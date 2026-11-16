import Foundation

/// CSV / TSV 를 읽어 테이블에 넣는 INSERT 문을 만든다
public enum CSVImport {
    /// 첫 줄을 보고 구분자를 고른다 (쉼표 · 탭 · 세미콜론 중 가장 많은 것)
    public static func detectDelimiter(_ text: String) -> Character {
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let counts: [(Character, Int)] = [",", "\t", ";"].map { d in (d, first.filter { $0 == d }.count) }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    /// RFC 4180: 따옴표 안의 구분자 · 줄바꿈 · "" 를 처리한다. BOM 은 뗀다. 빈 줄은 건너뛴다.
    public static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == delimiter {
                endField()
            } else if c == "\r\n" || c == "\n" || c == "\r" {
                endRow()
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// CSV 머리글을 테이블 컬럼에 맞춘다 (대소문자 · 공백 · _ 무시). 머리글이 없으면 순서대로.
    /// 결과[i] = CSV i번째 열이 들어갈 테이블 컬럼 (nil 은 건너뜀)
    public static func autoMap(header: [String]?, csvColumns: Int, tableColumns: [String]) -> [String?] {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        guard let header else {
            return (0..<csvColumns).map { $0 < tableColumns.count ? tableColumns[$0] : nil }
        }
        let byName = Dictionary(tableColumns.map { (norm($0), $0) }, uniquingKeysWith: { a, _ in a })
        return (0..<csvColumns).map { i in i < header.count ? byName[norm(header[i])] : nil }
    }

    /// 여러 행 INSERT 문들 (batch 행씩). emptyAsNull 이면 빈 칸은 NULL.
    public static func inserts(table: String, mapping: [String?], rows: [[String]], dialect: any SQLDialect,
                               emptyAsNull: Bool = true, batch: Int = 200) -> [String] {
        let picked = mapping.enumerated().compactMap { i, c in c.map { (i, $0) } }
        guard !picked.isEmpty, !rows.isEmpty else { return [] }
        let head = "INSERT INTO \(dialect.quoteTable(table)) (" + picked.map { dialect.quoteIdent($0.1) }.joined(separator: ", ") + ") VALUES\n"
        let size = max(1, min(batch, 1000))   // SQL Server 는 VALUES 1000행까지
        var out: [String] = []
        var start = 0
        while start < rows.count {
            let chunk = rows[start..<min(rows.count, start + size)]
            let values = chunk.map { row in
                "(" + picked.map { i, _ in
                    let v = i < row.count ? row[i] : ""
                    return emptyAsNull && v.isEmpty ? "NULL" : dialect.quoteString(v)
                }.joined(separator: ", ") + ")"
            }
            out.append(head + values.joined(separator: ",\n"))
            start += size
        }
        return out
    }
}
