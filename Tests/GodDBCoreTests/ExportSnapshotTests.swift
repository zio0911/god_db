import Foundation
import Testing
@testable import GodDBCore

/// 전체 내보내기: 페이지 사이에 다른 연결이 앞쪽에 행을 넣어도, 처음 시점 그대로 겹침 · 빠짐 없이 (#199)
@Suite("Export snapshot", .serialized)
struct ExportSnapshotTests {
    static let env = ProcessInfo.processInfo.environment

    func run(_ profile: ConnectionProfile, _ password: String) async throws {
        let admin = try await DBSession.connect(profile: profile, password: password)
        let reader = try await DBSession.connect(profile: profile, password: password)
        defer { Task { _ = try? await admin.raw("DROP TABLE IF EXISTS goddb_snap"); await admin.close(); await reader.close() } }
        _ = try await admin.raw("DROP TABLE IF EXISTS goddb_snap")
        _ = try await admin.raw("CREATE TABLE goddb_snap (id INT PRIMARY KEY)")
        _ = try await admin.raw("INSERT INTO goddb_snap VALUES (10), (20), (30), (40), (50), (60)")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-snap-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ResultExportWriter(format: .csv, columns: ["id"], url: url)
        let inserted = Inserted()
        try await reader.exportAll("SELECT id FROM goddb_snap ORDER BY id", sort: nil, chunk: 2, to: writer) { written in
            // 첫 페이지를 받은 뒤 다른 연결에서 맨 앞에 두 행 추가 → OFFSET 이 두 칸 밀린다
            if written == 2, await inserted.once() {
                _ = try? await admin.raw("INSERT INTO goddb_snap VALUES (1), (2)")
            }
        }
        try writer.finish()
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst().map(String.init)
        #expect(lines == ["10", "20", "30", "40", "50", "60"], "\(lines)")
        #expect(await inserted.done)
    }

    actor Inserted {
        var done = false
        func once() -> Bool { defer { done = true }; return !done }
    }

    @Test(.enabled(if: env["GODDB_PG_PORT"] != nil))
    func postgres() async throws {
        let (p, pw) = try #require(MultiDB.profile(.postgres, database: "shop"))
        try await run(p, pw)
    }

    @Test(.enabled(if: env["GODDB_IT_PORT"] != nil))
    func mysql() async throws {
        let p = ConnectionProfile(name: "my", host: "127.0.0.1", port: Int(Self.env["GODDB_IT_PORT"]!)!, username: "root",
                                  database: "shop", useTLS: false)
        try await run(p, Self.env["GODDB_IT_PASSWORD"] ?? "")
    }
}
