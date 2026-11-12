import Foundation
import Testing
@testable import GodDBCore

@Suite("Result editing")
struct ResultEditingTests {
    let table = TableMeta(name: "tb_member", columns: [
        ColumnMeta(name: "member_id", columnType: "bigint", nullable: false, columnKey: "PRI", position: 1),
        ColumnMeta(name: "email", columnType: "varchar(100)", nullable: true, position: 2),
        ColumnMeta(name: "status", columnType: "char(1)", nullable: false, position: 3),
    ], indexes: [IndexMeta(name: "PRIMARY", unique: true, columns: ["member_id"])])

    @Test func detectsSingleTable() {
        #expect(ResultEditing.singleTable(in: "SELECT * FROM tb_member WHERE status = 'A'") == "tb_member")
        #expect(ResultEditing.singleTable(in: "select m.* from `shop`.`tb_member` m order by 1") == "shop.tb_member")
        #expect(ResultEditing.singleTable(in: "SELECT * FROM [dbo].[tb_member]") == "dbo.tb_member")
        #expect(ResultEditing.singleTable(in: "SELECT * FROM a JOIN b ON a.id = b.id") == nil)
        #expect(ResultEditing.singleTable(in: "SELECT * FROM a, b") == nil)
        #expect(ResultEditing.singleTable(in: "SELECT status, COUNT(*) FROM a GROUP BY status") == nil)
        #expect(ResultEditing.singleTable(in: "SELECT * FROM a WHERE id IN (SELECT id FROM b)") == nil)
        #expect(ResultEditing.singleTable(in: "UPDATE a SET x = 1") == nil)
    }

    @Test func targetNeedsPrimaryKey() throws {
        let t = try ResultEditing.target(sql: "SELECT member_id, email FROM tb_member", columns: ["member_id", "email"], tables: [table])
        #expect(t.primaryKeyIndexes == [0])
        #expect(t.columnMap == [0: "member_id", 1: "email"])
        #expect(throws: ResultEditingError.primaryKeyNotSelected("member_id")) {
            try ResultEditing.target(sql: "SELECT email FROM tb_member", columns: ["email"], tables: [table])
        }
        #expect(throws: ResultEditingError.notSingleTable) {
            try ResultEditing.target(sql: "SELECT * FROM tb_member m JOIN x ON 1=1", columns: [], tables: [table])
        }
    }

    @Test func generatesStatements() throws {
        let t = try ResultEditing.target(sql: "SELECT * FROM tb_member", columns: ["member_id", "email", "status"], tables: [table])
        let rows = [QueryResult.Row(id: 0, values: ["1", "a@x.com", "A"]), QueryResult.Row(id: 1, values: ["2", nil, "A"])]
        var e = PendingEdits()
        e.updates[0] = [1: "it's@x.com", 2: nil]
        e.deletes = [1]
        e.inserts = [[0: "3", 1: "c@x.com"]]
        #expect(e.count == 4)
        let sql = ResultEditing.statements(e, target: t, rows: rows, dialect: MySQLDialect())
        #expect(sql == [
            "DELETE FROM `tb_member` WHERE `member_id` = '2';",
            "UPDATE `tb_member` SET `email` = 'it''s@x.com', `status` = NULL WHERE `member_id` = '1';",
            "INSERT INTO `tb_member` (`member_id`, `email`) VALUES ('3', 'c@x.com');",
        ])
        let ms = ResultEditing.statements(e, target: t, rows: rows, dialect: MSSQLDialect())
        #expect(ms[0] == "DELETE FROM [tb_member] WHERE [member_id] = N'2';")
    }
}

extension MultiDBChecks {
    /// 세 DB 공통: 결과 편집 → 트랜잭션 적용 → 실패 시 전부 되돌림
    static func editing(_ s: DBSession, container: String) async throws {
        let d = s.dialect
        _ = try? await s.raw(d.dropTableSQL("tb_edit_it"))
        // SQL Server 의 varchar 는 기본 정렬 규칙에서 한글을 못 담아서 nvarchar 를 쓴다
        let text = d.kind == .mssql ? "nvarchar(50)" : "varchar(50)"
        _ = try await s.raw("CREATE TABLE tb_edit_it (id int PRIMARY KEY, name \(text) NULL, memo \(text) NULL)")
        _ = try await s.raw("INSERT INTO tb_edit_it (id, name, memo) VALUES (1, 'a', 'x'), (2, 'b', 'y')")
        let tables = try await s.loadSchema(container)
        let sql = "SELECT * FROM tb_edit_it ORDER BY id"
        let r = try await s.execute(sql, limit: 500)
        let target = try ResultEditing.target(sql: sql, columns: r.columns.map(\.name), tables: tables)

        var e = PendingEdits()
        e.updates[0] = [1: "가나다", 2: nil]
        e.deletes = [1]
        e.inserts = [[0: "3", 1: "c"]]
        try await s.executeInTransaction(ResultEditing.statements(e, target: target, rows: r.rows, dialect: d))
        let after = try await s.execute(sql, limit: 500).rows.map(\.values)
        #expect(after == [["1", "가나다", nil], ["3", "c", nil]], "\(after)")

        // 중간에 실패하면 (중복 키) 앞의 변경도 되돌려야 한다
        var bad = PendingEdits()
        bad.updates[0] = [1: "바뀌면 안 됨"]
        bad.inserts = [[0: "3", 1: "dup"]]
        let rows2 = try await s.execute(sql, limit: 500).rows
        await #expect(throws: (any Error).self) {
            try await s.executeInTransaction(ResultEditing.statements(bad, target: target, rows: rows2, dialect: d))
        }
        let unchanged = try await s.execute(sql, limit: 500).rows.map(\.values)
        #expect(unchanged == after, "\(unchanged)")
        _ = try await s.raw(d.dropTableSQL("tb_edit_it"))
    }
}

@Suite("Binary text")
struct BinaryTextTests {
    @Test func hexAndLiterals() {
        #expect(BinaryText.hex([0xCD, 0x01, 0xFF]) == "0xCD01FF")
        #expect(BinaryText.isHex("0xcd01") && !BinaryText.isHex("0xC") && !BinaryText.isHex("abc"))
        #expect(MySQLDialect().binaryLiteral(hex: "CD01") == "X'CD01'")
        #expect(PostgresDialect().binaryLiteral(hex: "CD01") == "decode('CD01', 'hex')")
        #expect(MSSQLDialect().binaryLiteral(hex: "CD01") == "0xCD01")
    }
}

extension MultiDBChecks {
    /// 세 DB 공통: 바이너리 컬럼이 0x16진수로 보이고, 편집으로 바이너리 값을 저장할 수 있다
    static func binary(_ s: DBSession, container: String) async throws {
        let d = s.dialect
        let type = d.kind == .postgres ? "bytea" : "varbinary(16)"
        _ = try? await s.raw(d.dropTableSQL("tb_bin_it"))
        _ = try await s.raw("CREATE TABLE tb_bin_it (id int PRIMARY KEY, data \(type) NULL)")
        _ = try await s.raw("INSERT INTO tb_bin_it (id, data) VALUES (1, \(d.binaryLiteral(hex: "CD01FF00")))")
        let sql = "SELECT id, data FROM tb_bin_it"
        let r = try await s.execute(sql, limit: 500)
        #expect(r.rows.first?.values[1] == "0xCD01FF00", "\(String(describing: r.rows.first?.values))")

        let target = try ResultEditing.target(sql: sql, columns: r.columns.map(\.name), tables: try await s.loadSchema(container))
        var e = PendingEdits()
        e.updates[0] = [1: "0x0A0B"]
        try await s.executeInTransaction(ResultEditing.statements(e, target: target, rows: r.rows, dialect: d))
        #expect(try await s.execute(sql, limit: 500).rows.first?.values[1] == "0x0A0B")
        _ = try await s.raw(d.dropTableSQL("tb_bin_it"))
    }
}
