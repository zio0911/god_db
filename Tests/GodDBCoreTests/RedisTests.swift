import Foundation
import NIOCore
import Testing
@testable import GodDBCore

@Suite("Redis protocol")
struct RedisProtocolTests {
    func decode(_ s: String) throws -> RESPValue? {
        var b = ByteBuffer(string: s)
        return try RESPCoder.decode(&b)
    }

    @Test func decodesAllTypes() throws {
        #expect(try decode("+OK\r\n") == .simple("OK"))
        #expect(try decode("-ERR bad\r\n") == .error("ERR bad"))
        #expect(try decode(":42\r\n") == .integer(42))
        #expect(try decode("$5\r\nhello\r\n") == .bulk(Array("hello".utf8)))
        #expect(try decode("$-1\r\n") == .bulk(nil))
        #expect(try decode("*2\r\n$1\r\na\r\n:1\r\n") == .array([.bulk([97]), .integer(1)]))
        #expect(try decode("*-1\r\n") == .array(nil))
    }

    @Test func waitsForPartialData() throws {
        var b = ByteBuffer(string: "*2\r\n$5\r\nhel")
        #expect(try RESPCoder.decode(&b) == nil)
        #expect(b.readableBytes == 11)   // 읽은 위치를 되돌린다
        b.writeString("lo\r\n:7\r\n")
        #expect(try RESPCoder.decode(&b) == .array([.bulk(Array("hello".utf8)), .integer(7)]))
        #expect(b.readableBytes == 0)
    }

    @Test func formatsLikeRedisCli() {
        let v = RESPValue.array([.bulk(Array("a".utf8)), .integer(2), .array([.bulk(nil)])])
        #expect(v.formatted() == "1) \"a\"\n2) (integer) 2\n3) 1) (nil)")
        #expect(RESPValue.bulk([0xff, 0x41]).string == "\\xffA")
        #expect(RESPValue.bulk(Array("한글".utf8)).string == "한글")
    }

    @Test func splitsArgsWithQuotes() {
        #expect(RedisText.splitArgs("SET  k \"hello world\"") == ["SET", "k", "hello world"])
        #expect(RedisText.splitArgs("SET k 'it\\'s'") == ["SET", "k", "it's"])
        #expect(RedisText.splitArgs("SET k \"a\\nb\"") == ["SET", "k", "a\nb"])
        #expect(RedisText.splitArgs("SET k \"open") == nil)
        #expect(RedisText.splitArgs("") == [])
    }

    @Test func classifiesCommands() {
        #expect(RedisCommands.isReadOnly(["get", "k"]))
        #expect(!RedisCommands.isReadOnly(["SET", "k", "v"]))
        #expect(RedisCommands.isReadOnly(["CONFIG", "GET", "maxmemory"]))
        #expect(!RedisCommands.isReadOnly(["CONFIG", "SET", "maxmemory", "1"]))
        #expect(!RedisCommands.isReadOnly(["XREADGROUP", "GROUP", "g", "c", "STREAMS", "s", ">"]))
        #expect(RedisCommands.isDangerous(["flushall"]))
        #expect(RedisCommands.isDangerous(["KEYS", "*"]))
        #expect(!RedisCommands.isDangerous(["GET", "k"]))
        #expect(RedisCommands.complete("hge").contains("HGETALL"))
    }

    @Test func parsesInfo() {
        let info = RedisSession.parseInfo("# Server\r\nredis_version:7.2.4\r\n\r\n# Keyspace\r\ndb0:keys=3,expires=0\r\n")
        #expect(info.map(\.0) == ["Server", "Keyspace"])
        #expect(info[0].1.first.map { $0.0 == "redis_version" && $0.1 == "7.2.4" } == true)
    }
}

/// 실제 Redis (./scripts/test-dbs.sh up → 127.0.0.1:36379, 비밀번호 goddbtest)
@Suite("Redis integration", .serialized, .enabled(if: ProcessInfo.processInfo.environment["GODDB_REDIS_PORT"] != nil))
struct RedisIntegrationTests {
    var profile: ConnectionProfile {
        ConnectionProfile(kind: .redis, name: "redis-it", host: "127.0.0.1",
                          port: Int(ProcessInfo.processInfo.environment["GODDB_REDIS_PORT"]!)!,
                          username: "", database: "3", useTLS: false)
    }

    func session(readOnly: Bool = false) async throws -> RedisSession {
        var p = profile
        p.readOnly = readOnly
        return try await RedisSession.connect(profile: p, password: "goddbtest")
    }

    @Test func wrongPasswordFails() async throws {
        await #expect(throws: RedisServerError.self) {
            _ = try await RedisSession.connect(profile: profile, password: "nope")
        }
    }

    @Test func typesScanAndInfo() async throws {
        let s = try await session()
        try await s.command(["FLUSHDB"])
        try await s.command(["SET", "user:1:name", "홍길동"])
        try await s.command(["EXPIRE", "user:1:name", "100"])
        try await s.command(["HSET", "user:1", "name", "kim", "age", "30"])
        try await s.command(["RPUSH", "queue", "a", "b", "c"])
        try await s.command(["SADD", "tags", "x", "y"])
        try await s.command(["ZADD", "rank", "10", "a", "20", "b"])
        for i in 0..<1200 { try await s.command(["SET", "bulk:\(i)", "\(i)"]) }

        #expect(await s.db == 3)
        #expect(try await s.dbSize() == 1205)
        let all = try await s.scanKeys(pattern: "user:*")
        #expect(Set(all.keys) == ["user:1:name", "user:1"])
        let page = try await s.scanKeys(pattern: "bulk:*", limit: 500)
        #expect(page.keys.count >= 500)
        #expect(page.next != nil)
        let hashes = try await s.scanKeys(pattern: "*", type: "hash")
        #expect(hashes.keys == ["user:1"])

        let info = try await s.keyInfo("user:1:name")
        #expect(info.type == "string")
        #expect(info.ttlMillis > 90_000)
        #expect(info.length == "홍길동".utf8.count)
        #expect(try await s.string("user:1:name") == "홍길동")
        #expect(try await s.hash("user:1").sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" } == ["age=30", "name=kim"])
        #expect(try await s.list("queue", start: 1, count: 5) == ["b", "c"])
        #expect(Set(try await s.set("tags")) == ["x", "y"])
        #expect(try await s.zset("rank", start: 0, count: 10, reverse: true).map(\.0) == ["b", "a"])
        #expect(try await s.keyInfo("missing").exists == false)

        let dbs = try await s.databases()
        #expect(dbs.first { $0.index == 3 }?.keys == 1205)
        let sections = try await s.info()
        #expect(sections.contains { $0.0 == "Server" })

        // 콘솔: 오류도 값으로
        let err = try await s.console(["HGET", "queue", "x"])
        if case .error(let m) = err { #expect(m.hasPrefix("WRONGTYPE")) } else { Issue.record("expected error") }
        await #expect(throws: RedisCommandError.useSubscribeTab) { try await s.console(["SUBSCRIBE", "c"]) }
        await s.close()
    }

    @Test func readOnlyBlocksWrites() async throws {
        let s = try await session(readOnly: true)
        await #expect(throws: RedisCommandError.readOnly) { try await s.console(["SET", "k", "v"]) }
        await #expect(throws: RedisCommandError.readOnly) { try await s.command(["DEL", "k"]) }
        _ = try await s.console(["GET", "k"])
        await s.close()
    }

    @Test func streamsAndGroups() async throws {
        let s = try await session()
        try await s.command(["DEL", "orders"])
        for i in 1...5 { try await s.command(["XADD", "orders", "*", "order_id", "\(i)", "status", "new"]) }
        try await s.command(["XGROUP", "CREATE", "orders", "billing", "0"])
        // consumer c1 가 2건 읽고 1건만 ACK
        let read = try await s.command(["XREADGROUP", "GROUP", "billing", "c1", "COUNT", "2", "STREAMS", "orders", ">"])
        let firstID = read.array?.first?.array?[1].array?.first?.array?.first?.string
        #expect(firstID != nil)
        try await s.command(["XACK", "orders", "billing", firstID!])

        let latest = try await s.streamLatest("orders", count: 3)
        #expect(latest.count == 3)
        #expect(latest.first?.fields.first.map { $0.0 == "order_id" && $0.1 == "5" } == true)
        let older = try await s.streamLatest("orders", count: 10, before: latest.last!.id)
        #expect(older.count == 2)
        #expect(try await s.streamRange("orders", start: "", end: "", count: 100).count == 5)

        let groups = try await s.streamGroups("orders")
        #expect(groups.map(\.name) == ["billing"])
        #expect(groups.first?.pending == 1)
        let consumers = try await s.streamConsumers("orders", group: "billing")
        #expect(consumers.map(\.name) == ["c1"])
        let pending = try await s.streamPending("orders", group: "billing")
        #expect(pending.count == 1 && pending.first?.consumer == "c1")
        let info = try await s.streamInfo("orders")
        #expect(info.contains { $0.0 == "length" && $0.1 == "5" })

        // 실시간 보기: 새 항목이 들어오면 받는다
        let tail = try await s.streamTail("orders")
        let got = Task { () -> String? in
            for try await e in tail { return e.fields.first?.1 }
            return nil
        }
        try await Task.sleep(for: .milliseconds(300))
        try await s.command(["XADD", "orders", "*", "order_id", "99"])
        #expect(try await got.value == "99")
        await s.close()
    }

    @Test func pubSub() async throws {
        let s = try await session()
        let sub = try await s.subscriber()
        sub.subscribe(["news"])
        sub.psubscribe(["evt:*"])
        let collected = Task { () -> [RedisPubSubMessage] in
            var out: [RedisPubSubMessage] = []
            for await m in sub.messages {
                out.append(m)
                if out.filter({ $0.kind != "subscribe" && $0.kind != "psubscribe" }).count == 2 { break }
            }
            return out
        }
        try await Task.sleep(for: .milliseconds(300))
        let channels = try await s.activeChannels()
        #expect(channels.contains { $0.0 == "news" && $0.1 == 1 })
        #expect(try await s.publish("news", "안녕") == 1)
        #expect(try await s.publish("evt:login", "u1") == 1)
        let msgs = try await collected.value
        #expect(msgs.contains { $0.kind == "message" && $0.channel == "news" && $0.payload == "안녕" })
        #expect(msgs.contains { $0.kind == "pmessage" && $0.pattern == "evt:*" && $0.channel == "evt:login" })
        await sub.close()
        await s.close()
    }
}
