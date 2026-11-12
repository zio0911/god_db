import Foundation
import Testing
@testable import GodDBCore

/// 실제 MySQL 대상 통합 테스트. GODDB_IT_PORT / GODDB_IT_PASSWORD 환경변수가 있을 때만 실행된다.
@Suite("Integration", .serialized, .enabled(if: ProcessInfo.processInfo.environment["GODDB_IT_PORT"] != nil))
struct IntegrationTests {
    var profile: ConnectionProfile {
        let env = ProcessInfo.processInfo.environment
        return ConnectionProfile(name: "it", host: "127.0.0.1", port: Int(env["GODDB_IT_PORT"]!)!,
                                 username: "root", database: "shop", useTLS: true)
    }
    var password: String { ProcessInfo.processInfo.environment["GODDB_IT_PASSWORD"] ?? "" }

    @Test func queryAndSchemaAndCompare() async throws {
        let s = try await DBSession.connect(profile: profile, password: password)
        // 앱에서 테스트 DB 를 직접 고쳤을 수 있으니 회원 데이터를 처음 상태로 되돌린다
        _ = try await s.raw("DELETE FROM shop.tb_member")
        _ = try await s.raw("INSERT INTO shop.tb_member (member_id, email) VALUES (1, 'kim@sample.com'), (2, 'lee@sample.com'), (3, NULL)")
        #expect(try await s.serverVersion().hasPrefix("MySQL 8"))
        let dbs = try await s.databases()
        #expect(dbs.contains("shop"))

        let r = try await s.execute("SELECT member_id, email FROM tb_member ORDER BY member_id", limit: 2)
        #expect(r.columns.map(\.name) == ["member_id", "email"])
        #expect(r.rows.count == 2)
        #expect(r.rows[0].values[1] == "kim@sample.com")

        let nulls = try await s.execute("SELECT email FROM tb_member WHERE email IS NULL", limit: 500)
        #expect(nulls.rows.first?.values.first == .some(nil))

        try await MultiDBChecks.paging(s, table: "tb_member")
        try await MultiDBChecks.serverSort(s, table: "tb_member")
        _ = try await s.raw("DROP TABLE IF EXISTS tb_rename_it, tb_renamed_it")
        try await MultiDBChecks.renameAndDrop(s, container: "shop")
        try await MultiDBChecks.editing(s, container: "shop")
        try await MultiDBChecks.binary(s, container: "shop")
        try await MultiDBChecks.foreignKeys(s, container: "shop")

        let empty = try await s.execute("SELECT * FROM tb_member WHERE 1 = 0", limit: 500)
        #expect(empty.message == "결과 없음")

        // 테스트 전용 대상 스키마를 매번 새로 만든다 (데모용 shop_stg 는 건드리지 않음)
        _ = try await s.raw("DROP DATABASE IF EXISTS goddb_it_stg")
        _ = try await s.raw("CREATE DATABASE goddb_it_stg")
        _ = try await s.raw("CREATE TABLE goddb_it_stg.tb_member (member_id BIGINT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(50), status CHAR(1) NOT NULL DEFAULT 'A')")
        let source = try await s.loadSchema("shop").filter { !$0.name.hasPrefix("tb_alter_it") }
        let target = try await s.loadSchema("goddb_it_stg")
        #expect(source.first { $0.name == "tb_member" }?.comment == "회원")
        let create = try await s.showCreateTable("tb_coupon")
        let report = SchemaDiff.compare(source: source, target: target, createStatements: ["tb_coupon": create ?? ""])
        print(report.fixScript)
        #expect(report.items.contains { $0.kind == .missingTable && $0.table == "tb_coupon" })
        #expect(report.items.contains { $0.kind == .differentColumn && $0.object == "email" })
        #expect(report.items.contains { $0.kind == .missingColumn && $0.object == "reg_dt" })
        #expect(report.items.contains { $0.kind == .missingIndex && $0.object == "idx_email" })

        // 생성된 보정 SQL 을 stg 에 적용하면 차이가 사라져야 한다
        try await s.use("goddb_it_stg")
        for stmt in SQLText.statements(in: report.fixScript) {
            _ = try await s.raw(stmt.sql)
        }
        let after = SchemaDiff.compare(source: source, target: try await s.loadSchema("goddb_it_stg"))
        #expect(after.items.isEmpty, "\(after.items)")
        _ = try await s.raw("DROP DATABASE goddb_it_stg")
        await s.close()
    }

    /// 회귀: localhost 가 ::1 로 먼저 풀려도 IPv4 로 연결돼야 한다. (Docker 는 127.0.0.1 만 열림)
    @Test func connectsViaLocalhostName() async throws {
        var p = profile
        p.host = "localhost"
        p.useTLS = false
        let s = try await DBSession.connect(profile: p, password: password)
        #expect(try await s.raw("SELECT 1").rows.first?.first == "1")
        await s.close()
    }

    @Test func refusedPortGivesKoreanHint() async throws {
        var p = profile
        p.port = 1
        do {
            _ = try await DBSession.connect(profile: p, password: password)
            Issue.record("연결이 성공하면 안 됨")
        } catch {
            let d = ErrorText.describe(error)
            #expect(d.message.contains("거부"), "\(d.message) / \(d.raw)")
            #expect(d.hint != nil)
        }
    }

    @Test func wrongPasswordGivesHint() async throws {
        do {
            _ = try await DBSession.connect(profile: profile, password: "wrong")
            Issue.record("연결이 성공하면 안 됨")
        } catch {
            let d = ErrorText.describe(error)
            #expect(d.message.contains("1045"), "\(d.message)")
            #expect(d.hint?.contains("비밀번호") == true)
        }
    }

    @Test func readOnlyBlocksWrites() async throws {
        var p = profile
        p.readOnly = true
        let s = try await DBSession.connect(profile: p, password: password)
        await #expect(throws: DBError.self) { _ = try await s.execute("DELETE FROM tb_member", limit: 0) }
        // 가드를 우회하더라도 서버 세션이 읽기전용이라 거부된다
        await #expect(throws: (any Error).self) { _ = try await s.raw("INSERT INTO tb_member (email) VALUES ('x')") }
        await s.close()
    }
}

extension IntegrationTests {
    /// 생성한 ALTER 문이 실제 MySQL 에서 실행되고 결과가 의도대로인지 확인
    @Test func alterRunsOnServer() async throws {
        let s = try await DBSession.connect(profile: profile, password: password)
        _ = try await s.raw("DROP TABLE IF EXISTS tb_alter_it")
        _ = try await s.raw("CREATE TABLE tb_alter_it (id INT PRIMARY KEY, email VARCHAR(100), nick VARCHAR(20), KEY idx_email (email))")
        let original = try #require(try await s.loadSchema("shop").first { $0.name == "tb_alter_it" })
        var c = original.columns.map(EditableColumn.init)
        c[1].name = "mail"
        c.remove(at: 2)
        c.append(EditableColumn(name: "status", columnType: "char(1)", nullable: false, defaultValue: "A", comment: "상태"))
        var i = original.indexes.map(EditableIndex.init)
        i = i.map { var x = $0; if x.name == "idx_email" { x.columns = ["mail"] }; return x }
        let sql = try #require(try TableAlter.statement(original: original, columns: c, indexes: i, comment: "테스트"))
        _ = try await s.execute(sql, limit: 0)
        let after = try #require(try await s.loadSchema("shop").first { $0.name == "tb_alter_it" })
        #expect(after.columns.map(\.name) == ["id", "mail", "status"])
        #expect(after.columns.last?.comment == "상태")
        #expect(after.indexes.first { $0.name == "idx_email" }?.columns == ["mail"])
        #expect(after.comment == "테스트")
        _ = try await s.raw("DROP TABLE tb_alter_it")
        await s.close()
    }
}

extension IntegrationTests {
    @Test func routinesAndExplain() async throws {
        let s = try await DBSession.connect(profile: profile, password: password)
        _ = try await s.raw("DROP PROCEDURE IF EXISTS sp_it_count")
        _ = try await s.raw("CREATE PROCEDURE sp_it_count() COMMENT '회원 수' SELECT COUNT(*) FROM tb_member")
        _ = try await s.raw("CREATE OR REPLACE VIEW v_it_member AS SELECT member_id, email FROM tb_member")
        let routines = try await s.loadRoutines("shop")
        let sp = try #require(routines.first { $0.name == "sp_it_count" })
        #expect(sp.kind == .procedure && sp.comment == "회원 수")
        #expect(try await s.definition(of: sp)?.contains("SELECT COUNT(*)") == true)
        let v = try #require(routines.first { $0.name == "v_it_member" })
        #expect(try await s.definition(of: v)?.contains("member_id") == true)
        #expect(try await s.loadSchema("shop").contains { $0.name == "v_it_member" } == false)

        let plan = try await s.execute("EXPLAIN SELECT * FROM tb_member WHERE status = 'A' ORDER BY reg_dt", limit: 500)
        #expect(PlanAnalyzer.warnings(plan).contains { $0.message.contains("풀 테이블 스캔") })
        _ = try await s.raw("DROP PROCEDURE sp_it_count")
        _ = try await s.raw("DROP VIEW v_it_member")
        await s.close()
    }
}
