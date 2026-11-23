import Foundation
import Testing
@testable import GodDBCore

@Suite("QueryHistory")
struct QueryHistoryTests {
    /// 실제 키체인 대신 메모리 키
    let crypto = LocalDataCrypto(provider: StaticLocalDataKeyProvider())

    func tempFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("goddb-\(UUID().uuidString)/\(name)")
    }

    @Test func appendsNewestFirstAndPersists() {
        let file = tempFile("history.jsonl")
        let p = UUID()
        let h = QueryHistory(file: file, crypto: crypto)
        h.append(HistoryEntry(profileID: p, profileName: "a", database: "shop", sql: "SELECT 1", elapsedMs: 3, ok: true))
        h.append(HistoryEntry(profileID: p, profileName: "a", database: "shop", sql: "SELECT 2", elapsedMs: 4, ok: false))
        #expect(h.all().map(\.sql) == ["SELECT 2", "SELECT 1"])
        // 새로 읽어도 같다
        #expect(QueryHistory(file: file, crypto: crypto).all().map(\.sql) == ["SELECT 2", "SELECT 1"])
    }

    @Test func trimsToMaxEntries() {
        let file = tempFile("history.jsonl")
        let h = QueryHistory(file: file, maxEntries: 10, crypto: crypto)
        for i in 0..<25 {
            h.append(HistoryEntry(profileID: UUID(), profileName: "a", database: "", sql: "SELECT \(i)", elapsedMs: 1, ok: true))
        }
        let all = QueryHistory(file: file, maxEntries: 10, crypto: crypto).all()
        #expect(all.count <= 10)
        #expect(all.first?.sql == "SELECT 24")
    }

    @Test func filtersByWordsAndProfile() {
        let a = UUID(), b = UUID()
        let list = [
            HistoryEntry(profileID: a, profileName: "a", database: "shop", sql: "select * from orders where id = 1", elapsedMs: 1, ok: true),
            HistoryEntry(profileID: b, profileName: "b", database: "crm", sql: "UPDATE users SET x = 1", elapsedMs: 1, ok: true),
        ]
        #expect(QueryHistory.filter(list, query: "ORDERS id", profileID: nil).count == 1)
        #expect(QueryHistory.filter(list, query: "", profileID: b).map(\.profileName) == ["b"])
        #expect(QueryHistory.filter(list, query: "crm", profileID: nil).count == 1)
        #expect(QueryHistory.filter(list, query: "orders", profileID: b).isEmpty)
    }

    @Test func tabStoreRoundTrip() {
        let store = TabStore(file: tempFile("tabs.json"), crypto: crypto)
        let tabs = [SavedTab(profileID: UUID(), database: "shop", number: 2, title: nil, text: "SELECT 1;", selected: true)]
        store.save(tabs)
        #expect(store.load() == tabs)
    }
}
