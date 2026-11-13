import Foundation

/// 키 정보
public struct RedisKeyInfo: Sendable, Equatable {
    public let key: String
    /// string, hash, list, set, zset, stream, none …
    public let type: String
    /// 남은 시간(밀리초). -1 = 만료 없음, -2 = 키 없음
    public let ttlMillis: Int
    /// 원소 수 (string 은 바이트 수)
    public let length: Int?
    /// 메모리 사용량 (MEMORY USAGE, 못 구하면 nil)
    public let memory: Int?
    public let encoding: String?

    public var exists: Bool { type != "none" && ttlMillis != -2 }
}

public struct RedisStreamEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let fields: [(String, String)]
    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.fields.map(\.0) == b.fields.map(\.0) && a.fields.map(\.1) == b.fields.map(\.1)
    }
}

public struct RedisStreamGroup: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let consumers: Int
    public let pending: Int
    public let lastDeliveredID: String
    public let lag: Int?
}

public struct RedisStreamConsumer: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let pending: Int
    public let idleMillis: Int
}

public struct RedisPendingEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let consumer: String
    public let idleMillis: Int
    public let deliveries: Int
}

public struct RedisPubSubMessage: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let date: Date
    /// message / pmessage / subscribe / unsubscribe / psubscribe / punsubscribe
    public let kind: String
    public let channel: String
    public let pattern: String?
    public let payload: String
}

/// Redis 접속 하나 (필요하면 SSH 터널 포함).
/// Cluster 면 노드마다 연결을 열고 키의 슬롯에 맞는 노드로 보낸다 (MOVED/ASK 자동 처리).
/// Sentinel 이면 센티널에게 현재 마스터를 물어 접속한다.
public actor RedisSession {
    public enum Topology: Sendable, Equatable {
        case standalone
        /// 마스터 노드 주소들 ("host:port")
        case cluster(masters: [String])
        /// 마스터 이름과 접속한 주소
        case sentinel(master: String, address: String)
    }

    public nonisolated let profile: ConnectionProfile
    public private(set) var topology: Topology = .standalone
    public private(set) var db: Int = 0
    private var password: String?
    /// 노드 주소("host:port") → 연결 / SSH 터널
    private var conns: [String: RedisConnection] = [:]
    private var tunnels: [String: SSHTunnel] = [:]
    /// 키 없는 명령을 보낼 노드
    private var primary = ""
    private var slots: [RedisCluster.SlotRange] = []

    public init(profile: ConnectionProfile) {
        self.profile = profile
    }

    public static func connect(profile: ConnectionProfile, password: String?) async throws -> RedisSession {
        let s = RedisSession(profile: profile)
        do {
            try await s.open(password: password)
        } catch {
            await s.close()
            throw error
        }
        return s
    }

    /// 접속 화면의 "DB" 칸 (비어 있으면 0)
    public static func databaseIndex(_ text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    public var isCluster: Bool { if case .cluster = topology { return true } else { return false } }

    /// 화면 표시용: "Cluster · 마스터 3" / "Sentinel mymaster → 10.0.0.5:6379"
    public var topologyText: String {
        switch topology {
        case .standalone: return ""
        case .cluster(let m): return tr("Cluster · 마스터 %@개", "\(m.count)")
        case .sentinel(let name, let addr): return "Sentinel \(name) → \(addr)"
        }
    }

    /// Cluster 노드 목록 (화면용)
    public var masterNodes: [String] {
        if case .cluster(let m) = topology { return m }
        return [primary]
    }

    private func open(password: String?) async throws {
        self.password = password
        switch profile.redisMode {
        case .sentinel:
            let address = try await resolveSentinel()
            primary = address
            db = Self.databaseIndex(profile.database)
            _ = try await connection(address)
            topology = .sentinel(master: profile.sentinelMaster, address: address)
        case .standalone, .cluster:
            let seed = "\(profile.host):\(profile.port)"
            primary = seed
            // Cluster 인지 확인하기 전에는 DB 0 으로 붙는다 (Cluster 는 SELECT 를 거부)
            let wantedDB = profile.redisMode == .cluster ? 0 : Self.databaseIndex(profile.database)
            db = 0
            let conn = try await connection(seed)
            // 단일로 설정했어도 서버가 Cluster 면 자동으로 Cluster 로 동작한다
            var clusterEnabled = profile.redisMode == .cluster
            if !clusterEnabled, let text = try? await conn.send(["INFO", "cluster"]).string {
                clusterEnabled = text.contains("cluster_enabled:1")
            }
            if clusterEnabled {
                try await refreshSlots()
            } else if wantedDB != 0 {
                try await conn.send(["SELECT", String(wantedDB)])
                db = wantedDB
            }
        }
    }

    /// 센티널들에게 차례로 물어 현재 마스터 주소를 얻는다
    private func resolveSentinel() async throws -> String {
        let name = profile.sentinelMaster.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw RedisCommandError.sentinelMasterMissing }
        var lastError: Error = DBError.notConnected
        for s in RedisCluster.sentinelAddresses(profile.host, defaultPort: profile.port) {
            let addr = "\(s.host):\(s.port)"
            // 센티널은 보통 비밀번호가 없다. 필요하면 같은 비밀번호로 다시 시도
            for pw in [nil, password] {
                do {
                    let c = try await RedisConnection.connect(options(addr, password: pw, database: 0))
                    defer { Task { await c.close() } }
                    let v = try await c.send(["SENTINEL", "get-master-addr-by-name", name])
                    guard let a = v.array, a.count == 2, let host = a[0].string, let port = a[1].int else {
                        throw RedisCommandError.sentinelMasterNotFound(name)
                    }
                    return "\(host):\(port)"
                } catch let e as RedisServerError where e.code == "NOAUTH" || e.code == "WRONGPASS" {
                    lastError = e
                    continue
                } catch {
                    lastError = error
                    break
                }
            }
        }
        throw lastError
    }

    /// CLUSTER SLOTS 로 슬롯 표를 다시 읽는다
    private func refreshSlots() async throws {
        let seedHost = RedisCluster.split(primary)?.host ?? profile.host
        let v = try await connection(primary).send(["CLUSTER", "SLOTS"])
        let parsed = RedisCluster.parseSlots(v, seedHost: seedHost)
        guard !parsed.isEmpty else { return }
        slots = parsed
        var masters: [String] = []
        for r in parsed where !masters.contains(r.master) { masters.append(r.master) }
        topology = .cluster(masters: masters)
        if !masters.contains(primary), let first = masters.first { primary = first }
    }

    /// 노드 주소에 붙을 연결 설정 (SSH 면 노드마다 터널)
    private func options(_ address: String, password: String?, database: Int) async throws -> RedisConnection.Options {
        guard let (host, port) = RedisCluster.split(address) else { throw DBError.notConnected }
        var h = host, p = port
        if let ssh = profile.ssh {
            if let t = tunnels[address] {
                p = t.localPort
            } else {
                let t = try SSHTunnel(config: ssh, remoteHost: host, remotePort: port)
                try await t.start()
                tunnels[address] = t
                p = t.localPort
            }
            h = "127.0.0.1"
        }
        return RedisConnection.Options(
            host: h, port: p,
            serverName: (profile.ssh == nil && !HostResolver.isIPAddress(host)) ? host : nil,
            useTLS: profile.useTLS, username: profile.username, password: password, database: database)
    }

    /// 노드 연결 (없거나 끊겼으면 연다)
    private func connection(_ address: String) async throws -> RedisConnection {
        if let c = conns[address], c.isOpen { return c }
        let c = try await RedisConnection.connect(options(address, password: password, database: isCluster ? 0 : db))
        conns[address] = c
        return c
    }

    /// 키가 있는 노드
    private func address(forKey key: String?) -> String {
        guard isCluster, let key, !slots.isEmpty else { return primary }
        let slot = RedisCluster.slot(key)
        return slots.first { $0.start <= slot && slot <= $0.end }?.master ?? primary
    }

    private func connection(forKey key: String?) async throws -> RedisConnection {
        try await connection(address(forKey: key))
    }

    /// 명령을 맞는 노드로 보낸다. MOVED/ASK 면 따라간다. raw 면 서버 오류도 값으로 돌려준다.
    private func exec(_ args: [String], raw: Bool = false) async throws -> RESPValue {
        var addr = address(forKey: RedisCluster.routingKey(args))
        var asking = false
        for _ in 0..<5 {
            let conn = try await connection(addr)
            if asking { _ = try? await conn.raw([Array("ASKING".utf8)]) }
            let v = try await conn.raw(args.map { Array($0.utf8) })
            if case .error(let m) = v, let r = RedisCluster.redirect(m) {
                switch r {
                case .moved(_, let a):
                    addr = a
                    asking = false
                    // 슬롯이 옮겨졌다 → 표를 새로 읽는다 (단일로 붙었는데 Cluster 였던 경우도 여기서 전환)
                    try? await refreshSlotsFrom(a)
                case .ask(_, let a):
                    addr = a
                    asking = true
                }
                continue
            }
            if !raw, case .error(let m) = v { throw RedisServerError(message: m) }
            return v
        }
        throw RedisServerError(message: "ERR too many cluster redirects")
    }

    private func refreshSlotsFrom(_ address: String) async throws {
        if !isCluster { primary = address; db = 0 }
        try await refreshSlots()
    }

    private func c() async throws -> RedisConnection {
        try await connection(primary)
    }

    public func close() async {
        for c in conns.values { await c.close() }
        conns = [:]
        for t in tunnels.values { t.stop() }
        tunnels = [:]
    }

    public var isConnected: Bool { conns[primary]?.isOpen ?? false }

    /// 앱이 내부적으로 쓰는 명령 (읽기전용이면 쓰기 명령 차단)
    @discardableResult
    public func command(_ args: [String]) async throws -> RESPValue {
        if profile.readOnly, !RedisCommands.isReadOnly(args) { throw RedisCommandError.readOnly }
        return try await exec(args)
    }

    /// 콘솔에서 입력한 명령. 서버 오류도 값으로 돌려준다.
    public func console(_ args: [String]) async throws -> RESPValue {
        guard let name = args.first?.uppercased() else { return .simple("") }
        if RedisCommands.subscribeCommands.contains(name) { throw RedisCommandError.useSubscribeTab }
        if profile.readOnly && !RedisCommands.isReadOnly(args) { throw RedisCommandError.readOnly }
        if name == "SELECT", isCluster { throw RedisCommandError.clusterSingleDB }
        let v = try await exec(args, raw: true)
        if name == "SELECT", case .simple = v, args.count > 1, let n = Int(args[1]) { db = n }
        return v
    }

    public func select(_ index: Int) async throws {
        if isCluster {
            guard index == 0 else { throw RedisCommandError.clusterSingleDB }
            return
        }
        try await exec(["SELECT", String(index)])
        db = index
    }

    public func ping() async throws -> String {
        try await exec(["PING"]).string ?? ""
    }

    // MARK: - 서버

    /// INFO 를 (섹션, [(키, 값)]) 로
    /// node 를 주면 그 노드의 INFO (Cluster)
    public func info(_ section: String? = nil, node: String? = nil) async throws -> [(String, [(String, String)])] {
        let args = section.map { ["INFO", $0] } ?? ["INFO"]
        let text: String
        if let node {
            text = try await connection(node).send(args).string ?? ""
        } else {
            text = try await exec(args).string ?? ""
        }
        return Self.parseInfo(text)
    }

    public static func parseInfo(_ text: String) -> [(String, [(String, String)])] {
        var out: [(String, [(String, String)])] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                out.append((line.dropFirst().trimmingCharacters(in: .whitespaces), []))
            } else if let i = line.firstIndex(of: ":") {
                if out.isEmpty { out.append(("", [])) }
                out[out.count - 1].1.append((String(line[..<i]), String(line[line.index(after: i)...])))
            }
        }
        return out
    }

    /// 쓸 수 있는 DB 번호들과 키 개수 (INFO keyspace + CONFIG GET databases)
    public func databases() async throws -> [(index: Int, keys: Int)] {
        // Cluster 는 DB 0 하나뿐, 키 수는 모든 마스터 합계
        if isCluster { return [(0, try await dbSize())] }
        var count = 16
        if let v = try? await exec(["CONFIG", "GET", "databases"]).array, v.count == 2, let n = v[1].int {
            count = n
        }
        var keys: [Int: Int] = [:]
        for (_, items) in try await info("keyspace") {
            for (k, v) in items where k.hasPrefix("db") {
                if let i = Int(k.dropFirst(2)),
                   let kv = v.split(separator: ",").first(where: { $0.hasPrefix("keys=") }),
                   let n = Int(kv.dropFirst(5)) {
                    keys[i] = n
                }
            }
        }
        count = max(count, (keys.keys.max() ?? 0) + 1, db + 1)
        return (0..<count).map { ($0, keys[$0] ?? 0) }
    }

    public func dbSize() async throws -> Int {
        if isCluster {
            var total = 0
            for m in masterNodes { total += try await connection(m).send(["DBSIZE"]).int ?? 0 }
            return total
        }
        return try await exec(["DBSIZE"]).int ?? 0
    }

    // MARK: - 키

    /// SCAN 한 번. cursor "0" 이 오면 끝.
    /// Cluster 면 마스터를 차례로 훑는다. 이때 cursor 는 "노드번호|노드cursor" 형태.
    public func scan(cursor: String, pattern: String, count: Int = 500, type: String? = nil) async throws -> (cursor: String, keys: [String]) {
        var args = ["SCAN", "", "MATCH", pattern.isEmpty ? "*" : pattern, "COUNT", String(count)]
        if let type, !type.isEmpty { args += ["TYPE", type] }
        guard isCluster else {
            args[1] = cursor
            let v = try await exec(args).array ?? []
            guard v.count == 2 else { return ("0", []) }
            return (v[0].string ?? "0", (v[1].array ?? []).compactMap(\.string))
        }
        let masters = masterNodes
        var node = 0
        var nodeCursor = "0"
        if cursor != "0" {
            let parts = cursor.split(separator: "|", maxSplits: 1)
            node = parts.first.flatMap { Int($0) } ?? 0
            nodeCursor = parts.count > 1 ? String(parts[1]) : "0"
        }
        guard node < masters.count else { return ("0", []) }
        args[1] = nodeCursor
        let v = try await connection(masters[node]).send(args).array ?? []
        let keys = v.count == 2 ? (v[1].array ?? []).compactMap(\.string) : []
        let next = v.count == 2 ? (v[0].string ?? "0") : "0"
        if next != "0" { return ("\(node)|\(next)", keys) }
        return node + 1 < masters.count ? ("\(node + 1)|0", keys) : ("0", keys)
    }

    /// 키를 limit 개까지 모은다 (SCAN 반복). 더 있으면 다음 cursor.
    public func scanKeys(pattern: String, type: String? = nil, from cursor: String = "0", limit: Int = 1000) async throws -> (keys: [String], next: String?) {
        var cur = cursor
        var keys: [String] = []
        var seen = Set<String>()
        var rounds = 0
        repeat {
            let r = try await scan(cursor: cur, pattern: pattern, type: type)
            for k in r.keys where seen.insert(k).inserted { keys.append(k) }
            cur = r.cursor
            rounds += 1
        } while cur != "0" && keys.count < limit && rounds < 2000
        return (keys, cur == "0" ? nil : cur)
    }

    /// 여러 키의 타입과 남은 시간(밀리초)을 파이프라인으로 한 번에
    public func keyMeta(_ keys: [String]) async throws -> [String: (type: String, ttlMillis: Int)] {
        // 노드별로 묶어서 각 노드에 파이프라인
        var byNode: [String: [String]] = [:]
        for k in keys { byNode[address(forKey: k), default: []].append(k) }
        var conns: [(RedisConnection, [String])] = []
        for (addr, ks) in byNode { conns.append((try await connection(addr), ks)) }
        return try await withThrowingTaskGroup(of: (String, String, Int).self) { group in
            for (conn, ks) in conns { for k in ks {
                group.addTask {
                    async let t = conn.send(["TYPE", k])
                    async let p = conn.send(["PTTL", k])
                    return (k, try await t.string ?? "none", try await p.int ?? -2)
                }
            } }
            var out: [String: (type: String, ttlMillis: Int)] = [:]
            for try await (k, t, ttl) in group { out[k] = (t, ttl) }
            return out
        }
    }

    public func keyInfo(_ key: String) async throws -> RedisKeyInfo {
        let conn = try await connection(forKey: key)
        let type = try await conn.send(["TYPE", key]).string ?? "none"
        let ttl = try await conn.send(["PTTL", key]).int ?? -2
        var length: Int? = nil
        let lenCmd: [String]? = switch type {
        case "string": ["STRLEN", key]
        case "hash": ["HLEN", key]
        case "list": ["LLEN", key]
        case "set": ["SCARD", key]
        case "zset": ["ZCARD", key]
        case "stream": ["XLEN", key]
        default: nil
        }
        if let lenCmd { length = try? await conn.send(lenCmd).int }
        let memory = try? await conn.send(["MEMORY", "USAGE", key]).int
        let encoding = try? await conn.send(["OBJECT", "ENCODING", key]).string
        return RedisKeyInfo(key: key, type: type, ttlMillis: ttl, length: length, memory: memory, encoding: encoding)
    }

    // MARK: - 타입별 값

    public func string(_ key: String) async throws -> String? {
        try await exec(["GET", key]).string
    }

    /// HSCAN 으로 limit 개까지
    public func hash(_ key: String, pattern: String = "*", limit: Int = 1000) async throws -> [(String, String)] {
        var cur = "0"
        var out: [(String, String)] = []
        repeat {
            let v = try await exec(["HSCAN", key, cur, "MATCH", pattern.isEmpty ? "*" : pattern, "COUNT", "500"]).array ?? []
            guard v.count == 2 else { break }
            cur = v[0].string ?? "0"
            let items = v[1].array ?? []
            var i = 0
            while i + 1 < items.count {
                out.append((items[i].string ?? "", items[i + 1].string ?? ""))
                i += 2
            }
        } while cur != "0" && out.count < limit
        return out
    }

    public func list(_ key: String, start: Int, count: Int) async throws -> [String] {
        try await exec(["LRANGE", key, String(start), String(start + count - 1)]).array?.compactMap(\.string) ?? []
    }

    public func set(_ key: String, pattern: String = "*", limit: Int = 1000) async throws -> [String] {
        var cur = "0"
        var out: [String] = []
        repeat {
            let v = try await exec(["SSCAN", key, cur, "MATCH", pattern.isEmpty ? "*" : pattern, "COUNT", "500"]).array ?? []
            guard v.count == 2 else { break }
            cur = v[0].string ?? "0"
            out += (v[1].array ?? []).compactMap(\.string)
        } while cur != "0" && out.count < limit
        return out
    }

    /// 점수 순 (reverse 면 높은 점수부터)
    public func zset(_ key: String, start: Int, count: Int, reverse: Bool = false) async throws -> [(String, String)] {
        var args = ["ZRANGE", key, String(start), String(start + count - 1)]
        if reverse { args.append("REV") }
        args.append("WITHSCORES")
        let items = try await exec(args).array ?? []
        var out: [(String, String)] = []
        var i = 0
        while i + 1 < items.count {
            out.append((items[i].string ?? "", items[i + 1].string ?? ""))
            i += 2
        }
        return out
    }

    // MARK: - Streams

    static func entries(_ v: RESPValue) -> [RedisStreamEntry] {
        (v.array ?? []).compactMap { e in
            guard let parts = e.array, parts.count == 2, let id = parts[0].string else { return nil }
            let kv = parts[1].array ?? []
            var fields: [(String, String)] = []
            var i = 0
            while i + 1 < kv.count {
                fields.append((kv[i].string ?? "", kv[i + 1].string ?? ""))
                i += 2
            }
            return RedisStreamEntry(id: id, fields: fields)
        }
    }

    /// 최신 항목부터 (before 가 있으면 그 ID 보다 이전)
    public func streamLatest(_ key: String, count: Int, before: String? = nil) async throws -> [RedisStreamEntry] {
        let end = before.map { "(" + $0 } ?? "+"
        return Self.entries(try await exec(["XREVRANGE", key, end, "-", "COUNT", String(count)]))
    }

    public func streamRange(_ key: String, start: String, end: String, count: Int) async throws -> [RedisStreamEntry] {
        Self.entries(try await exec(["XRANGE", key, start.isEmpty ? "-" : start, end.isEmpty ? "+" : end, "COUNT", String(count)]))
    }

    /// XINFO STREAM 의 주요 값
    public func streamInfo(_ key: String) async throws -> [(String, String)] {
        let v = try await exec(["XINFO", "STREAM", key]).array ?? []
        var out: [(String, String)] = []
        var i = 0
        while i + 1 < v.count {
            let name = v[i].string ?? ""
            let value: String
            if let arr = v[i + 1].array {
                // first-entry / last-entry 는 [id, [f, v…]]
                if arr.count == 2, let id = arr[0].string { value = id } else { value = "\(arr.count) items" }
            } else {
                value = v[i + 1].string ?? "(nil)"
            }
            out.append((name, value))
            i += 2
        }
        return out
    }

    static func dict(_ v: RESPValue) -> [String: RESPValue] {
        let a = v.array ?? []
        var d: [String: RESPValue] = [:]
        var i = 0
        while i + 1 < a.count {
            if let k = a[i].string { d[k] = a[i + 1] }
            i += 2
        }
        return d
    }

    public func streamGroups(_ key: String) async throws -> [RedisStreamGroup] {
        (try await exec(["XINFO", "GROUPS", key]).array ?? []).map { g in
            let d = Self.dict(g)
            return RedisStreamGroup(name: d["name"]?.string ?? "", consumers: d["consumers"]?.int ?? 0,
                                    pending: d["pending"]?.int ?? 0, lastDeliveredID: d["last-delivered-id"]?.string ?? "",
                                    lag: d["lag"]?.int)
        }
    }

    public func streamConsumers(_ key: String, group: String) async throws -> [RedisStreamConsumer] {
        (try await exec(["XINFO", "CONSUMERS", key, group]).array ?? []).map { g in
            let d = Self.dict(g)
            return RedisStreamConsumer(name: d["name"]?.string ?? "", pending: d["pending"]?.int ?? 0,
                                       idleMillis: d["idle"]?.int ?? 0)
        }
    }

    public func streamPending(_ key: String, group: String, count: Int = 100) async throws -> [RedisPendingEntry] {
        (try await exec(["XPENDING", key, group, "-", "+", String(count)]).array ?? []).compactMap { e in
            guard let a = e.array, a.count >= 4 else { return nil }
            return RedisPendingEntry(id: a[0].string ?? "", consumer: a[1].string ?? "",
                                     idleMillis: a[2].int ?? 0, deliveries: a[3].int ?? 0)
        }
    }

    // MARK: - Pub/Sub

    public func publish(_ channel: String, _ message: String) async throws -> Int {
        try await command(["PUBLISH", channel, message]).int ?? 0
    }

    /// 활성 채널과 구독자 수
    public func activeChannels(pattern: String = "*") async throws -> [(String, Int)] {
        let names = try await exec(["PUBSUB", "CHANNELS", pattern.isEmpty ? "*" : pattern]).array?.compactMap(\.string) ?? []
        guard !names.isEmpty else { return [] }
        let v = try await exec(["PUBSUB", "NUMSUB"] + names.prefix(500)).array ?? []
        var out: [(String, Int)] = []
        var i = 0
        while i + 1 < v.count {
            out.append((v[i].string ?? "", v[i + 1].int ?? 0))
            i += 2
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// 구독 전용 연결을 따로 연다.
    public func subscriber() async throws -> RedisSubscriber {
        // Cluster 에서도 PUBLISH 는 모든 노드에 전달되므로 아무 노드에 구독하면 된다
        return try await RedisSubscriber(connection: RedisConnection.connect(options(primary, password: password, database: isCluster ? 0 : db)))
    }

    /// 스트림 실시간 보기용 연결 (XREAD BLOCK 이 일반 명령을 막지 않도록 따로 연다)
    public func streamTail(_ key: String, from id: String = "$") async throws -> AsyncThrowingStream<RedisStreamEntry, Error> {
        let tailConn = try await RedisConnection.connect(options(address(forKey: key), password: password, database: isCluster ? 0 : db))
        return AsyncThrowingStream { cont in
            let task = Task {
                var last = id
                do {
                    while !Task.isCancelled {
                        let v = try await tailConn.send(["XREAD", "COUNT", "100", "BLOCK", "2000", "STREAMS", key, last])
                        guard let streams = v.array else { continue }
                        for s in streams {
                            guard let parts = s.array, parts.count == 2 else { continue }
                            for e in Self.entries(parts[1]) {
                                last = e.id
                                cont.yield(e)
                            }
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: Task.isCancelled ? nil : error)
                }
                await tailConn.close()
            }
            cont.onTermination = { _ in
                task.cancel()
                Task { await tailConn.close() }
            }
        }
    }
}

/// 구독 연결
public final class RedisSubscriber: @unchecked Sendable {
    let connection: RedisConnection
    public let messages: AsyncStream<RedisPubSubMessage>

    init(connection: RedisConnection) {
        self.connection = connection
        messages = AsyncStream { cont in
            let stream = connection.pushStream()
            let task = Task {
                for await v in stream {
                    if let m = RedisSubscriber.parse(v) { cont.yield(m) }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func parse(_ v: RESPValue) -> RedisPubSubMessage? {
        guard let a = v.array, let kind = a.first?.string else { return nil }
        switch kind {
        case "message" where a.count == 3:
            return .init(date: Date(), kind: kind, channel: a[1].string ?? "", pattern: nil, payload: a[2].string ?? "")
        case "pmessage" where a.count == 4:
            return .init(date: Date(), kind: kind, channel: a[2].string ?? "", pattern: a[1].string, payload: a[3].string ?? "")
        case "subscribe", "unsubscribe", "psubscribe", "punsubscribe":
            return .init(date: Date(), kind: kind, channel: a.count > 1 ? (a[1].string ?? "") : "", pattern: nil,
                         payload: a.count > 2 ? (a[2].string ?? "") : "")
        default:
            return nil
        }
    }

    public func subscribe(_ channels: [String]) { if !channels.isEmpty { connection.fire(["SUBSCRIBE"] + channels) } }
    public func psubscribe(_ patterns: [String]) { if !patterns.isEmpty { connection.fire(["PSUBSCRIBE"] + patterns) } }
    public func unsubscribe(_ channels: [String]) { connection.fire(["UNSUBSCRIBE"] + channels) }
    public func punsubscribe(_ patterns: [String]) { connection.fire(["PUNSUBSCRIBE"] + patterns) }

    public func close() async { await connection.close() }
}

public enum RedisCommandError: LocalizedError, Equatable {
    case readOnly
    case useSubscribeTab
    case clusterSingleDB
    case sentinelMasterMissing
    case sentinelMasterNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .readOnly: return tr("읽기전용 접속이라 이 명령은 실행할 수 없어요. (조회 명령만 허용)")
        case .useSubscribeTab: return tr("구독 명령은 Pub/Sub 탭에서 쓰세요.")
        case .clusterSingleDB: return tr("Redis Cluster 는 DB 0 하나만 쓸 수 있어요.")
        case .sentinelMasterMissing: return tr("Sentinel 마스터 이름을 접속 편집에서 넣어 주세요. (예: mymaster)")
        case .sentinelMasterNotFound(let n): return tr("센티널이 마스터 %@ 를 모른다고 해요. 마스터 이름을 확인해 주세요.", n)
        }
    }
}
