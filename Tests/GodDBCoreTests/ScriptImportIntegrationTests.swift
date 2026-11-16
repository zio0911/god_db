import Foundation
import Testing
@testable import GodDBCore

/// DELIMITER / GO 스크립트 실행, CSV 가져오기 (실제 DB). 환경변수가 없으면 건너뛴다.
@Suite("Script & import integration", .serialized)
struct ScriptImportIntegrationTests {
    func session(_ kind: DatabaseKind) async throws -> DBSession? {
        try await ExportIntegrationTests().session(kind)
    }

    @Test func mysqlDelimiterProcedure() async throws {
        guard let s = try await session(.mysql) else { return }
        defer { Task { await s.close() } }
        let script = """
        DROP PROCEDURE IF EXISTS p_delim_it;
        DELIMITER $$
        CREATE PROCEDURE p_delim_it(OUT answer INT)
        BEGIN
          DECLARE x INT DEFAULT 1;
          SET answer = x + 41;
        END$$
        DELIMITER ;
        CALL p_delim_it(@answer);
        SELECT @answer;
        """
        var last: QueryResult?
        for st in SQLText.statements(in: script).map(\.sql) { last = try await s.execute(st, limit: 0) }
        #expect(last?.rows.first?.values.first == "42")
        _ = try await s.raw("DROP PROCEDURE p_delim_it")
    }

    @Test func mssqlGoBatches() async throws {
        guard let s = try await session(.mssql) else { return }
        defer { Task { await s.close() } }
        let script = """
        IF OBJECT_ID('dbo.p_go_it') IS NOT NULL DROP PROCEDURE dbo.p_go_it;
        GO
        CREATE PROCEDURE dbo.p_go_it AS
        BEGIN
          DECLARE @x int = 1;
          SELECT @x + 41 AS answer;
        END
        GO
        EXEC dbo.p_go_it;
        """
        var last: QueryResult?
        for st in SQLText.statements(in: script).map(\.sql) { last = try await s.execute(st, limit: 0) }
        #expect(last?.rows.first?.values.first == "42")
        _ = try await s.raw("DROP PROCEDURE dbo.p_go_it")
    }

    @Test(arguments: [DatabaseKind.mysql, .postgres, .mssql])
    func csvImportInOneTransaction(_ kind: DatabaseKind) async throws {
        guard let s = try await session(kind) else { return }
        defer { Task { await s.close() } }
        let d = s.dialect
        _ = try? await s.raw(d.dropTableSQL("tb_csv_it"))
        _ = try await s.raw("CREATE TABLE tb_csv_it (id int PRIMARY KEY, name varchar(50), note varchar(50))")
        let csv = "ID,Name,Ignored\n1,\"Kim, A\",x\n2,,y\n3,O'Neil,z\n"
        let rows = CSVImport.parse(csv, delimiter: CSVImport.detectDelimiter(csv))
        let mapping = CSVImport.autoMap(header: rows[0], csvColumns: 3, tableColumns: ["id", "name", "note"])
        try await s.executeInTransaction(CSVImport.inserts(table: "tb_csv_it", mapping: mapping, rows: Array(rows.dropFirst()), dialect: d, batch: 2))
        let r = try await s.raw("SELECT id, name FROM tb_csv_it ORDER BY id").rows
        #expect(r.count == 3)
        #expect(r[0][1] == "Kim, A")
        #expect(r[1][1] == nil)
        #expect(r[2][1] == "O'Neil")
        // 중복 키가 있으면 모두 되돌린다
        let bad = CSVImport.inserts(table: "tb_csv_it", mapping: ["id", "name", nil], rows: [["4", "a", ""], ["1", "dup", ""]], dialect: d)
        var failed = false
        do { try await s.executeInTransaction(bad) } catch { failed = true }
        #expect(failed)
        #expect(try await s.raw("SELECT COUNT(*) FROM tb_csv_it").rows.first?.first == "3")
        _ = try await s.raw(d.dropTableSQL("tb_csv_it"))
    }
}
