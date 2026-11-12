import Foundation
import Testing
@testable import GodDBCore

@Suite("Insert hints")
struct InsertHintsTests {
    let tables = [TableMeta(name: "tb_member", columns: [
        ColumnMeta(name: "member_id", columnType: "bigint", nullable: false, position: 1),
        ColumnMeta(name: "name", columnType: "varchar(50)", nullable: true, position: 2),
        ColumnMeta(name: "email", columnType: "varchar(100)", nullable: true, position: 3),
    ])]

    func labels(_ sql: String) -> [String] {
        let s = sql as NSString
        return InsertHints.hints(in: sql, tables: tables).map { h in
            // 힌트 위치부터 값 앞부분 몇 글자
            "\(h.column)=" + s.substring(with: NSRange(location: h.location, length: min(3, s.length - h.location)))
        }
    }

    @Test func explicitColumnList() {
        #expect(labels("insert into a (wow, id) values ('a', 'b')") == ["wow='a'", "id='b'"])
    }

    @Test func usesTableColumnsWhenNoList() {
        #expect(labels("INSERT INTO tb_member VALUES (1, 'kim', NULL)") == ["member_id=1, ", "name='ki", "email=NUL"])
    }

    @Test func multipleRowsQuotesAndFunctions() {
        let sql = "INSERT INTO `tb_member` (`name`, email) VALUES ('a,b', CONCAT('x', 'y')), ('it''s', NOW());"
        #expect(labels(sql) == ["name='a,", "email=CON", "name='it", "email=NOW"])
    }

    @Test func schemaQualifiedAndUnknownTable() {
        #expect(labels("insert into shop.tb_member values (7, 'a', 'b')").count == 3)
        #expect(labels("insert into unknown values (1, 2)").isEmpty)
    }

    @Test func ignoresCommentsAndStringsAndIncompleteInput() {
        #expect(labels("-- insert into tb_member values (1)\nselect 'insert into tb_member values (1)'").isEmpty)
        // 입력 중 (괄호 안 닫힘)
        #expect(labels("insert into tb_member values (1, 'k") == ["member_id=1, ", "name='k"])
        // 컬럼보다 값이 많으면 넘치는 값은 표시 안 함
        #expect(labels("insert into tb_member (name) values ('a', 'b')") == ["name='a'"])
    }

    @Test func locationsAreUTF16() {
        let sql = "insert into tb_member (name) values ('한글'), ('😀')"
        let hints = InsertHints.hints(in: sql, tables: tables)
        let s = sql as NSString
        #expect(hints.map { s.substring(with: NSRange(location: $0.location, length: 1)) } == ["'", "'"])
    }
}
