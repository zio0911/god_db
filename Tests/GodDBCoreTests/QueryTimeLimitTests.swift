import Foundation
import Testing
@testable import GodDBCore

/// 실행 시간 제한 기본 30분 · 서버 쪽 제한 (#198)
@Suite("Query time limit")
struct QueryTimeLimitTests {
    @Test func defaultIsThirtyMinutes() {
        #expect(QueryTimeLimit.defaultSeconds == 1800)
        #expect(QueryTimeLimit.key == "queryTimeoutSeconds")
    }

    @Test func serverSideSQL() {
        #expect(PostgresDialect().statementTimeoutSQL(milliseconds: 600_000) == "SET statement_timeout = 600000")
        #expect(PostgresDialect(redshift: true).statementTimeoutSQL(milliseconds: 1000) == "SET statement_timeout = 1000")
        #expect(MySQLDialect().statementTimeoutSQL(milliseconds: 600_000) == "SET SESSION max_execution_time = 600000")
        #expect(MSSQLDialect().statementTimeoutSQL(milliseconds: 600_000) == nil)
    }

    /// 실제 서버: 연결하면 세션에 제한이 걸려 있다 (테스트 프로세스는 설정을 바꾸지 않아 기본 30분)
    @Test(.enabled(if: MultiDB.env["GODDB_PG_PORT"] != nil && UserDefaults.standard.object(forKey: QueryTimeLimit.key) == nil))
    func postgresSessionHasTimeout() async throws {
        let (p, pw) = try #require(MultiDB.profile(.postgres, database: "shop"))
        let s = try await DBSession.connect(profile: p, password: pw)
        defer { Task { await s.close() } }
        #expect(try await s.raw("SHOW statement_timeout").rows.first?.first == .some("30min"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GODDB_IT_PORT"] != nil
                   && UserDefaults.standard.object(forKey: QueryTimeLimit.key) == nil))
    func mysqlSessionHasTimeout() async throws {
        let env = ProcessInfo.processInfo.environment
        let p = ConnectionProfile(name: "my", host: "127.0.0.1", port: Int(env["GODDB_IT_PORT"]!)!, username: "root",
                                  database: "shop", useTLS: false)
        let s = try await DBSession.connect(profile: p, password: env["GODDB_IT_PASSWORD"] ?? "")
        defer { Task { await s.close() } }
        #expect(try await s.raw("SELECT @@SESSION.max_execution_time").rows.first?.first == .some("1800000"))
    }
}
