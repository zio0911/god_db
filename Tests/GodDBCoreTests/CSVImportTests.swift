import Testing
@testable import GodDBCore

@Suite("CSVImport")
struct CSVImportTests {
    @Test func detectsDelimiter() {
        #expect(CSVImport.detectDelimiter("a,b,c\n1,2,3") == ",")
        #expect(CSVImport.detectDelimiter("a\tb\n1\t2") == "\t")
        #expect(CSVImport.detectDelimiter("a;b;c\n1;2;3") == ";")
        #expect(CSVImport.detectDelimiter("single") == ",")
    }

    @Test func parsesQuotesNewlinesAndBOM() {
        let text = "\u{FEFF}id,name,note\r\n1,\"Kim, A\",\"line1\nline2\"\r\n2,\"say \"\"hi\"\"\",\n\n"
        let rows = CSVImport.parse(text, delimiter: ",")
        #expect(rows.count == 3)
        #expect(rows[0] == ["id", "name", "note"])
        #expect(rows[1] == ["1", "Kim, A", "line1\nline2"])
        #expect(rows[2] == ["2", "say \"hi\"", ""])
    }

    @Test func autoMapsByNameOrPosition() {
        let cols = ["id", "user_name", "created_at"]
        #expect(CSVImport.autoMap(header: ["ID", "User Name", "unknown"], csvColumns: 3, tableColumns: cols) == ["id", "user_name", nil])
        #expect(CSVImport.autoMap(header: nil, csvColumns: 4, tableColumns: cols) == ["id", "user_name", "created_at", nil])
    }

    @Test func buildsBatchedInserts() {
        let rows = (1...5).map { ["\($0)", $0 == 2 ? "" : "n'\($0)", "skip"] }
        let sql = CSVImport.inserts(table: "t", mapping: ["id", "name", nil], rows: rows, dialect: MySQLDialect(), batch: 2)
        #expect(sql.count == 3)
        #expect(sql[0].hasPrefix("INSERT INTO `t` (`id`, `name`) VALUES"))
        #expect(sql[0].contains("('2', NULL)"))
        #expect(sql[0].contains("'n''1'") || sql[0].contains("'n\\'1'"))
        #expect(!sql[0].contains("skip"))
    }
}
