import Foundation
import Testing
@testable import GodDBCore

@Suite("SQLEditing")
struct SQLEditingTests {
    func apply(_ text: String, _ sel: NSRange) -> String {
        let r = SQLEditing.toggleLineComment(text, selection: sel)
        return (text as NSString).replacingCharacters(in: r.range, with: r.replacement)
    }

    @Test func commentsAndUncommentsSelectedLines() {
        let text = "SELECT 1;\n  SELECT 2;\nSELECT 3;"
        let once = apply(text, NSRange(location: 0, length: 15))
        #expect(once == "-- SELECT 1;\n--   SELECT 2;\nSELECT 3;")
        let back = apply(once, NSRange(location: 0, length: 20))
        #expect(back == text)
    }

    @Test func cursorOnlyTogglesItsLine() {
        let text = "a\nb\nc"
        #expect(apply(text, NSRange(location: 2, length: 0)) == "a\n-- b\nc")
    }

    @Test func keepsIndentAndBlankLines() {
        let text = "    x\n\n    y\n"
        #expect(apply(text, NSRange(location: 0, length: 12)) == "    -- x\n\n    -- y\n")
    }

    @Test func formatsClausesAndConditions() {
        let sql = "select a, b from t join u on u.id = t.uid where a = 1 and b in (1,2) order by a desc"
        #expect(SQLEditing.format(sql) == """
        SELECT a, b
        FROM t
        JOIN u ON u.id = t.uid
        WHERE a = 1
            AND b IN (1, 2)
        ORDER BY a DESC
        """)
    }

    @Test func keepsStringsCommentsAndIdentifiers() {
        let sql = "select 'from x where' as `select`, \"Where\" from t -- where note\nwhere x = 'a and b'"
        let f = SQLEditing.format(sql)
        #expect(f.contains("'from x where'"))
        #expect(f.contains("`select`"))
        #expect(f.contains("\"Where\""))
        #expect(f.contains("-- where note"))
        #expect(f.contains("'a and b'"))
    }

    @Test func betweenStaysOnOneLineAndIsStable() {
        let sql = "SELECT * FROM t WHERE d BETWEEN 1 AND 5 AND x = 2"
        let f = SQLEditing.format(sql)
        #expect(f.contains("BETWEEN 1 AND 5\n    AND x = 2"))
        #expect(SQLEditing.format(f) == f)
    }

    @Test func functionCallsStayAttached() {
        let f = SQLEditing.format("select count(*), max(x.y) from t where a in (1)")
        #expect(f.hasPrefix("SELECT COUNT(*), MAX(x.y)"))
        #expect(f.contains("IN (1)"))
    }

    @Test func subqueryIsIndented() {
        let f = SQLEditing.format("select * from t where id in (select id from u where x = 1)")
        #expect(f.contains("IN (\n    SELECT id\n    FROM u\n    WHERE x = 1)"))
    }
}
