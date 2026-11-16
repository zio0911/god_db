import Foundation
import Testing
@testable import GodDBCore

/// 빠른 찾기용 모든 스키마 테이블 목록 (실제 DB). 환경변수가 없으면 건너뛴다.
@Suite("QuickOpen integration", .serialized)
struct QuickOpenIntegrationTests {
    @Test(arguments: [DatabaseKind.mysql, .postgres, .mssql])
    func listsTablesAcrossSchemas(_ kind: DatabaseKind) async throws {
        guard let s = try await ExportIntegrationTests().session(kind) else { return }
        defer { Task { await s.close() } }
        if kind == .mssql {
            _ = try await s.raw("IF OBJECT_ID('tb_qo_it') IS NULL CREATE TABLE tb_qo_it (id int)")
        } else {
            _ = try await s.raw("CREATE TABLE IF NOT EXISTS tb_qo_it (id int)")
        }
        let all = try await s.allTables()
        if kind == .mssql {
            #expect(all.isEmpty)   // SQL Server 는 지금 DB 의 사이드바 목록으로 찾는다
        } else {
            #expect(all.contains { $0.name == "tb_qo_it" && !$0.isView })
            #expect(!all.contains { ["mysql", "information_schema", "pg_catalog"].contains($0.schema) })
        }
    }
}
