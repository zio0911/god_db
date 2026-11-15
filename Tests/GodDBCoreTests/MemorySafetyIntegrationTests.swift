import Foundation
import Testing
@testable import GodDBCore

/// 큰 값 · 큰 결과 (실제 DB). test-dbs.sh test 로 실행, 환경변수가 없으면 건너뛴다.
@Suite("Memory safety integration", .serialized)
struct MemorySafetyIntegrationTests {
    @Test func bigCellsAreCappedInGridButNotInExport() async throws {
        guard let s = try await ExportIntegrationTests().session(.mysql) else { return }
        defer { Task { await s.close() } }
        _ = try await s.raw("DROP TABLE IF EXISTS tb_big_it")
        _ = try await s.raw("CREATE TABLE tb_big_it (id int PRIMARY KEY, body longtext)")
        _ = try await s.raw("SET GLOBAL max_allowed_packet = 67108864")
        _ = try await s.raw("INSERT INTO tb_big_it VALUES (1, REPEAT('가', 1500000)), (2, 'small')")
        let r = try await s.execute("SELECT id, body FROM tb_big_it ORDER BY id", limit: 500)
        #expect(r.truncatedCells == 1)
        #expect(r.rows[0].values[1]?.count == DBSession.maxCellCharacters + 1)   // 앞부분 + …
        #expect(r.rows[1].values[1] == "small")
        // 내보내기는 자르지 않는다
        let full = try await s.execute("SELECT id, body FROM tb_big_it ORDER BY id", limit: 500, capCells: false)
        #expect(full.truncatedCells == 0 && full.rows[0].values[1]?.count == 1_500_000)
    }

    @Test func pagesStreamWithoutGaps() async throws {
        guard let s = try await ExportIntegrationTests().session(.mysql) else { return }
        defer { Task { await s.close() } }
        _ = try await s.raw("DROP TABLE IF EXISTS tb_stream_it")
        _ = try await s.raw("CREATE TABLE tb_stream_it (id int PRIMARY KEY)")
        _ = try await s.raw("SET SESSION cte_max_recursion_depth = 100000")
        _ = try await s.raw("INSERT INTO tb_stream_it WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3500) SELECT i FROM n")
        // 보이지 않는 페이징: 1,000행씩 이어 붙이기
        var all: [Int] = []
        var page = 0
        while true {
            let r = try await s.execute("SELECT id FROM tb_stream_it ORDER BY id", limit: 1_000, page: page)
            all += r.rows.compactMap { $0.values[0].flatMap(Int.init) }
            if !r.hasMore { break }
            page += 1
        }
        #expect(all == Array(1...3500))
    }

    @Test func bigRedisStringIsReadPartially() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["GODDB_REDIS_PORT"].flatMap(Int.init) else { return }
        let p = ConnectionProfile(kind: .redis, name: "r", host: "127.0.0.1", port: port, username: "", database: "0", useTLS: false)
        let s = try await RedisSession.connect(profile: p, password: "goddbtest")
        defer { Task { await s.close() } }
        let big = String(repeating: "x", count: 3 * 1_048_576)
        try await s.command(["SET", "goddb:it:big", big])
        let r = try await s.stringPrefix("goddb:it:big")
        #expect(r.truncated && r.total == big.utf8.count && r.value.utf8.count == 1_048_576)
        try await s.command(["SET", "goddb:it:small", "hi"])
        let small = try await s.stringPrefix("goddb:it:small")
        #expect(!small.truncated && small.value == "hi")
        try await s.command(["DEL", "goddb:it:big", "goddb:it:small"])
    }
}
