import Foundation
import Testing
@testable import GodDBCore

@Suite("ResultCopy")
struct ResultCopyTests {
    let cols = ["id", "name"]
    let rows: [[String?]] = [["1", "Kim, A"], ["2", nil]]

    @Test func tsvAndCsv() {
        let tsv = ResultCopy.text(.tsv, columns: cols, rows: rows)
        #expect(tsv.hasPrefix("id\tname"))
        #expect(tsv.contains("1\tKim, A"))
        let csv = ResultCopy.text(.csv, columns: cols, rows: rows)
        #expect(csv.contains("1,\"Kim, A\""))
        #expect(!csv.hasPrefix("\u{FEFF}"))
    }

    @Test func insertUsesTableName() {
        let sql = ResultCopy.text(.sql, columns: cols, rows: rows, tableName: "users", dialect: MySQLDialect())
        #expect(sql.contains("INSERT INTO"))
        #expect(sql.contains("users"))
        #expect(sql.contains("NULL"))
    }

    @Test func inListQuotesAndDedupes() {
        #expect(ResultCopy.inList(["1", "2", "2", nil]) == "(1, 2)")
        #expect(ResultCopy.inList(["a", "b'c", "007"]) == "('a', 'b''c', '007')")
    }

    @Test func quickFilter() {
        let w = ResultCopy.words("kim  A")
        #expect(ResultCopy.matches(["1", "Kim, A"], words: w))
        #expect(!ResultCopy.matches(["2", nil], words: w))
        #expect(ResultCopy.matches(["2", nil], words: ["null"]))
    }
}
