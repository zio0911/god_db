import Foundation
import Testing
@testable import GodDBCore

@Suite("Result export")
struct ResultExportTests {
    let cols = ["id", "name", "memo"]
    let rows: [[String?]] = [["1", "김철수", "a,b"], ["2", nil, "줄\n바꿈|파이프"], ["007", "x\"y", "1e5"]]

    func export(_ f: ExportFormat, _ opts: ExportOptions = ExportOptions(), dialect: (any SQLDialect)? = nil,
                pages: Int = 1) throws -> (URL, String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-test-\(UUID().uuidString).\(f.fileExtension)")
        let w = try ResultExportWriter(format: f, columns: cols, url: url, options: opts, dialect: dialect)
        for _ in 0..<pages { try w.write(rows) }
        try w.finish()
        #expect(w.rowsWritten == rows.count * pages)
        let text = f == .xlsx ? "" : (try String(contentsOf: url, encoding: .utf8))
        return (url, text)
    }

    @Test func csvAndTsv() throws {
        let (url, csv) = try export(.csv)
        #expect(try Data(contentsOf: url).prefix(3) == Data([0xEF, 0xBB, 0xBF]))   // BOM (String 으로 읽으면 빠짐)
        #expect(csv.hasPrefix("id,name,memo\r\n1,김철수,\"a,b\"\r\n"))
        #expect(csv.contains("2,,\"줄\n바꿈|파이프\"\r\n"))
        var o = ExportOptions(); o.excelBOM = false
        let (_, tsv) = try export(.tsv, o)
        #expect(tsv.hasPrefix("id\tname\tmemo\r\n"))
        #expect(tsv.contains("2\t\t줄 바꿈|파이프\r\n"))
    }

    @Test func jsonKeepsNumbersAndNulls() throws {
        let (_, json) = try export(.json)
        let data = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        #expect(data?.count == 3)
        #expect(data?[0]["id"] as? Int == 1)
        #expect(data?[1]["name"] is NSNull)
        #expect(data?[2]["id"] as? String == "007")     // 앞자리 0 은 문자열
        #expect(data?[2]["memo"] as? String == "1e5")   // 지수 표기도 문자열
    }

    @Test func sqlInsertBatches() throws {
        var o = ExportOptions(); o.tableName = "users"; o.insertBatch = 2
        let (_, sql) = try export(.sql, o, dialect: MySQLDialect(), pages: 2)
        #expect(sql.components(separatedBy: "INSERT INTO `users` (`id`, `name`, `memo`) VALUES").count - 1 == 3)
        #expect(sql.contains("('2', NULL, '줄\\n바꿈|파이프')") || sql.contains("('2', NULL, '줄\n바꿈|파이프')"))
    }

    @Test func markdownEscapes() throws {
        let (_, md) = try export(.markdown)
        #expect(md.hasPrefix("| id | name | memo |\n| --- | --- | --- |\n"))
        #expect(md.contains("| 2 | NULL | 줄<br>바꿈\\|파이프 |"))
    }

    @Test func xlsxIsValidZip() throws {
        var o = ExportOptions(); o.tableName = "a/b:c"
        let (url, _) = try export(.xlsx, o, pages: 3)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-unzip-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", url.path, "-d", out.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let sheet = try String(contentsOf: out.appendingPathComponent("xl/worksheets/sheet1.xml"), encoding: .utf8)
        #expect(sheet.components(separatedBy: "<row>").count - 1 == 1 + 9)   // 머리글 + 3행 × 3페이지
        #expect(sheet.contains("<c><v>1</v></c>"))
        #expect(sheet.contains("<t xml:space=\"preserve\">007</t>"))
        #expect(sheet.contains("<c/>"))
        let wb = try String(contentsOf: out.appendingPathComponent("xl/workbook.xml"), encoding: .utf8)
        #expect(wb.contains("name=\"a_b_c\""))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("[Content_Types].xml").path))
    }

    @Test func cancelRemovesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-cancel-\(UUID().uuidString).csv")
        let w = try ResultExportWriter(format: .csv, columns: cols, url: url)
        try w.write(rows)
        w.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func numberRule() {
        #expect(ResultExportWriter.isPlainNumber("12345"))
        #expect(ResultExportWriter.isPlainNumber("-3.25"))
        #expect(!ResultExportWriter.isPlainNumber("0012"))
        #expect(!ResultExportWriter.isPlainNumber("1234567890123456"))   // 16자리
        #expect(!ResultExportWriter.isPlainNumber("1e5"))
        #expect(!ResultExportWriter.isPlainNumber(""))
    }

    @Test func stableSortForPaging() {
        let c = ["id", "name"]
        #expect(ResultExportPlan.stableSort(sql: "SELECT * FROM t ORDER BY name", serverSort: nil, columns: c, primaryKey: ["id"]) == (nil, true))
        let r = ResultExportPlan.stableSort(sql: "SELECT * FROM t", serverSort: nil, columns: c, primaryKey: ["ID"])
        #expect(r.sort == ResultSort(column: "id", ascending: true) && r.stable)
        #expect(ResultExportPlan.stableSort(sql: "SELECT name FROM t", serverSort: nil, columns: ["name"], primaryKey: ["id"]).stable == false)
        let s = ResultSort(column: "name", ascending: false)
        #expect(ResultExportPlan.stableSort(sql: "SELECT * FROM t", serverSort: s, columns: c, primaryKey: nil).sort == s)
    }
}
