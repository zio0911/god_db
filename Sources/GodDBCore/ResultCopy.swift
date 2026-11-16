import Foundation

/// 결과 표에서 고른 행을 클립보드용 글자로 만든다 (내보내기와 같은 형식 규칙)
public enum ResultCopy {
    /// csv · tsv · json · sql(INSERT) · markdown. 내보내기 작성기를 임시 파일로 돌려 같은 결과를 낸다.
    public static func text(_ format: ExportFormat, columns: [String], rows: [[String?]],
                            tableName: String = "table", dialect: (any SQLDialect)? = nil) -> String {
        guard format != .xlsx else { return "" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var options = ExportOptions()
            options.excelBOM = false
            options.tableName = tableName
            let url = dir.appendingPathComponent("copy.\(format.fileExtension)")
            let writer = try ResultExportWriter(format: format, columns: columns, url: url, options: options, dialect: dialect)
            try writer.write(rows)
            try writer.finish()
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return ""
        }
    }

    /// 한 컬럼 값을 SQL IN 목록으로: (1, 2, 'a''b'). NULL · 중복은 뺀다.
    public static func inList(_ values: [String?], quote: (String) -> String = SQLText.quoteString) -> String {
        var seen = Set<String>()
        let items = values.compactMap { $0 }.filter { seen.insert($0).inserted }
            .map { ResultExportWriter.isPlainNumber($0) ? $0 : quote($0) }
        return "(" + items.joined(separator: ", ") + ")"
    }

    /// 빠른 필터: 모든 단어가 어느 칸에든 들어 있는 행 (대소문자 무시). NULL 은 "null" 로 찾는다.
    public static func matches(_ values: [String?], words: [String]) -> Bool {
        words.allSatisfy { w in values.contains { ($0 ?? "null").lowercased().contains(w) } }
    }

    public static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
