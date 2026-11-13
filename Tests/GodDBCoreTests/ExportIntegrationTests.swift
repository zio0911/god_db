import Foundation
import Testing
@testable import GodDBCore

/// 여러 페이지짜리 결과를 페이지 단위로 전체 내보내기 (실제 DB). test-dbs.sh test 로 실행.
@Suite("Export integration", .serialized)
struct ExportIntegrationTests {
    static let rows = 12_345

    func session(_ kind: DatabaseKind) async throws -> DBSession? {
        let env = ProcessInfo.processInfo.environment
        switch kind {
        case .mysql:
            guard let port = env["GODDB_IT_PORT"].flatMap(Int.init) else { return nil }
            let p = ConnectionProfile(name: "it", host: "127.0.0.1", port: port, username: "root", database: "shop", useTLS: true)
            return try await DBSession.connect(profile: p, password: env["GODDB_IT_PASSWORD"] ?? "")
        default:
            if kind == .mssql, let (p, pw) = MultiDB.profile(.mssql, database: "master") {
                let admin = try await DBSession.connect(profile: p, password: pw)
                _ = try await admin.raw("IF DB_ID('shop') IS NULL CREATE DATABASE shop")
                await admin.close()
            }
            guard let (p, pw) = MultiDB.profile(kind, database: "shop") else { return nil }
            return try await DBSession.connect(profile: p, password: pw)
        }
    }

    func seed(_ s: DBSession, _ kind: DatabaseKind) async throws {
        let n = Self.rows
        switch kind {
        case .mysql:
            _ = try await s.raw("DROP TABLE IF EXISTS tb_export_it")
            _ = try await s.raw("CREATE TABLE tb_export_it (id int PRIMARY KEY, name varchar(50))")
            _ = try await s.raw("SET SESSION cte_max_recursion_depth = 100000")
            _ = try await s.raw("INSERT INTO tb_export_it WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(n)) SELECT i, CONCAT('이름', i) FROM n")
        case .postgres:
            _ = try await s.raw("DROP TABLE IF EXISTS tb_export_it")
            _ = try await s.raw("CREATE TABLE tb_export_it (id int PRIMARY KEY, name varchar(50))")
            _ = try await s.raw("INSERT INTO tb_export_it SELECT i, '이름' || i FROM generate_series(1, \(n)) i")
        case .mssql:
            _ = try await s.raw("IF OBJECT_ID('tb_export_it') IS NOT NULL DROP TABLE tb_export_it")
            _ = try await s.raw("CREATE TABLE tb_export_it (id int PRIMARY KEY, name nvarchar(50))")
            _ = try await s.raw("""
                INSERT INTO tb_export_it SELECT TOP (\(n)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), N'이름' + CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS nvarchar(10))
                FROM sys.all_objects a CROSS JOIN sys.all_objects b
                """)
        case .redis: return
        }
    }

    @Test(arguments: [DatabaseKind.mysql, .postgres, .mssql])
    func exportsEveryRowAcrossPages(_ kind: DatabaseKind) async throws {
        guard let s = try await session(kind) else { return }
        defer { Task { await s.close() } }
        try await seed(s, kind)
        let sql = "SELECT id, name FROM tb_export_it"
        let plan = ResultExportPlan.stableSort(sql: sql, serverSort: nil, columns: ["id", "name"], primaryKey: ["id"])
        #expect(plan.stable)
        #expect(try await s.count(sql) == Self.rows)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-export-it-\(kind.rawValue).csv")
        var opts = ExportOptions(); opts.excelBOM = false
        let w = try ResultExportWriter(format: .csv, columns: ["id", "name"], url: url, options: opts)
        let truncated = try await s.exportAll(sql, sort: plan.sort, chunk: 5_000, to: w)
        try w.finish()
        #expect(!truncated)
        #expect(w.rowsWritten == Self.rows)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\r\n").dropFirst()
        let ids = lines.compactMap { Int($0.split(separator: ",").first ?? "") }
        #expect(ids.count == Self.rows)
        #expect(Set(ids).count == Self.rows)            // 겹친 행 없음
        #expect(ids == Array(1...Self.rows))            // 빠진 행 없음, 기본 키 순서
        #expect(lines.first == "1,이름1")
    }
}
