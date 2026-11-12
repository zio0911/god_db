import Foundation
import Testing
@testable import GodDBCore

@Suite("Paging SQL")
struct PagingSQLTests {
    @Test func mysqlAndPostgres() {
        let my = MySQLDialect().pagedSQL("SELECT * FROM t;", limit: 500, offset: 1000)
        #expect(my == PagedSQL(sql: "SELECT * FROM t\nLIMIT 501 OFFSET 1000", skip: 0))
        #expect(PostgresDialect().pagedSQL("WITH x AS (SELECT 1) SELECT * FROM x", limit: 10, offset: 0)?.sql
                == "WITH x AS (SELECT 1) SELECT * FROM x\nLIMIT 11")
        #expect(MySQLDialect().pagedSQL("SELECT * FROM t LIMIT 5", limit: 500, offset: 0) == nil)
        #expect(MySQLDialect().pagedSQL("UPDATE t SET a = 1", limit: 500, offset: 0) == nil)
        #expect(MySQLDialect().pagedSQL("SELECT * FROM t FOR UPDATE", limit: 500, offset: 0) == nil)
        #expect(MySQLDialect().pagedSQL("SELECT 1", limit: 0, offset: 0) == nil)
    }

    @Test func mssqlWithAndWithoutOrderBy() {
        let d = MSSQLDialect()
        #expect(d.pagedSQL("SELECT * FROM t ORDER BY id", limit: 500, offset: 500)?.sql
                == "SELECT * FROM t ORDER BY id\nOFFSET 500 ROWS FETCH NEXT 501 ROWS ONLY")
        let noOrder = d.pagedSQL("SELECT * FROM t", limit: 500, offset: 1000)
        #expect(noOrder?.sql.contains("TOP 1501") == true)
        #expect(noOrder?.skip == 1000)
        // 서브쿼리 안의 ORDER BY 는 맨 바깥 ORDER BY 가 아니다
        #expect(d.pagedSQL("SELECT * FROM (SELECT TOP 10 * FROM t ORDER BY id) x", limit: 5, offset: 0) == nil)
        #expect(d.pagedSQL("SELECT TOP 10 * FROM t", limit: 500, offset: 0) == nil)
    }

    @Test func countSQL() {
        #expect(MySQLDialect().countSQL("SELECT * FROM t;") == "SELECT COUNT(*) FROM (\nSELECT * FROM t\n) AS goddb_cnt")
        #expect(MSSQLDialect().countSQL("SELECT * FROM t ORDER BY id")?.contains("ORDER BY") == false)
        #expect(MSSQLDialect().countSQL("SELECT * FROM (SELECT TOP 3 * FROM t ORDER BY id) x")?.contains("ORDER BY id") == true)
        #expect(MySQLDialect().countSQL("DELETE FROM t") == nil)
    }
}

extension MultiDBChecks {
    /// 세 DB 공통: 페이지 이동과 전체 행 수
    static func paging(_ s: DBSession, table: String) async throws {
        let sql = "SELECT member_id FROM \(s.dialect.quoteTable(table)) ORDER BY member_id"
        let p0 = try await s.execute(sql, limit: 2, page: 0)
        #expect(p0.rows.count == 2 && p0.hasMore && p0.page == 0 && p0.pageSize == 2)
        let p1 = try await s.execute(sql, limit: 2, page: 1)
        #expect(p1.rows.count == 1 && !p1.hasMore)
        #expect(p0.rows.map { $0.values[0] } + p1.rows.map { $0.values[0] } == ["1", "2", "3"])
        // ORDER BY 없는 쿼리도 (SQL Server 는 TOP + 앞부분 버리기)
        let noOrder = try await s.execute("SELECT member_id FROM \(s.dialect.quoteTable(table))", limit: 2, page: 1)
        #expect(noOrder.rows.count == 1)
        #expect(try await s.count(sql) == 3)
    }
}

@Suite("Rename / drop SQL")
struct RenameDropSQLTests {
    @Test func perDialect() {
        #expect(MySQLDialect().renameTableSQL("a", to: "b") == "RENAME TABLE `a` TO `b`;")
        #expect(PostgresDialect().renameTableSQL("a", to: "b") == "ALTER TABLE \"a\" RENAME TO \"b\";")
        #expect(MSSQLDialect().renameTableSQL("sales.a", to: "b") == "EXEC sp_rename N'[sales].[a]', N'b';")
        #expect(MSSQLDialect().dropTableSQL("a") == "DROP TABLE [a];")
    }
}

extension MultiDBChecks {
    /// 세 DB 공통: 테이블 이름 변경 후 삭제
    static func renameAndDrop(_ s: DBSession, container: String) async throws {
        let d = s.dialect
        _ = try await s.raw("CREATE TABLE tb_rename_it (id int PRIMARY KEY)")
        _ = try await s.raw(d.renameTableSQL("tb_rename_it", to: "tb_renamed_it"))
        var names = try await s.loadSchema(container).map(\.name)
        #expect(names.contains("tb_renamed_it") && !names.contains("tb_rename_it"))
        _ = try await s.raw(d.dropTableSQL("tb_renamed_it"))
        names = try await s.loadSchema(container).map(\.name)
        #expect(!names.contains("tb_renamed_it"))
    }
}

@Suite("Sort SQL")
struct SortSQLTests {
    @Test func wrapsAndReplacesOrderBy() {
        let s = ResultSort(column: "email", ascending: false)
        #expect(MySQLDialect().sortedSQL("SELECT * FROM t ORDER BY id;", sort: s)
                == "SELECT * FROM (\nSELECT * FROM t\n) AS goddb_sort ORDER BY `email` DESC")
        // LIMIT 이 있으면 원래 ORDER BY 를 둔다 (같은 결과 집합을 정렬)
        #expect(PostgresDialect().sortedSQL("SELECT * FROM t ORDER BY id LIMIT 5", sort: s)?.contains("ORDER BY id LIMIT 5") == true)
        #expect(MSSQLDialect().sortedSQL("SELECT * FROM t ORDER BY id", sort: s)
                == "SELECT * FROM (\nSELECT * FROM t\n) AS goddb_sort ORDER BY [email] DESC")
        #expect(MySQLDialect().sortedSQL("SHOW TABLES", sort: s) == nil)
    }

    @Test func clientCompare() {
        #expect(ResultSorting.compare("10", "9") == .orderedDescending)
        #expect(ResultSorting.compare(nil, "a") == .orderedAscending)
        let rows = [QueryResult.Row(id: 0, values: ["b"]), QueryResult.Row(id: 1, values: [nil]), QueryResult.Row(id: 2, values: ["a"])]
        #expect(ResultSorting.sorted(rows, column: 0, ascending: true).map(\.id) == [1, 2, 0])
    }
}

extension MultiDBChecks {
    /// 세 DB 공통: DB 에서 정렬 + 페이징 유지
    static func serverSort(_ s: DBSession, table: String) async throws {
        let sql = "SELECT member_id, email FROM \(s.dialect.quoteTable(table)) ORDER BY member_id"
        let desc = ResultSort(column: "member_id", ascending: false)
        let p0 = try await s.execute(sql, limit: 2, page: 0, sort: desc)
        #expect(p0.rows.map { $0.values[0] } == ["3", "2"])
        #expect(p0.serverSort == desc && p0.hasMore)
        let p1 = try await s.execute(sql, limit: 2, page: 1, sort: desc)
        #expect(p1.rows.map { $0.values[0] } == ["1"])
    }
}
