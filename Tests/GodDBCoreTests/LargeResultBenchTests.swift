import Foundation
import Testing
@testable import GodDBCore

/// 대용량 결과 측정 (GODDB_BENCH_MSSQL_PORT 가 있을 때만). 화면을 쓰지 않는다.
/// 준비: SQL Server 에 GODDB_BENCH DB 와 100만 행 tb_bench_member (member_id bigint PK + 컬럼 9개) 를 만든다.
/// 실행: GODDB_BENCH_MSSQL_PORT=1433 GODDB_BENCH_PASSWORD=… ./scripts/test.sh --filter LargeResultBench
@Suite("Large result bench", .serialized)
struct LargeResultBenchTests {
    func session() async throws -> DBSession? {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["GODDB_BENCH_MSSQL_PORT"].flatMap(Int.init) else { return nil }
        let p = ConnectionProfile(kind: .mssql, name: "bench", host: "127.0.0.1", port: port,
                                  username: "sa", database: "GODDB_BENCH", useTLS: false)
        return try await DBSession.connect(profile: p, password: env["GODDB_BENCH_PASSWORD"] ?? "")
    }

    func rss() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return Double(info.resident_size) / 1_048_576
    }

    /// 화면 "제한 없음" 이어 받기: 1,000행씩 200페이지 (메모리 상한 200,000행)
    @Test(arguments: ["SELECT * FROM tb_bench_member", "SELECT * FROM tb_bench_member ORDER BY member_id"])
    func gridAppend(_ sql: String) async throws {
        guard let s = try await session() else { return }
        defer { Task { await s.close() } }
        let m0 = rss()
        var rows: [QueryResult.Row] = []
        let t0 = Date()
        var marks: [String] = []
        for page in 0..<200 {
            let p0 = Date()
            let r = try await s.execute(sql, limit: 1_000, page: page)
            rows += r.rows
            if [0, 49, 99, 199].contains(page) {
                marks.append("p\(page + 1): \(Int(Date().timeIntervalSince(p0) * 1000))ms")
            }
        }
        let ids = Set(rows.compactMap { $0.values.first ?? nil })
        #expect(ids.count == 200_000)   // 페이지 사이에 겹치거나 빠진 행 없음
        print("BENCH grid [\(sql.contains("ORDER") ? "ORDER BY" : "no ORDER BY")] rows=\(rows.count) total=\(String(format: "%.1f", Date().timeIntervalSince(t0)))s  \(marks.joined(separator: ", "))  rss +\(Int(rss() - m0))MB")
    }

    @Test(arguments: [ExportFormat.csv, .xlsx])
    func exportMillion(_ format: ExportFormat) async throws {
        guard let s = try await session() else { return }
        defer { Task { await s.close() } }
        let sql = "SELECT * FROM tb_bench_member"
        let cols = ["member_id","member_name","email","phone","grade","point","balance","memo","created_at","updated_at"]
        let plan = ResultExportPlan.stableSort(sql: sql, serverSort: nil, columns: cols, primaryKey: ["member_id"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-bench.\(format.fileExtension)")
        let w = try ResultExportWriter(format: format, columns: cols, url: url, options: ExportOptions(),
                                       dialect: MSSQLDialect())
        let m0 = rss(); var peak = m0
        let t0 = Date()
        var marks: [String] = []
        var last = Date()
        try await s.exportAll(sql, sort: plan.sort, chunk: 5_000, to: w) { n in
            if n % 250_000 == 0 { marks.append("\(n / 1000)k@\(String(format: "%.1f", Date().timeIntervalSince(t0)))s") }
            _ = last; last = Date()
        }
        peak = max(peak, rss())
        let tw = Date().timeIntervalSince(t0)
        try w.finish()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("BENCH export \(format.rawValue) rows=\(w.rowsWritten) fetch+write=\(String(format: "%.1f", tw))s finish=\(String(format: "%.1f", Date().timeIntervalSince(t0) - tw))s size=\(size / 1_048_576)MB rss +\(Int(peak - m0))MB  \(marks.joined(separator: ", "))")
    }
}
