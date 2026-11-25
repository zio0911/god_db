import Foundation
import Testing
@testable import GodDBCore

/// #205: DB 로 나가는 모든 문장이 감사 기록에 남는다
final class AuditCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AuditRecord] = []
    var records: [AuditRecord] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ r: AuditRecord) { lock.lock(); items.append(r); lock.unlock() }
    func statements(containing s: String) -> [AuditRecord] { records.filter { $0.statement.contains(s) } }

    /// 이 작업 안에서 남는 감사 기록만 모은다
    func collect<T>(_ body: () async throws -> T) async rethrows -> T {
        try await QueryAudit.$capture.withValue({ [self] in add($0) }) { try await body() }
    }
}

private final class FakeDriver: DBDriver, @unchecked Sendable {
    var fail = false
    func query(_ sql: String) async throws -> (columns: [String], rows: [[String?]]) {
        if fail { throw DBError.notConnected }
        return sql.hasPrefix("SET") ? ([], []) : (["a"], [["1"], ["2"]])
    }
    func close() async {}
    var isOpen: Bool { true }
}

@Suite("Query audit")
struct QueryAuditTests {
    @Test func recordsEveryStatementWithTargetRowsAndOrigin() async throws {
        let c = AuditCollector()
        let d = AuditingDriver(FakeDriver(), name: "dev", database: "shop")
        try await c.collect {
            _ = try await d.query("SELECT * FROM t")
            _ = try await QueryAudit.labeled("세션 설정") { try await d.query("SET x = 1") }
            d.setDatabase("other")
            _ = try await QueryAudit.labeled("메타데이터") { try await d.query("SHOW TABLES") }
        }
        let r = c.records
        #expect(r.count == 3)
        #expect(r[0].action == .read && r[0].target == "dev/shop" && r[0].statement == "SELECT * FROM t")
        #expect(r[0].result.hasPrefix("2행 · ") && r[0].result.hasSuffix("ms"), "\(r[0].result)")
        #expect(r[1].action == .execute && r[1].result.hasPrefix("세션 설정 · ") && !r[1].result.contains("행"), "\(r[1].result)")
        #expect(r[2].target == "dev/other" && r[2].result.hasPrefix("메타데이터 · 2행"), "\(r[2].result)")
    }

    @Test func failureIsRecordedAsFailure() async throws {
        let c = AuditCollector()
        let fake = FakeDriver()
        fake.fail = true
        let d = AuditingDriver(fake, name: "dev", database: "")
        await c.collect {
            _ = try? await QueryAudit.labeled("다음 페이지") { try await d.query("SELECT 1") }
        }
        #expect(c.records.count == 1)
        #expect(c.records.first?.target == "dev")
        #expect(c.records.first?.result.hasPrefix("실패: 다음 페이지 · ") == true, "\(c.records.first?.result ?? "")")
    }

    @Test func callerAuditedPrimaryIsSkippedButOtherStatementsStay() async throws {
        let c = AuditCollector()
        let d = AuditingDriver(FakeDriver(), name: "dev", database: "shop")
        try await c.collect {
            try await QueryAudit.audited {
                _ = try await QueryAudit.labeled("자동 트랜잭션 시작") { try await d.query("BEGIN") }
                _ = try await QueryAudit.primary(true) { try await d.query("UPDATE t SET a = 1") }
            }
            // 호출한 쪽이 기록하지 않으면 주 문장도 남는다
            _ = try await QueryAudit.primary(true) { try await d.query("SELECT 2") }
        }
        #expect(c.records.map(\.statement) == ["BEGIN", "SELECT 2"])
    }

    @Test func redisSecretsAreMasked() {
        #expect(QueryAudit.redisStatement(["AUTH", "pw1"]) == "AUTH ******")
        #expect(QueryAudit.redisStatement(["auth", "me", "pw1"]) == "auth me ******")
        #expect(QueryAudit.redisStatement(["HELLO", "3", "AUTH", "me", "pw1"]) == "HELLO 3 AUTH me ******")
        #expect(QueryAudit.redisStatement(["CONFIG", "SET", "requirepass", "pw1"]) == "CONFIG SET requirepass ******")
        #expect(QueryAudit.redisStatement(["ACL", "SETUSER", "u", "on", ">pw1", "~*"]) == "ACL SETUSER u on >****** ~*")
        #expect(QueryAudit.redisStatement(["SET", "k", "hello world"]) == "SET k \"hello world\"")
        #expect(!QueryAudit.redisStatement(["MIGRATE", "h", "1", "", "0", "5000", "AUTH", "pw1", "KEYS", "a"]).contains("pw1"))
    }
}

/// 실제 DB: 접속 설정 · 메타데이터 · 페이지 · 행 수 · 자동 트랜잭션까지 남고, 직접 실행(호출한 쪽이 기록)은 한 번만
@Suite("Query audit integration", .serialized)
struct QueryAuditIntegrationTests {
    static let env = ProcessInfo.processInfo.environment

    func run(_ profile: ConnectionProfile, _ password: String, table: String) async throws {
        let c = AuditCollector()
        try await c.collect {
            let s = try await DBSession.connect(profile: profile, password: password)
            defer { Task { await s.close() } }
            _ = try await s.loadSchema(await s.current.isEmpty ? profile.database : s.current)
            _ = try await QueryAudit.audited { try await s.execute("SELECT * FROM \(table)", limit: 1) }
            _ = try await QueryAudit.labeled("페이지 이동") { try await s.execute("SELECT * FROM \(table)", limit: 1, page: 1) }
            _ = try await QueryAudit.labeled("행 수 세기") { try await s.count("SELECT * FROM \(table)") }
        }
        let r = c.records
        let all = r.map { "\($0.result) | \($0.statement)" }.joined(separator: "\n")
        #expect(r.allSatisfy { $0.target.hasPrefix(profile.name) }, "\(all)")
        #expect(r.contains { $0.result.hasPrefix("세션 설정") }, "접속 설정 문장\n\(all)")
        #expect(r.contains { $0.result.hasPrefix("메타데이터") }, "메타데이터\n\(all)")
        #expect(r.contains { $0.result.hasPrefix("페이지 이동") && $0.statement.contains(table) }, "페이지\n\(all)")
        #expect(r.contains { $0.result.hasPrefix("행 수 세기") && $0.statement.uppercased().contains("COUNT") }, "행 수\n\(all)")
        // 직접 실행한 첫 문장은 호출한 쪽이 기록 → 드라이버 쪽에는 페이지 이동 한 번만
        #expect(r.filter { $0.statement.contains("FROM \(table)") && !$0.statement.uppercased().contains("COUNT")
            && !$0.result.hasPrefix("메타데이터") }.count == 1, "\(all)")
    }

    @Test(.enabled(if: env["GODDB_IT_PORT"] != nil))
    func mysql() async throws {
        let p = ConnectionProfile(name: "my", host: "127.0.0.1", port: Int(Self.env["GODDB_IT_PORT"]!)!, username: "root",
                                  database: "shop", useTLS: false)
        try await run(p, Self.env["GODDB_IT_PASSWORD"] ?? "", table: "information_schema.TABLES")
    }

    @Test(.enabled(if: env["GODDB_PG_PORT"] != nil))
    func postgres() async throws {
        let (p, pw) = try #require(MultiDB.profile(.postgres, database: "shop"))
        try await run(p, pw, table: "pg_catalog.pg_class")
    }

    @Test(.enabled(if: env["GODDB_MSSQL_PORT"] != nil))
    func mssql() async throws {
        let (p, pw) = try #require(MultiDB.profile(.mssql, database: "master"))
        try await run(p, pw, table: "sys.objects")
        // SQL Server 접속 기본 설정(SET ANSI_*)도 남는다
        let c = AuditCollector()
        try await c.collect {
            let s = try await DBSession.connect(profile: p, password: pw)
            await s.close()
        }
        #expect(c.records.contains { $0.statement.contains("SET ANSI_NULLS ON") && $0.result.hasPrefix("세션 설정") })
    }

    @Test(.enabled(if: env["GODDB_IT_PORT"] != nil))
    func manualCommitBeginIsRecorded() async throws {
        let p = ConnectionProfile(name: "my", host: "127.0.0.1", port: Int(Self.env["GODDB_IT_PORT"]!)!, username: "root",
                                  database: "shop", useTLS: false)
        let s = try await DBSession.connect(profile: p, password: Self.env["GODDB_IT_PASSWORD"] ?? "")
        defer { Task { await s.close() } }
        _ = try await s.raw("CREATE TABLE IF NOT EXISTS goddb_audit_t (id INT)")
        try await s.setAutoCommit(false)
        let c = AuditCollector()
        try await c.collect {
            _ = try await QueryAudit.audited { try await s.execute("INSERT INTO goddb_audit_t VALUES (1)", limit: 0) }
            _ = try await QueryAudit.audited { try await s.rollback() }
        }
        _ = try await s.raw("DROP TABLE goddb_audit_t")
        let r = c.records
        // INSERT · ROLLBACK 은 호출한 쪽이 기록, 앱이 덧붙인 BEGIN 만 남는다
        #expect(r.count == 1 && r.first?.result.hasPrefix("자동 트랜잭션 시작") == true, "\(r.map(\.statement))")
    }

    @Test(.enabled(if: env["GODDB_REDIS_PORT"] != nil))
    func redis() async throws {
        let p = ConnectionProfile(kind: .redis, name: "redis-it", host: "127.0.0.1",
                                  port: Int(Self.env["GODDB_REDIS_PORT"]!)!, username: "", database: "3", useTLS: false)
        let c = AuditCollector()
        try await c.collect {
            let s = try await RedisSession.connect(profile: p, password: "goddbtest")
            _ = try await QueryAudit.labeled("키 목록") { try await s.command(["SCAN", "0", "COUNT", "10"]) }
            _ = try await QueryAudit.audited { try await s.command(["SET", "goddb:audit", "1"]) }
            _ = try await s.command(["DEL", "goddb:audit"])
            await s.close()
        }
        let r = c.records
        let all = r.map { "\($0.target) | \($0.result) | \($0.statement)" }.joined(separator: "\n")
        #expect(r.contains { $0.statement == "SELECT 3" && $0.result.hasPrefix("세션 설정") }, "\(all)")
        #expect(r.contains { $0.statement == "AUTH ******" } && !all.contains("goddbtest"), "비밀번호는 가림\n\(all)")
        #expect(r.contains { $0.statement.hasPrefix("SCAN 0") && $0.result.hasPrefix("키 목록") && $0.target == "redis-it db3" }, "\(all)")
        #expect(!r.contains { $0.statement.hasPrefix("SET goddb:audit") }, "호출한 쪽이 기록한 명령은 한 번만\n\(all)")
        #expect(r.contains { $0.statement == "DEL goddb:audit" && $0.action == .delete }, "\(all)")
    }
}
