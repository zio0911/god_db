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

    @Test func scriptLines() {
        let text = "// 큐에 넣기\nRPUSH queue a b\n\n  # 확인\n  LRANGE queue 0 -1  \nSET k \"a b\""
        #expect(RedisText.scriptLines(text) == ["RPUSH queue a b", "LRANGE queue 0 -1", "SET k \"a b\""])
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

@Suite("Redis key tree")
struct RedisKeyTreeTests {
    @Test func groupsByDelimiter() {
        let t = RedisKeyTree.build(["user:10:name", "user:2:name", "user:2:email", "user:2", "session:abc", "plain"])
        #expect(t.map(\.name) == ["session", "user", "plain"])
        #expect(t[1].count == 4)
        let user = t[1].children!
        // 숫자 순서, 폴더 먼저, 같은 이름의 키(user:2)는 폴더 뒤에
        #expect(user.map(\.id) == ["f:user:2", "f:user:10", "k:user:2"])
        #expect(user[0].children!.map(\.key) == ["user:2:email", "user:2:name"])
        #expect(t[2].key == "plain" && t[2].children == nil)
    }

    @Test func otherDelimiterAndEdgeCases() {
        let t = RedisKeyTree.build(["a/b/c", "a/d", "x::y"], delimiter: "/")
        #expect(t.map(\.name) == ["a", "x::y"])
        let colon = RedisKeyTree.build(["x::y"])
        #expect(colon.first?.children?.first?.name == "")   // 빈 조각 폴더
        #expect(RedisKeyTree.build(["k"], delimiter: "").first?.key == "k")
    }

    @Test func folderPattern() {
        #expect(RedisKeyTree.pattern(forFolder: "user:1001") == "user:1001:*")
        #expect(RedisKeyTree.pattern(forFolder: "a*b") == "a\\*b:*")
    }
}

@Suite("Redis cluster math")
struct RedisClusterMathTests {
    @Test func crcAndSlots() {
        #expect(RedisCluster.crc16(Array("123456789".utf8)) == 0x31C3)
        #expect(RedisCluster.slot("foo") == 12182)
        #expect(RedisCluster.slot("bar") == 5061)
        #expect(RedisCluster.slot("{user1000}.following") == RedisCluster.slot("{user1000}.followers"))
        #expect(RedisCluster.slot("{}x") == RedisCluster.slot("{}x"))   // 빈 태그는 키 전체
    }

    @Test func routingKeys() {
        #expect(RedisCluster.routingKey(["GET", "k"]) == "k")
        #expect(RedisCluster.routingKey(["INFO"]) == nil)
        #expect(RedisCluster.routingKey(["MEMORY", "USAGE", "k"]) == "k")
        #expect(RedisCluster.routingKey(["XINFO", "GROUPS", "s"]) == "s")
        #expect(RedisCluster.routingKey(["XREAD", "COUNT", "1", "BLOCK", "0", "STREAMS", "s", "$"]) == "s")
        #expect(RedisCluster.routingKey(["EVAL", "return 1", "1", "k"]) == "k")
        #expect(RedisCluster.routingKey(["SCAN", "0"]) == nil)
    }

    @Test func slotsAndRedirects() {
        let v = RESPValue.array([
            .array([.integer(5461), .integer(10922), .array([.bulk(Array("10.0.0.2".utf8)), .integer(6379)])]),
            .array([.integer(0), .integer(5460), .array([.bulk(Array("".utf8)), .integer(7000)]),
                    .array([.bulk(Array("10.0.0.9".utf8)), .integer(7003)])]),
        ])
        let s = RedisCluster.parseSlots(v, seedHost: "seed")
        #expect(s.map(\.master) == ["seed:7000", "10.0.0.2:6379"])
        #expect(s[0].replicas == ["10.0.0.9:7003"])
        #expect(RedisCluster.redirect("MOVED 3999 127.0.0.1:6381") == .moved(slot: 3999, address: "127.0.0.1:6381"))
        #expect(RedisCluster.redirect("ASK 1 h:1") == .ask(slot: 1, address: "h:1"))
        #expect(RedisCluster.redirect("ERR x y") == nil)
        #expect(RedisCluster.split("[::1]:6379")! == ("::1", 6379))
        #expect(RedisCluster.sentinelAddresses("a:26380, b", defaultPort: 26379).map { "\($0.host):\($0.port)" } == ["a:26380", "b:26379"])
    }
}

/// 실제 Redis Cluster (./scripts/test-dbs.sh up → 127.0.0.1:37000~37002) / Sentinel (36381 → mymaster)
@Suite("Redis cluster & sentinel", .serialized)
struct RedisClusterIntegrationTests {
    static let env = ProcessInfo.processInfo.environment

    func profile(_ mode: RedisMode, port: Int) -> ConnectionProfile {
        var p = ConnectionProfile(kind: .redis, name: "it", host: "127.0.0.1", port: port, username: "", database: "", useTLS: false)
        p.redisMode = mode
        p.sentinelMaster = "mymaster"
        return p
    }

    @Test(.enabled(if: env["GODDB_REDIS_CLUSTER_PORT"] != nil))
    func clusterRoutesScansAndFollowsMoved() async throws {
        let port = Int(Self.env["GODDB_REDIS_CLUSTER_PORT"]!)!
        // "단일"로 설정해도 자동으로 Cluster 를 알아챈다
        let s = try await RedisSession.connect(profile: profile(.standalone, port: port), password: "goddbtest")
        #expect(await s.isCluster)
        #expect(await s.masterNodes.count == 3)
        // 여러 노드에 흩어지는 키들
        let keys = (0..<60).map { "it:cluster:\($0)" }
        for k in keys { try await s.command(["SET", k, "v-\(k)"]) }
        try await s.command(["HSET", "it:cluster:h", "f", "1"])
        for k in keys { #expect(try await s.string(k) == "v-\(k)") }
        let found = try await s.scanKeys(pattern: "it:cluster:*", limit: 10_000)
        #expect(Set(found.keys) == Set(keys + ["it:cluster:h"]))
        #expect(try await s.dbSize() >= 61)
        #expect(try await s.databases().map(\.index) == [0])
        let meta = try await s.keyMeta(["it:cluster:1", "it:cluster:h", "nope"])
        #expect(meta["it:cluster:h"]?.type == "hash" && meta["nope"]?.type == "none")
        #expect(try await s.keyInfo("it:cluster:h").type == "hash")
        // 콘솔: 다른 노드의 키도 MOVED 없이
        for k in keys.prefix(10) {
            let v = try await s.console(["GET", k])
            #expect(v == .bulk(Array("v-\(k)".utf8)))
        }
        await #expect(throws: RedisCommandError.clusterSingleDB) { try await s.console(["SELECT", "1"]) }
        // 노드별 INFO
        for n in await s.masterNodes {
            #expect(try await s.info("server", node: n).first?.1.contains { $0.0 == "tcp_port" } == true)
        }
        // Pub/Sub 은 아무 노드에서
        let sub = try await s.subscriber()
        sub.subscribe(["it:news"])
        let got = Task { () -> String? in
            for await m in sub.messages where m.kind == "message" { return m.payload }
            return nil
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await s.publish("it:news", "hello")
        #expect(await got.value == "hello")
        await sub.close()
        for k in keys { try await s.command(["DEL", k]) }
        try await s.command(["DEL", "it:cluster:h"])
        await s.close()
    }

    @Test(.enabled(if: env["GODDB_REDIS_SENTINEL_PORT"] != nil))
    func sentinelResolvesMaster() async throws {
        let port = Int(Self.env["GODDB_REDIS_SENTINEL_PORT"]!)!
        let s = try await RedisSession.connect(profile: profile(.sentinel, port: port), password: "goddbtest")
        #expect(await s.topology == .sentinel(master: "mymaster", address: "127.0.0.1:36380"))
        try await s.command(["SET", "it:sentinel", "ok"])
        #expect(try await s.string("it:sentinel") == "ok")
        await s.close()

        var bad = profile(.sentinel, port: port)
        bad.sentinelMaster = "nope"
        await #expect(throws: RedisCommandError.sentinelMasterNotFound("nope")) {
            _ = try await RedisSession.connect(profile: bad, password: "goddbtest")
        }
    }
}

@Suite("Redis key tree rows")
struct RedisKeyTreeRowsTests {
    @Test func visibleRowsFollowExpandedFolders() {
        let tree = RedisKeyTree.build(["user:1:name", "user:1:age", "user:2:name", "session:x", "plain"])
        // 접힌 상태: 최상위만
        let top = RedisKeyTree.visibleRows(tree, expanded: [])
        #expect(top.map(\.id) == ["f:session", "f:user", "k:plain"])
        #expect(top.allSatisfy { $0.depth == 0 })
        // user, user:1 펼침
        let open = RedisKeyTree.visibleRows(tree, expanded: ["f:user", "f:user:1"])
        #expect(open.map(\.id) == ["f:session", "f:user", "f:user:1", "k:user:1:age", "k:user:1:name", "f:user:2", "k:plain"])
        #expect(open.first { $0.id == "k:user:1:age" }?.depth == 2)
        // 행 id 는 겹치지 않는다
        #expect(Set(open.map(\.id)).count == open.count)
        // 없어진 폴더가 펼침 목록에 남아 있어도 문제없다
        #expect(RedisKeyTree.visibleRows(tree, expanded: ["f:gone"]).count == 3)
    }
}
