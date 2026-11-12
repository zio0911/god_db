import Foundation
import Testing
@testable import GodDBCore

@Suite("TableAlter")
struct TableAlterTests {
    let table = TableMeta(
        name: "tb_member", comment: "회원",
        columns: [
            ColumnMeta(name: "id", columnType: "bigint", nullable: false, extra: "auto_increment", columnKey: "PRI", position: 1),
            ColumnMeta(name: "email", columnType: "varchar(100)", nullable: true, position: 2),
            ColumnMeta(name: "nick", columnType: "varchar(20)", nullable: true, position: 3),
        ],
        indexes: [
            IndexMeta(name: "PRIMARY", unique: true, columns: ["id"]),
            IndexMeta(name: "idx_email", unique: false, columns: ["email"]),
        ])

    var cols: [EditableColumn] { table.columns.map(EditableColumn.init) }
    var idxs: [EditableIndex] { table.indexes.map(EditableIndex.init) }

    @Test func noChangesGivesNil() throws {
        #expect(try TableAlter.statement(original: table, columns: cols, indexes: idxs, comment: "회원") == nil)
    }

    @Test func renameModifyDropAdd() throws {
        var c = cols
        c[1].name = "mail"                 // rename
        c[1].columnType = "varchar(200)"
        c.remove(at: 2)                    // drop nick
        c.append(EditableColumn(name: "status", columnType: "char(1)", nullable: false, defaultValue: "A"))
        var i = idxs
        i[1].columns = ["mail"]            // email 인덱스 컬럼 변경
        i.append(EditableIndex(name: "idx_status", columns: ["status"]))
        let sql = try #require(try TableAlter.statement(original: table, columns: c, indexes: i, comment: "회원 테이블"))
        #expect(sql == """
            ALTER TABLE `tb_member`
              DROP INDEX `idx_email`,
              DROP COLUMN `nick`,
              CHANGE COLUMN `email` `mail` varchar(200) NULL,
              ADD COLUMN `status` char(1) NOT NULL DEFAULT 'A' AFTER `mail`,
              ADD INDEX `idx_email` (`mail`),
              ADD INDEX `idx_status` (`status`),
              COMMENT = '회원 테이블';
            """)
    }

    @Test func validation() {
        var c = cols
        c[2].name = "EMAIL"
        #expect(throws: TableAlterError.duplicateColumn("EMAIL")) {
            try TableAlter.statement(original: table, columns: c, indexes: idxs, comment: "")
        }
        var i = idxs
        i.append(EditableIndex(name: "idx_x", columns: ["nope"]))
        #expect(throws: TableAlterError.unknownIndexColumn(index: "idx_x", column: "nope")) {
            try TableAlter.statement(original: table, columns: cols, indexes: i, comment: "")
        }
    }
}

@Suite("PlanAnalyzer")
struct PlanAnalyzerTests {
    @Test func flagsFullScanAndFilesort() {
        let r = QueryResult(
            columns: ["id", "select_type", "table", "type", "possible_keys", "key", "rows", "Extra"],
            rows: [["1", "SIMPLE", "tb_member", "ALL", nil, nil, "12000", "Using where; Using filesort"],
                   ["1", "SIMPLE", "tb_order", "ref", "idx_member", "idx_member", "3", nil]],
            elapsed: 0)
        let w = PlanAnalyzer.warnings(r)
        #expect(w.count == 2)
        #expect(w[0].table == "tb_member" && w[0].message.contains("풀 테이블 스캔"))
        #expect(w[1].message.contains("filesort"))
    }
}

@Suite("ConnectionProfile")
struct ConnectionProfileTests {
    @Test func decodesOldJSONWithoutSavePassword() throws {
        let json = """
        [{"id":"559343C0-9D63-4846-A9F4-CB47500265B9","name":"a","host":"localhost","port":3306,
          "username":"root","database":"shop","useTLS":false,"readOnly":false}]
        """
        let p = try JSONDecoder().decode([ConnectionProfile].self, from: Data(json.utf8))
        #expect(p[0].savePassword == true)
        #expect(p[0].ssh == nil)
    }
}
