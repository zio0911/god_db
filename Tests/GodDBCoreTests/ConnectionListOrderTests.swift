import Foundation
import Testing
@testable import GodDBCore

/// 사이드바 접속 목록 찾기 · 정렬 (#173)
@Suite("Connection list order")
struct ConnectionListOrderTests {
    func profile(_ name: String, _ kind: DatabaseKind = .mysql, group: String = "", host: String = "h.example.test",
                 db: String = "", last: TimeInterval? = nil) -> ConnectionProfile {
        var p = ConnectionProfile(kind: kind, name: name, host: host, port: kind.defaultPort, database: db)
        p.group = group
        p.lastConnectedAt = last.map { Date(timeIntervalSince1970: $0) }
        return p
    }

    @Test func findsByNameHostDatabaseGroupAndType() {
        var p = profile("주문 DB", .postgres, group: "운영", host: "orders.example.test", db: "shop")
        p.ssh = SSHConfig(host: "bastion.example.test")
        p.environment = .production
        for q in ["주문", "ORDERS", "shop", "운영", "postgres", "PostgreSQL", "bastion", "주문 shop", ""] {
            #expect(ConnectionListOrder.matches(p, query: q), "\(q)")
        }
        #expect(!ConnectionListOrder.matches(p, query: "회원"))
        #expect(!ConnectionListOrder.matches(p, query: "주문 회원"))  // 낱말이 모두 들어 있어야
    }

    @Test func sortsByEachOrder() {
        let a = profile("b-mysql", .mysql, last: 100)
        let b = profile("a-redis", .redis)
        let c = profile("c-pg", .postgres, last: 300)
        let d = profile("A-pg", .postgres, last: 200)
        let all = [a, b, c, d]
        func names(_ s: ConnectionSort, connectedFirst: Bool = false, connected: Set<UUID> = []) -> [String] {
            ConnectionListOrder.sorted(all, by: s, connectedFirst: connectedFirst, isConnected: { connected.contains($0) }).map(\.name)
        }
        #expect(names(.manual) == ["b-mysql", "a-redis", "c-pg", "A-pg"])
        #expect(names(.name) == ["A-pg", "a-redis", "b-mysql", "c-pg"])
        #expect(names(.recent) == ["c-pg", "A-pg", "b-mysql", "a-redis"])  // 연결한 적 없으면 뒤
        #expect(names(.type) == ["b-mysql", "A-pg", "c-pg", "a-redis"])
        #expect(names(.name, connectedFirst: true, connected: [c.id, a.id]) == ["b-mysql", "c-pg", "A-pg", "a-redis"])
    }

    @Test func groupOrder() {
        let ps = [profile("1", group: "운영", last: 10), profile("2", group: "개발", last: 50),
                  profile("3"), profile("4", group: "운영", last: 90), profile("5", group: "기타")]
        #expect(ConnectionListOrder.sortedGroups(ps, by: .name) == ["개발", "기타", "운영"])
        #expect(ConnectionListOrder.sortedGroups(ps, by: .manual) == ["운영", "개발", "기타"])
        #expect(ConnectionListOrder.sortedGroups(ps, by: .recent) == ["운영", "개발", "기타"])
    }

    @Test func manualMoves() {
        let ps = [profile("a"), profile("g1", group: "운영"), profile("b"), profile("g2", group: "운영"), profile("c")]
        func names(_ x: [ConnectionProfile]) -> [String] { x.map(\.name) }
        let id = { (n: String) in ps.first { $0.name == n }!.id }
        // 같은 그룹 안에서만 움직인다
        #expect(names(ConnectionListOrder.moved(ps, id("c"), .up)) == ["a", "g1", "c", "b", "g2"])
        #expect(names(ConnectionListOrder.moved(ps, id("c"), .top)) == ["c", "a", "g1", "b", "g2"])
        #expect(names(ConnectionListOrder.moved(ps, id("g1"), .down)) == ["a", "b", "g2", "g1", "c"])
        #expect(names(ConnectionListOrder.moved(ps, id("a"), .up)) == names(ps))        // 이미 맨 위
        #expect(names(ConnectionListOrder.moved(ps, id("g2"), .bottom)) == names(ps))   // 이미 맨 아래
        // 끌어다 놓기: 놓은 접속 앞으로, 그 그룹으로
        let dropped = ConnectionListOrder.moved(ps, id("c"), before: id("g1"))
        #expect(names(dropped) == ["a", "c", "g1", "b", "g2"])
        #expect(dropped.first { $0.name == "c" }?.group == "운영")
        #expect(names(ConnectionListOrder.moved(ps, id("a"), before: id("a"))) == names(ps))
        // 보이는 순서 그대로 (그룹 없는 접속 → 그룹)
        #expect(names(ConnectionListOrder.visibleOrder(ps, by: .name)) == ["a", "b", "c", "g1", "g2"])
    }

    @Test func lastConnectedIsSavedAndOldFilesRead() throws {
        var p = profile("x", last: 1_700_000_000)
        let back = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(p))
        #expect(back.lastConnectedAt == p.lastConnectedAt)
        p.lastConnectedAt = nil
        let old = #"{"id":"6F1C2A6E-1B8B-4B6E-9C55-0C1F0E6A9A10","kind":"mysql","name":"a","host":"h","port":3306,"username":"u"}"#
        #expect(try JSONDecoder().decode(ConnectionProfile.self, from: Data(old.utf8)).lastConnectedAt == nil)
    }

    @Test func translated() {
        for s in ConnectionSort.allCases { #expect(L10nEnglish.table[s.title] != nil) }
        #expect(String(format: L10nEnglish.table["%@개 중 %@개"]!, "5", "2") == "5 total · 2 shown")
    }
}
