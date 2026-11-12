import Foundation
import Testing
@testable import GodDBCore

@Suite("SQLText")
struct SQLTextTests {
    @Test func splitsStatementsIgnoringQuotedSemicolons() {
        let sql = "SELECT 'a;b' FROM t;\n-- x; y\nSELECT `c;d` FROM u;"
        let parts = SQLText.statements(in: sql).map(\.sql)
        #expect(parts.count == 2)
        #expect(parts[0] == "SELECT 'a;b' FROM t")
        #expect(parts[1].hasSuffix("SELECT `c;d` FROM u"))
    }

    @Test func picksStatementAtCursor() {
        let sql = "SELECT 1;\nSELECT 2;\nSELECT 3;"
        let cursor = (sql as NSString).range(of: "2").location
        #expect(SQLText.statement(in: sql, at: cursor) == "SELECT 2")
        #expect(SQLText.statement(in: sql, at: (sql as NSString).length) == "SELECT 3")
    }

    @Test func readOnlyGuard() {
        #expect(SQLText.isReadOnly("select * from t"))
        #expect(SQLText.isReadOnly("/* hi */ SHOW TABLES"))
        #expect(SQLText.isReadOnly("  explain select 1"))
        #expect(!SQLText.isReadOnly("UPDATE t SET a = 1"))
        #expect(!SQLText.isReadOnly("-- select\nDELETE FROM t"))
        #expect(!SQLText.isReadOnly("SELECT * FROM t INTO OUTFILE '/tmp/x'"))
        #expect(!SQLText.isReadOnly("WITH x AS (SELECT 1) DELETE FROM t"))
    }

    @Test func appliesLimitOnlyWhenMissing() {
        #expect(SQLText.applyingLimit("SELECT * FROM t;", limit: 500) == "SELECT * FROM t\nLIMIT 500")
        #expect(SQLText.applyingLimit("SELECT * FROM t LIMIT 10", limit: 500) == "SELECT * FROM t LIMIT 10")
        #expect(SQLText.applyingLimit("SHOW TABLES", limit: 500) == "SHOW TABLES")
        #expect(SQLText.applyingLimit("SELECT 1", limit: 0) == "SELECT 1")
    }
}

@Suite("SchemaDiff")
struct SchemaDiffTests {
    let id = ColumnMeta(name: "id", columnType: "bigint", nullable: false, extra: "auto_increment", columnKey: "PRI", position: 1)
    let email = ColumnMeta(name: "email", columnType: "varchar(100)", nullable: true, comment: "메일", position: 2)
    let regDt = ColumnMeta(name: "reg_dt", columnType: "datetime", nullable: false,
                           defaultValue: "CURRENT_TIMESTAMP", extra: "DEFAULT_GENERATED", position: 3)

    @Test func identicalSchemasHaveNoDiff() {
        let t = TableMeta(name: "tb_member", columns: [id, email], indexes: [IndexMeta(name: "PRIMARY", unique: true, columns: ["id"])])
        let report = SchemaDiff.compare(source: [t], target: [t])
        #expect(report.items.isEmpty)
        #expect(report.matchedTables == 1)
    }

    @Test func detectsMissingAndDifferentColumns() {
        var shortEmail = email
        shortEmail.columnType = "varchar(50)"
        let source = TableMeta(name: "tb_member", columns: [id, email, regDt])
        let target = TableMeta(name: "tb_member", columns: [id, shortEmail])
        let report = SchemaDiff.compare(source: [source], target: [target])

        let diff = report.items.first { $0.kind == .differentColumn }
        #expect(diff?.fixSQL == "ALTER TABLE `tb_member` MODIFY COLUMN `email` varchar(100) NULL COMMENT '메일';")

        let missing = report.items.first { $0.kind == .missingColumn }
        #expect(missing?.fixSQL == "ALTER TABLE `tb_member` ADD COLUMN `reg_dt` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP AFTER `email`;")
    }

    @Test func quotesLiteralDefaults() {
        let c = ColumnMeta(name: "status", columnType: "char(1)", nullable: false, defaultValue: "A")
        #expect(SchemaDiff.columnDefinition(c) == "`status` char(1) NOT NULL DEFAULT 'A'")
    }

    @Test func indexesAndTables() {
        let source = [
            TableMeta(name: "a", columns: [id], indexes: [
                IndexMeta(name: "idx_x", unique: false, columns: ["x"]),
                IndexMeta(name: "uq_y", unique: true, columns: ["y", "z"]),
            ]),
            TableMeta(name: "b", columns: [id]),
        ]
        let target = [
            TableMeta(name: "a", columns: [id], indexes: [IndexMeta(name: "idx_x", unique: false, columns: ["x", "w"])]),
            TableMeta(name: "c", columns: [id]),
        ]
        let report = SchemaDiff.compare(source: source, target: target, createStatements: ["b": "CREATE TABLE `b` (...)"])
        #expect(report.items.first { $0.kind == .differentIndex }?.fixSQL
                == "ALTER TABLE `a` DROP INDEX `idx_x`, ADD INDEX `idx_x` (`x`);")
        #expect(report.items.first { $0.kind == .missingIndex }?.fixSQL
                == "ALTER TABLE `a` ADD UNIQUE INDEX `uq_y` (`y`, `z`);")
        #expect(report.items.first { $0.kind == .missingTable }?.fixSQL == "CREATE TABLE `b` (...);")
        #expect(report.items.contains { $0.kind == .extraTable && $0.table == "c" && $0.fixSQL == nil })
        #expect(!report.fixScript.contains("DROP TABLE"))
    }

    @Test func buildsSchemaFromRows() {
        let tables = SchemaBuilder.build(
            tableRows: [["t", "코멘트"]],
            columnRows: [["t", "id", "bigint", "NO", nil, "auto_increment", "PRI", "", "1"]],
            indexRows: [["t", "PRIMARY", "0", "id"], ["t", "idx_ab", "1", "a"], ["t", "idx_ab", "1", "b"]]
        )
        #expect(tables.count == 1)
        #expect(tables[0].columns[0].isPrimaryKey)
        #expect(tables[0].indexes.first { $0.name == "idx_ab" }?.columns == ["a", "b"])
        #expect(tables[0].indexes.first { $0.name == "PRIMARY" }?.unique == true)
    }
}

@Suite("SSHTunnel")
struct SSHTunnelTests {
    @Test func buildsSSHArguments() {
        let args = SSHTunnel.arguments(
            config: SSHConfig(host: "bastion", port: 22, username: "ec2-user", keyPath: "/k.pem"),
            localPort: 40000, remoteHost: "db.internal", remotePort: 3306)
        #expect(args.contains("127.0.0.1:40000:db.internal:3306"))
        #expect(args.last == "ec2-user@bastion")
        #expect(args.contains("/k.pem"))
    }

    @Test func findsFreePort() {
        let port = SSHTunnel.findFreePort()
        #expect(port != nil && port! > 0)
    }
}
