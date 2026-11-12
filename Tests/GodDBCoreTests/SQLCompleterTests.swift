import Foundation
import Testing
@testable import GodDBCore

@Suite("SQLCompleter")
struct SQLCompleterTests {
    let tables = [
        TableMeta(name: "tb_member", columns: [
            ColumnMeta(name: "member_id", columnType: "bigint", nullable: false, position: 1),
            ColumnMeta(name: "email", columnType: "varchar(100)", nullable: true, position: 2),
        ]),
        TableMeta(name: "tb_order", columns: [
            ColumnMeta(name: "order_id", columnType: "bigint", nullable: false, position: 1),
            ColumnMeta(name: "member_id", columnType: "bigint", nullable: false, position: 2),
        ]),
    ]

    @Test func resolvesAliases() {
        let a = SQLCompleter.aliases(in: "SELECT * FROM tb_member m JOIN tb_order AS o ON o.member_id = m.member_id WHERE")
        #expect(a["m"] == "tb_member")
        #expect(a["o"] == "tb_order")
        #expect(a["tb_member"] == "tb_member")
        #expect(SQLCompleter.aliases(in: "SELECT * FROM tb_member WHERE x")["where"] == nil)
        #expect(SQLCompleter.aliases(in: "SELECT * FROM shop.tb_member a, tb_order b")["b"] == "tb_order")
    }

    @Test func columnsAfterAliasDot() {
        let s = SQLCompleter.suggestions(prefix: "", qualifier: "o",
                                         statement: "SELECT o. FROM tb_order o", tables: tables)
        #expect(s == ["order_id", "member_id"])
        let e = SQLCompleter.suggestions(prefix: "em", qualifier: "m",
                                         statement: "SELECT m.em FROM tb_member m", tables: tables)
        #expect(e == ["email"])
    }

    @Test func tablesAfterFrom() {
        let s = SQLCompleter.suggestions(prefix: "tb_", qualifier: nil, statement: "SELECT * FROM tb_", tables: tables)
        #expect(s == ["tb_member", "tb_order"])
    }

    @Test func columnsOfUsedTablesThenKeywords() {
        let s = SQLCompleter.suggestions(prefix: "e", qualifier: nil,
                                         statement: "SELECT * FROM tb_member WHERE e", tables: tables)
        #expect(s.first == "email")
        #expect(s.contains("exists"))   // 소문자로 입력하면 소문자 키워드
        let k = SQLCompleter.suggestions(prefix: "SEL", qualifier: nil, statement: "SEL", tables: tables)
        #expect(k == ["SELECT"])
    }
}

@Suite("SQLText dollar quoting")
struct DollarQuoteTests {
    @Test func keepsFunctionBodyTogether() {
        let sql = "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; SELECT 2; $$ LANGUAGE sql; SELECT $1, 3;"
        let parts = SQLText.statements(in: sql).map(\.sql)
        #expect(parts.count == 2, "\(parts)")
        #expect(parts[0].hasSuffix("LANGUAGE sql"))
        let tagged = SQLText.statements(in: "DO $body$ BEGIN PERFORM 1; END $body$; SELECT 1")
        #expect(tagged.count == 2)
    }
}
