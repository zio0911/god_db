import Foundation
import Testing
@testable import GodDBCore

@Suite("SQL lint")
struct SQLLintTests {
    let tables = [
        TableMeta(name: "users", columns: [
            ColumnMeta(name: "id", columnType: "bigint", nullable: false, position: 1),
            ColumnMeta(name: "name", columnType: "varchar(50)", nullable: true, position: 2),
            ColumnMeta(name: "email", columnType: "varchar(100)", nullable: true, position: 3),
        ]),
        TableMeta(name: "posts", columns: [
            ColumnMeta(name: "id", columnType: "bigint", nullable: false, position: 1),
            ColumnMeta(name: "user_id", columnType: "bigint", nullable: false, position: 2),
            ColumnMeta(name: "title", columnType: "varchar(200)", nullable: true, position: 3),
        ]),
    ]

    func issues(_ sql: String, kind: DatabaseKind = .mysql, schema: String? = nil) -> [(String, String)] {
        SQLLint.check(sql, tables: tables, kind: kind, schema: schema).map { i in
            ((sql as NSString).substring(with: i.range), i.message)
        }
    }

    @Test func unknownQualifiedColumnWithHint() {
        let sql = "SELECT a.id, a.username, b.title FROM users a JOIN posts b ON b.user_id = a.id"
        let found = SQLLint.check(sql, tables: tables, kind: .mysql)
        #expect(found.count == 1)
        #expect((sql as NSString).substring(with: found[0].range) == "username")
        #expect(found[0].message == tr("%@ 테이블에 %@ 컬럼이 없어요.", "users", "username"))
        #expect(found[0].hint == tr("비슷한 컬럼: %@", "name"))
    }

    @Test func validQueriesHaveNoIssues() {
        let ok = [
            "SELECT a.id, a.name, b.title FROM users a JOIN posts b ON b.user_id = a.id WHERE a.email LIKE '%x%' ORDER BY a.id DESC, b.id",
            "SELECT id, name AS nm, COUNT(*) cnt FROM users WHERE email IS NOT NULL GROUP BY id, name ORDER BY nm",
            "SELECT TOP 10 u.id, u.name FROM [dbo].[users] u",
            "SELECT DISTINCT ON (u.id) u.id, u.name FROM public.users u ORDER BY u.id, u.name",
            "WITH t AS (SELECT 1 AS foo) SELECT t.foo FROM t",
            "SELECT x.whatever FROM (SELECT id AS whatever FROM users) x",
            "SELECT o.anything FROM other_db.orders o",
            "SELECT u.id::text, u.name || '!' FROM users u",
            "SELECT CASE WHEN u.id > 1 THEN u.name ELSE u.email END AS label FROM users u",
            "SELECT DATE_ADD(NOW(), INTERVAL 1 DAY), CURRENT_TIMESTAMP FROM users",
            "UPDATE users SET name = 'a' WHERE id = 1",
            "INSERT INTO posts (user_id, title) VALUES (1, 'it''s, fine')",
            "SELECT 'a, b', \"c\" FROM users -- trailing, comment\n",
            "SELECT u.id FROM users AS u WHERE u.id IN (SELECT p.user_id FROM posts p)",
        ]
        for sql in ok {
            let kind: DatabaseKind = sql.contains("[dbo]") || sql.contains("TOP") ? .mssql : sql.contains("::") || sql.contains("ON (") ? .postgres : .mysql
            #expect(issues(sql, kind: kind, schema: kind == .postgres ? "public" : nil).isEmpty, "\(sql) → \(issues(sql, kind: kind))")
        }
    }

    @Test func missingComma() {
        let found = issues("SELECT a.id a.name, b.title FROM users a JOIN posts b ON b.user_id = a.id")
        #expect(found.map(\.0) == ["a.name"])
        #expect(found.first?.1 == tr("앞 항목과 사이에 콤마가 빠진 것 같아요."))
        #expect(issues("SELECT a.id, a.name FROM users a ORDER BY a.id a.name").map(\.0) == ["a.name"])
    }

    @Test func commasParensQuotes() {
        #expect(issues("SELECT id, name, FROM users").map(\.1) == [tr("콤마 뒤에 항목이 없어요.")])
        #expect(issues("SELECT id,, name FROM users").map(\.1) == [tr("콤마가 두 번 있어요.")])
        #expect(issues("SELECT , id FROM users").map(\.1) == [tr("콤마 앞에 항목이 없어요.")])
        #expect(issues("SELECT COUNT(id FROM users").map(\.1) == [tr("닫는 괄호가 없어요.")])
        #expect(issues("SELECT id) FROM users").map(\.1) == [tr("여는 괄호가 없어요.")])
        #expect(issues("SELECT id FROM users WHERE name = 'abc").map(\.1) == [tr("닫히지 않은 따옴표예요.")])
    }

    @Test func keywordTypos() {
        #expect(issues("SELEC id FROM users").map(\.1) == [tr("%@ 의 오타 같아요.", "SELECT")])
        #expect(issues("SELECT id FORM users").contains { $0.0 == "FORM" && $0.1 == tr("%@ 의 오타 같아요.", "FROM") })
        #expect(issues("SELECT id FROM users WEHRE id = 1").contains { $0.0 == "WEHRE" })
    }

    @Test func unqualifiedColumnInSingleTable() {
        #expect(issues("SELECT id, usrname FROM users WHERE id = 1").map(\.0) == ["usrname"])
        #expect(issues("SELECT id FROM users WHERE emial = 'x'").map(\.0) == ["emial"])
        // JOIN 이 있으면 이름만 쓴 컬럼은 검사하지 않는다 (어느 테이블인지 확실하지 않음)
        #expect(issues("SELECT usrname FROM users a JOIN posts b ON b.user_id = a.id").isEmpty)
    }

    @Test func otherSchemaIsSkipped() {
        #expect(issues("SELECT u.nope FROM sales.users u", kind: .postgres, schema: "public").isEmpty)
        #expect(issues("SELECT u.nope FROM public.users u", kind: .postgres, schema: "public").map(\.0) == ["nope"])
    }

    @Test func rangesAreInFullText() {
        let text = "SELECT 1;\n\n  SELECT a.nope FROM users a;"
        let found = SQLLint.check(text, tables: tables, kind: .mysql)
        #expect(found.count == 1)
        #expect((text as NSString).substring(with: found[0].range) == "nope")
    }

    @Test func serverCheckHelpers() {
        #expect(SQLServerCheck.checkable("  -- c\nselect 1", kind: .postgres))
        #expect(!SQLServerCheck.checkable("CREATE TABLE x (a int)", kind: .mysql))
        let sql = "SELECT a.username FROM users a"
        let r = SQLServerCheck.guessRange(message: "Unknown column 'a.username' in 'field list'", in: sql)
        #expect(r.map { (sql as NSString).substring(with: $0) } == "a.username")
        let r2 = SQLServerCheck.guessRange(message: "You have an error in your SQL syntax; check the manual near 'FORM users' at line 1",
                                           in: "SELECT id FORM users")
        #expect(r2.map { ("SELECT id FORM users" as NSString).substring(with: $0) } == "FORM")
        let (check, cleanup) = SQLServerCheck.commands(for: "SELECT 'it''s';", kind: .mssql)
        #expect(check == ["EXEC sp_describe_first_result_set @tsql = N'SELECT ''it''''s'''"])
        #expect(cleanup.isEmpty)
    }
}

/// 실제 DB 에 검사만 맡기기 (실행하지 않음). test-dbs.sh test 로 실행.
@Suite("SQL server check", .serialized)
struct SQLServerCheckIntegrationTests {
    func session(_ kind: DatabaseKind) async throws -> DBSession? {
        try await ExportIntegrationTests().session(kind)
    }

    @Test(arguments: [DatabaseKind.mysql, .postgres, .mssql])
    func checksWithoutRunning(_ kind: DatabaseKind) async throws {
        guard let s = try await session(kind) else { return }
        defer { Task { await s.close() } }
        let t = "goddb_lint_\(UInt32.random(in: 0...UInt32.max))"
        _ = try await s.raw("CREATE TABLE \(t) (id int, name varchar(20))")
        do {
            _ = try await s.raw("INSERT INTO \(t) (id, name) VALUES (1, 'a')")
            // 올바른 문장: 오류 없음, DELETE 는 실행되지 않아야 한다
            let ok = await s.serverCheck("DELETE FROM \(t) WHERE id = 1")
            #expect(ok == .some(nil))
            let count = try await s.raw("SELECT COUNT(*) FROM \(t)").rows.first?.first ?? nil
            #expect(count == "1", "검사가 DELETE 를 실행함")

            // 없는 컬럼
            let sql = "SELECT a.id, a.username FROM \(t) a"
            let bad = await s.serverCheck(sql)
            let failure = try #require(bad ?? nil)
            #expect(failure.range.map { (sql as NSString).substring(with: $0) }?.hasSuffix("username") == true, "\(failure) \(failure.message)")

            // 문법 오류
            let syntax = await s.serverCheck("SELECT id FORM \(t)")
            #expect((syntax ?? nil) != nil)

            // 검사 뒤에도 세션은 그대로 쓸 수 있다
            let again = try await s.raw("SELECT name FROM \(t)").rows.first?.first ?? nil
            #expect(again == "a")
        } catch {
            Issue.record(error)
        }
        _ = try? await s.raw("DROP TABLE \(t)")
    }
}
