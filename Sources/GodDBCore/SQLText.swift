import Foundation

/// SQL 문자열 처리 유틸 (구문 분리, 읽기전용 검사, LIMIT 자동 부여).
public enum SQLText {

    /// 세미콜론 기준으로 구문을 나눈다. 따옴표·백틱·주석 안의 세미콜론은 무시한다.
    /// 반환값의 range 는 원문(UTF-16 오프셋) 기준이다.
    public static func statements(in text: String) -> [(sql: String, range: Range<Int>)] {
        let chars = Array(text.utf16)
        var result: [(String, Range<Int>)] = []
        var start = 0
        var i = 0
        var quote: UInt16? = nil
        let semicolon = UInt16(UInt8(ascii: ";"))
        let backslash = UInt16(UInt8(ascii: "\\"))
        let dash = UInt16(UInt8(ascii: "-"))
        let hash = UInt16(UInt8(ascii: "#"))
        let slash = UInt16(UInt8(ascii: "/"))
        let star = UInt16(UInt8(ascii: "*"))
        let newline = UInt16(UInt8(ascii: "\n"))
        let backtick = UInt16(UInt8(ascii: "`"))
        let dollar = UInt16(UInt8(ascii: "$"))
        let quotes: Set<UInt16> = [UInt16(UInt8(ascii: "'")), UInt16(UInt8(ascii: "\"")), backtick]

        func flush(_ end: Int) {
            let s = String(utf16CodeUnits: Array(chars[start..<end]), count: end - start)
            if !stripComments(s).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append((s.trimmingCharacters(in: .whitespacesAndNewlines), start..<end))
            }
        }

        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == backslash && q != backtick { i += 2; continue }
                if c == q { quote = nil }
                i += 1
                continue
            }
            if quotes.contains(c) { quote = c; i += 1; continue }
            // PostgreSQL 달러 인용 ($$ … $$, $tag$ … $tag$) 안의 세미콜론은 무시
            if c == dollar, let tagEnd = dollarTagEnd(chars, from: i) {
                let tag = Array(chars[i...tagEnd])
                var j = tagEnd + 1
                var closed = false
                while j + tag.count <= chars.count {
                    if Array(chars[j..<(j + tag.count)]) == tag { j += tag.count; closed = true; break }
                    j += 1
                }
                i = closed ? j : chars.count
                continue
            }
            if c == hash || (c == dash && i + 1 < chars.count && chars[i + 1] == dash) {
                while i < chars.count && chars[i] != newline { i += 1 }
                continue
            }
            if c == slash && i + 1 < chars.count && chars[i + 1] == star {
                i += 2
                while i + 1 < chars.count && !(chars[i] == star && chars[i + 1] == slash) { i += 1 }
                i += 2
                continue
            }
            if c == semicolon {
                flush(i)
                start = i + 1
            }
            i += 1
        }
        if start < chars.count { flush(chars.count) }
        return result
    }

    /// `$tag$` 의 끝 `$` 위치. 달러 인용 시작이 아니면 nil. (앞 글자가 식별자 문자면 $1 같은 파라미터로 본다)
    static func dollarTagEnd(_ chars: [UInt16], from i: Int) -> Int? {
        if i > 0, let prev = UnicodeScalar(chars[i - 1]), CharacterSet.alphanumerics.contains(prev) || prev == "_" { return nil }
        var j = i + 1
        while j < chars.count {
            let c = chars[j]
            if c == UInt16(UInt8(ascii: "$")) { return j }
            guard let u = UnicodeScalar(c), CharacterSet.letters.contains(u) || u == "_" || (j > i + 1 && CharacterSet.decimalDigits.contains(u)) else { return nil }
            j += 1
        }
        return nil
    }

    /// 커서 위치(UTF-16 오프셋)가 속한 구문. 구문 사이 공백에 있으면 바로 앞 구문을 고른다.
    public static func statement(in text: String, at cursor: Int) -> String? {
        let all = statements(in: text)
        if let hit = all.first(where: { $0.range.lowerBound <= cursor && cursor <= $0.range.upperBound }) {
            return hit.sql
        }
        return all.last(where: { $0.range.upperBound <= cursor })?.sql ?? all.first?.sql
    }

    /// 주석 제거 (따옴표 안은 단순화를 위해 고려하지 않음 — 키워드 판별용)
    public static func stripComments(_ sql: String) -> String {
        var s = sql
        s = s.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(--|#)[^\\n]*", with: " ", options: .regularExpression)
        return s
    }

    public static func firstKeyword(_ sql: String) -> String {
        let cleaned = stripComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)
        let word = cleaned.prefix { $0.isLetter }
        return word.uppercased()
    }

    private static let readOnlyKeywords: Set<String> = ["SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "USE", "WITH"]
    private static let writeWords = ["INSERT", "UPDATE", "DELETE", "REPLACE", "DROP", "ALTER", "CREATE", "TRUNCATE", "RENAME", "GRANT", "REVOKE"]

    /// 읽기전용 접속에서 실행 가능한 구문인지 판별한다.
    public static func isReadOnly(_ sql: String) -> Bool {
        let kw = firstKeyword(sql)
        guard readOnlyKeywords.contains(kw) else { return false }
        let upper = stripComments(sql).uppercased()
        if upper.range(of: "\\bINTO\\s+(OUT|DUMP)FILE\\b", options: .regularExpression) != nil { return false }
        if kw == "WITH" {
            for w in writeWords where upper.range(of: "\\b\(w)\\b", options: .regularExpression) != nil {
                return false
            }
        }
        return true
    }

    /// LIMIT 이 없는 SELECT 에 LIMIT 을 붙인다.
    public static func applyingLimit(_ sql: String, limit: Int) -> String {
        guard limit > 0, firstKeyword(sql) == "SELECT" else { return sql }
        let upper = stripComments(sql).uppercased()
        if upper.range(of: "\\bLIMIT\\s+\\d", options: .regularExpression) != nil { return sql }
        if upper.range(of: "\\bFOR\\s+UPDATE\\b|\\bINTO\\b", options: .regularExpression) != nil { return sql }
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") { trimmed.removeLast() }
        return trimmed + "\nLIMIT \(limit)"
    }

    public static func quoteIdent(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    public static func quoteString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
    }
}
