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
