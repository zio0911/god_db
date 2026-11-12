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

/// Redis 접속 하나 (필요하면 SSH 터널 포함)
public actor RedisSession {
    public nonisolated let profile: ConnectionProfile
    private var tunnel: SSHTunnel?
    private var conn: RedisConnection?
    private var options: RedisConnection.Options?
    public private(set) var db: Int = 0

    public init(profile: ConnectionProfile) {
        self.profile = profile
    }

    public static func connect(profile: ConnectionProfile, password: String?) async throws -> RedisSession {
        let s = RedisSession(profile: profile)
        try await s.open(password: password)
        return s
    }

    /// 접속 화면의 "DB" 칸 (비어 있으면 0)
    public static func databaseIndex(_ text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private func open(password: String?) async throws {
        var host = profile.host
        var port = profile.port
        if let ssh = profile.ssh {
            let t = try SSHTunnel(config: ssh, remoteHost: profile.host, remotePort: profile.port)
            try await t.start()
            tunnel = t
            host = "127.0.0.1"
            port = t.localPort
        }
        db = Self.databaseIndex(profile.database)
        let o = RedisConnection.Options(
            host: host, port: port,
            serverName: (profile.ssh == nil && !HostResolver.isIPAddress(profile.host)) ? profile.host : nil,
            useTLS: profile.useTLS, username: profile.username, password: password, database: db)
        do {
            conn = try await RedisConnection.connect(o)
            options = o
        } catch {
            tunnel?.stop()
            tunnel = nil
            throw error
        }
    }

    public func close() async {
        await conn?.close()
        conn = nil
        tunnel?.stop()
        tunnel = nil
    }

    public var isConnected: Bool { conn?.isOpen ?? false }

    private func c() throws -> RedisConnection {
        guard let conn, conn.isOpen else { throw DBError.notConnected }
        return conn
    }

    /// 앱이 내부적으로 쓰는 명령 (읽기전용이면 쓰기 명령 차단)
    @discardableResult
    public func command(_ args: [String]) async throws -> RESPValue {
        if profile.readOnly, let name = args.first, !RedisCommands.isReadOnly(args) {
            _ = name
            throw RedisCommandError.readOnly
        }
        return try await c().send(args)
    }

    /// 콘솔에서 입력한 명령. 서버 오류도 값으로 돌려준다.
    public func console(_ args: [String]) async throws -> RESPValue {
        guard let name = args.first?.uppercased() else { return .simple("") }
        if RedisCommands.subscribeCommands.contains(name) { throw RedisCommandError.useSubscribeTab }
        if profile.readOnly && !RedisCommands.isReadOnly(args) { throw RedisCommandError.readOnly }
        let v = try await c().raw(args.map { Array($0.utf8) })
        if name == "SELECT", case .simple = v, args.count > 1, let n = Int(args[1]) { db = n }
        return v
    }

    public func select(_ index: Int) async throws {
        try await c().send(["SELECT", String(index)])
        db = index
    }

    public func ping() async throws -> String {
        try await c().send(["PING"]).string ?? ""
    }

    // MARK: - 서버

    /// INFO 를 (섹션, [(키, 값)]) 로
    public func info(_ section: String? = nil) async throws -> [(String, [(String, String)])] {
        let text = try await c().send(section.map { ["INFO", $0] } ?? ["INFO"]).string ?? ""
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
        var count = 16
        if let v = try? await c().send(["CONFIG", "GET", "databases"]).array, v.count == 2, let n = v[1].int {
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
        try await c().send(["DBSIZE"]).int ?? 0
    }

    // MARK: - 키

    /// SCAN 한 번. cursor "0" 이 오면 끝.
    public func scan(cursor: String, pattern: String, count: Int = 500, type: String? = nil) async throws -> (cursor: String, keys: [String]) {
        var args = ["SCAN", cursor, "MATCH", pattern.isEmpty ? "*" : pattern, "COUNT", String(count)]
        if let type, !type.isEmpty { args += ["TYPE", type] }
        let v = try await c().send(args).array ?? []
        guard v.count == 2 else { return ("0", []) }
        return (v[0].string ?? "0", (v[1].array ?? []).compactMap(\.string))
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

    public func keyInfo(_ key: String) async throws -> RedisKeyInfo {
        let conn = try c()
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
        try await c().send(["GET", key]).string
    }

    /// HSCAN 으로 limit 개까지
    public func hash(_ key: String, pattern: String = "*", limit: Int = 1000) async throws -> [(String, String)] {
        var cur = "0"
        var out: [(String, String)] = []
        repeat {
            let v = try await c().send(["HSCAN", key, cur, "MATCH", pattern.isEmpty ? "*" : pattern, "COUNT", "500"]).array ?? []
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
        try await c().send(["LRANGE", key, String(start), String(start + count - 1)]).array?.compactMap(\.string) ?? []
    }

    public func set(_ key: String, pattern: String = "*", limit: Int = 1000) async throws -> [String] {
        var cur = "0"
        var out: [String] = []
        repeat {
            let v = try await c().send(["SSCAN", key, cur, "MATCH", pattern.isEmpty ? "*" : pattern, "COUNT", "500"]).array ?? []
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
        let items = try await c().send(args).array ?? []
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
        return Self.entries(try await c().send(["XREVRANGE", key, end, "-", "COUNT", String(count)]))
    }

    public func streamRange(_ key: String, start: String, end: String, count: Int) async throws -> [RedisStreamEntry] {
        Self.entries(try await c().send(["XRANGE", key, start.isEmpty ? "-" : start, end.isEmpty ? "+" : end, "COUNT", String(count)]))
    }

    /// XINFO STREAM 의 주요 값
    public func streamInfo(_ key: String) async throws -> [(String, String)] {
        let v = try await c().send(["XINFO", "STREAM", key]).array ?? []
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
        (try await c().send(["XINFO", "GROUPS", key]).array ?? []).map { g in
            let d = Self.dict(g)
            return RedisStreamGroup(name: d["name"]?.string ?? "", consumers: d["consumers"]?.int ?? 0,
                                    pending: d["pending"]?.int ?? 0, lastDeliveredID: d["last-delivered-id"]?.string ?? "",
                                    lag: d["lag"]?.int)
        }
    }

    public func streamConsumers(_ key: String, group: String) async throws -> [RedisStreamConsumer] {
        (try await c().send(["XINFO", "CONSUMERS", key, group]).array ?? []).map { g in
            let d = Self.dict(g)
            return RedisStreamConsumer(name: d["name"]?.string ?? "", pending: d["pending"]?.int ?? 0,
                                       idleMillis: d["idle"]?.int ?? 0)
        }
    }

    public func streamPending(_ key: String, group: String, count: Int = 100) async throws -> [RedisPendingEntry] {
        (try await c().send(["XPENDING", key, group, "-", "+", String(count)]).array ?? []).compactMap { e in
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
        let names = try await c().send(["PUBSUB", "CHANNELS", pattern.isEmpty ? "*" : pattern]).array?.compactMap(\.string) ?? []
        guard !names.isEmpty else { return [] }
        let v = try await c().send(["PUBSUB", "NUMSUB"] + names.prefix(500)).array ?? []
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
        guard let options else { throw DBError.notConnected }
        return try await RedisSubscriber(connection: RedisConnection.connect(options))
    }

    /// 스트림 실시간 보기용 연결 (XREAD BLOCK 이 일반 명령을 막지 않도록 따로 연다)
    public func streamTail(_ key: String, from id: String = "$") async throws -> AsyncThrowingStream<RedisStreamEntry, Error> {
        guard let options else { throw DBError.notConnected }
        let tailConn = try await RedisConnection.connect(options)
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

    public var errorDescription: String? {
        switch self {
        case .readOnly: return tr("읽기전용 접속이라 이 명령은 실행할 수 없어요. (조회 명령만 허용)")
        case .useSubscribeTab: return tr("구독 명령은 Pub/Sub 탭에서 쓰세요.")
        }
    }
}
