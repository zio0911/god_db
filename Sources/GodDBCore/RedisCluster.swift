import Foundation

/// Redis Cluster 계산 (슬롯, 키 위치, 슬롯 표, 리다이렉트)
public enum RedisCluster {
    public static let slotCount = 16384

    /// CRC16-XMODEM (Redis Cluster 명세)
    static let table: [UInt16] = (0..<256).map { i -> UInt16 in
        var crc = UInt16(i) << 8
        for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        return crc
    }

    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes { crc = (crc << 8) ^ table[Int(UInt8(truncatingIfNeeded: crc >> 8) ^ b)] }
        return crc
    }

    /// 키의 슬롯. {태그} 가 있으면 태그만으로 계산 (같은 태그는 같은 노드)
    public static func slot(_ key: String) -> Int {
        var bytes = Array(key.utf8)
        if let open = bytes.firstIndex(of: UInt8(ascii: "{")),
           let close = bytes[(open + 1)...].firstIndex(of: UInt8(ascii: "}")), close > open + 1 {
            bytes = Array(bytes[(open + 1)..<close])
        }
        return Int(crc16(bytes)) % slotCount
    }

    /// 명령에서 노드를 고를 기준이 되는 키 (없으면 nil → 아무 노드)
    public static func routingKey(_ args: [String]) -> String? {
        guard let name = args.first?.uppercased() else { return nil }
        // 키가 없는 명령
        let keyless: Set<String> = ["PING", "ECHO", "INFO", "DBSIZE", "TIME", "SELECT", "CONFIG", "CLIENT", "CLUSTER",
                                    "COMMAND", "SLOWLOG", "MEMORY STATS", "LASTSAVE", "ROLE", "SCAN", "KEYS", "RANDOMKEY",
                                    "FLUSHDB", "FLUSHALL", "PUBLISH", "PUBSUB", "SUBSCRIBE", "PSUBSCRIBE", "AUTH", "HELLO",
                                    "MULTI", "EXEC", "DISCARD", "SCRIPT", "FUNCTION", "ACL", "LATENCY", "MONITOR", "LOLWUT",
                                    "SHUTDOWN", "SAVE", "BGSAVE", "BGREWRITEAOF", "DEBUG", "SWAPDB", "WAIT", "READONLY", "READWRITE"]
        if keyless.contains(name) { return nil }
        switch name {
        case "MEMORY", "OBJECT":   // MEMORY USAGE key / OBJECT ENCODING key
            return args.count > 2 ? args[2] : nil
        case "XINFO":              // XINFO STREAM key / GROUPS key / CONSUMERS key group
            return args.count > 2 ? args[2] : nil
        case "XGROUP":             // XGROUP CREATE key …
            return args.count > 2 ? args[2] : nil
        case "XREAD", "XREADGROUP":
            if let i = args.firstIndex(where: { $0.uppercased() == "STREAMS" }), i + 1 < args.count { return args[i + 1] }
            return nil
        case "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO":
            if args.count > 3, let n = Int(args[2]), n > 0 { return args[3] }
            return nil
        case "BITOP":
            return args.count > 2 ? args[2] : nil
        default:
            return args.count > 1 ? args[1] : nil
        }
    }

    /// 마스터 노드 하나가 맡는 슬롯 구간
    public struct SlotRange: Equatable, Sendable {
        public let start: Int
        public let end: Int
        /// "host:port"
        public let master: String
        public let replicas: [String]
    }

    /// CLUSTER SLOTS 응답 → 슬롯 표. ip 가 비어 있으면 seedHost 를 쓴다.
    public static func parseSlots(_ v: RESPValue, seedHost: String) -> [SlotRange] {
        func addr(_ node: RESPValue) -> String? {
            guard let a = node.array, a.count >= 2, let port = a[1].int else { return nil }
            var host = a[0].string ?? ""
            if host.isEmpty || host == "?" { host = seedHost }
            return "\(host):\(port)"
        }
        return (v.array ?? []).compactMap { r in
            guard let a = r.array, a.count >= 3, let s = a[0].int, let e = a[1].int, let m = addr(a[2]) else { return nil }
            return SlotRange(start: s, end: e, master: m, replicas: a.dropFirst(3).compactMap(addr))
        }.sorted { $0.start < $1.start }
    }

    /// 서버 오류가 리다이렉트인지: MOVED 3999 127.0.0.1:6381 / ASK 3999 127.0.0.1:6381
    public enum Redirect: Equatable, Sendable {
        case moved(slot: Int, address: String)
        case ask(slot: Int, address: String)
    }

    public static func redirect(_ message: String) -> Redirect? {
        let parts = message.split(separator: " ")
        guard parts.count >= 3, let slot = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "MOVED": return .moved(slot: slot, address: String(parts[2]))
        case "ASK": return .ask(slot: slot, address: String(parts[2]))
        default: return nil
        }
    }

    /// "host:port" → (host, port). IPv6 는 마지막 : 기준
    public static func split(_ address: String) -> (host: String, port: Int)? {
        guard let i = address.lastIndex(of: ":"), let port = Int(address[address.index(after: i)...]) else { return nil }
        var host = String(address[..<i])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host, port)
    }

    /// 센티널 주소 목록: 호스트 칸에 "h1:26379, h2:26379" 또는 "h1" (기본 포트)
    public static func sentinelAddresses(_ hostField: String, defaultPort: Int) -> [(host: String, port: Int)] {
        hostField.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).compactMap { item in
            let s = String(item)
            if s.contains(":"), let hp = split(s) { return hp }
            return s.isEmpty ? nil : (s, defaultPort)
        }
    }
}
