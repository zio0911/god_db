import Foundation
import Testing
@testable import GodDBCore

@Suite("SQLDanger")
struct SQLDangerTests {
    @Test func deleteAndUpdateWithoutWhere() {
        #expect(SQLText.danger("DELETE FROM orders") == .deleteAll)
        #expect(SQLText.danger("  -- 정리\n delete from orders;") == .deleteAll)
        #expect(SQLText.danger("UPDATE users SET name = 'x'") == .updateAll)
        #expect(SQLText.danger("DELETE TOP (10) FROM logs") == .deleteAll)
    }

    @Test func whereMakesItSafe() {
        #expect(SQLText.danger("DELETE FROM orders WHERE id = 1") == nil)
        #expect(SQLText.danger("update users\nset a = 1\nwhere id in (select id from t where x = 2)") == nil)
        #expect(SQLText.danger("DELETE o FROM orders o JOIN users u ON u.id = o.uid WHERE u.gone = 1") == nil)
    }

    @Test func whereOnlyInsideStringOrSubqueryDoesNotCount() {
        #expect(SQLText.danger("UPDATE t SET note = 'where am i'") == .updateAll)
        #expect(SQLText.danger("UPDATE t SET a = (SELECT max(b) FROM u WHERE u.k = 1)") == .updateAll)
        #expect(SQLText.danger("UPDATE t SET a = 1 /* where */") == .updateAll)
        #expect(SQLText.danger("UPDATE t SET `where` = 1") == .updateAll)
    }

    @Test func truncateAndDrop() {
        #expect(SQLText.danger("TRUNCATE TABLE logs") == .truncate)
        #expect(SQLText.danger("drop table if exists tmp") == .drop)
        #expect(SQLText.danger("DROP DATABASE shop") == .drop)
    }

    @Test func otherStatementsAreFine() {
        #expect(SQLText.danger("SELECT * FROM orders") == nil)
        #expect(SQLText.danger("INSERT INTO t VALUES (1)") == nil)
        #expect(SQLText.danger("ALTER TABLE t ADD c INT") == nil)
    }
}

@Suite("ConnectionEnvironment")
struct ConnectionEnvironmentTests {
    @Test func decodesOldProfilesWithoutEnvironment() throws {
        let json = #"{"id":"6F1C2D3E-0000-4000-8000-000000000001","name":"a","host":"h","port":3306,"username":"u"}"#
        let p = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))
        #expect(p.environment == .none)
    }

    @Test func roundTripsEnvironment() throws {
        var p = ConnectionProfile(name: "prod")
        p.environment = .production
        let back = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(p))
        #expect(back.environment == .production)
    }
}

@Suite("ScriptDelimiters")
struct ScriptDelimiterTests {
    @Test func mysqlDelimiterKeepsProcedureBodyTogether() {
        let script = """
        DROP PROCEDURE IF EXISTS p1;
        DELIMITER $$
        CREATE PROCEDURE p1()
        BEGIN
          SELECT 1;
          SELECT 2;
        END$$
        DELIMITER ;
        CALL p1();
        """
        let s = SQLText.statements(in: script).map(\.sql)
        #expect(s.count == 3)
        #expect(s[0] == "DROP PROCEDURE IF EXISTS p1")
        #expect(s[1].hasPrefix("CREATE PROCEDURE p1()") && s[1].hasSuffix("END"))
        #expect(s[1].contains("SELECT 1;\n  SELECT 2;"))
        #expect(s[2] == "CALL p1()")
    }

    @Test func slashDelimiter() {
        let s = SQLText.statements(in: "DELIMITER //\nSELECT 1; SELECT 2 //\nDELIMITER ;\nSELECT 3;").map(\.sql)
        #expect(s == ["SELECT 1; SELECT 2", "SELECT 3"])
    }

    @Test func goSplitsBatchesOnly() {
        let script = """
        CREATE PROCEDURE dbo.p AS
        BEGIN
          SELECT 1;
          SELECT 2;
        END
        GO
        EXEC dbo.p;
        go
        SELECT 'GO';
        """
        let s = SQLText.statements(in: script).map(\.sql)
        #expect(s.count == 3)
        #expect(s[0].contains("SELECT 1;\n  SELECT 2;"))
        #expect(s[1] == "EXEC dbo.p;")
        #expect(s[2] == "SELECT 'GO';")
    }

    @Test func plainScriptsUnchanged() {
        #expect(SQLText.statements(in: "SELECT 1; SELECT 'a;b'; -- x;\nSELECT 3").map(\.sql) == ["SELECT 1", "SELECT 'a;b'", "-- x;\nSELECT 3"])
        // GOOD 같은 단어나 문장 중간 GO 는 구분자가 아니다
        #expect(SQLText.statements(in: "SELECT good FROM t; SELECT 2").count == 2)
    }
}
