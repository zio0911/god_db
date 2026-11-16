import Foundation

/// 편집기 도구: 줄 주석 토글, SQL 정렬
public enum SQLEditing {
    // MARK: 주석 토글 (⌘/)

    /// 선택이 걸친 줄 전체를 `-- ` 주석으로 감싸거나 푼다. 모든 내용 줄이 주석이면 풀고, 아니면 단다.
    /// - Returns: 바꿀 범위(UTF-16)와 새 글자, 바꾼 뒤 선택할 범위
    public static func toggleLineComment(_ text: String, selection: NSRange) -> (range: NSRange, replacement: String, selection: NSRange) {
        let ns = text as NSString
        var lineRange = ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0))
        if selection.length > 0 {
            // 선택 끝이 줄 맨 앞이면 그 줄은 넣지 않는다
            var end = selection.location + selection.length
            if end > selection.location, end <= ns.length, end > 0, ns.character(at: end - 1) == 0x0A { end -= 1 }
            lineRange = ns.lineRange(for: NSRange(location: selection.location, length: max(0, end - selection.location)))
        }
        let block = ns.substring(with: lineRange)
        var lines = block.components(separatedBy: "\n")
        let trailingNewline = block.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !content.isEmpty && content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let indent = content.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let changed = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allCommented {
                guard let r = line.range(of: "--") else { return line }
                var after = line[r.upperBound...]
                if after.hasPrefix(" ") { after = after.dropFirst() }
                return String(line[..<r.lowerBound]) + after
            }
            let i = line.index(line.startIndex, offsetBy: indent)
            return String(line[..<i]) + "-- " + line[i...]
        }
        let replacement = changed.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let newSel = NSRange(location: lineRange.location, length: (replacement as NSString).length - (trailingNewline ? 1 : 0))
        return (lineRange, replacement, newSel)
    }

    // MARK: SQL 정렬 (⌥⌘L)

    enum Token: Equatable {
        case word(String), quoted(String), comment(String), symbol(String), space, newline
    }

    /// 문자열 · 따옴표 식별자 · 주석은 그대로 두고 나눈다
    static func tokenize(_ sql: String) -> [Token] {
        let c = Array(sql)
        var out: [Token] = []
        var i = 0
        func isWordChar(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" || ch == "$" || ch == "@" || ch == "." }
        while i < c.count {
            let ch = c[i]
            if ch == "\n" { out.append(.newline); i += 1; continue }
            if ch.isWhitespace { while i < c.count, c[i].isWhitespace, c[i] != "\n" { i += 1 }; out.append(.space); continue }
            if ch == "-" && i + 1 < c.count && c[i + 1] == "-" || ch == "#" {
                var j = i; while j < c.count, c[j] != "\n" { j += 1 }
                out.append(.comment(String(c[i..<j]))); i = j; continue
            }
            if ch == "/" && i + 1 < c.count && c[i + 1] == "*" {
                var j = i + 2
                while j + 1 < c.count, !(c[j] == "*" && c[j + 1] == "/") { j += 1 }
                j = min(c.count, j + 2)
                out.append(.comment(String(c[i..<j]))); i = j; continue
            }
            if ch == "'" || ch == "\"" || ch == "`" || ch == "[" {
                let close: Character = ch == "[" ? "]" : ch
                var j = i + 1
                while j < c.count {
                    if c[j] == "\\" && ch == "'" { j += 2; continue }
                    if c[j] == close {
                        if j + 1 < c.count, c[j + 1] == close, ch != "[" { j += 2; continue }
                        break
                    }
                    j += 1
                }
                j = min(c.count, j + 1)
                out.append(.quoted(String(c[i..<j]))); i = j; continue
            }
            if isWordChar(ch) {
                var j = i; while j < c.count, isWordChar(c[j]) { j += 1 }
                out.append(.word(String(c[i..<j]))); i = j; continue
            }
            out.append(.symbol(String(ch))); i += 1
        }
        return out
    }

    /// 줄을 바꿔 시작하는 절
    static let clauseStarts: [[String]] = [
        ["SELECT"], ["FROM"], ["WHERE"], ["GROUP", "BY"], ["ORDER", "BY"], ["HAVING"], ["LIMIT"], ["OFFSET"],
        ["UNION", "ALL"], ["UNION"], ["EXCEPT"], ["INTERSECT"],
        ["LEFT", "OUTER", "JOIN"], ["RIGHT", "OUTER", "JOIN"], ["FULL", "OUTER", "JOIN"],
        ["LEFT", "JOIN"], ["RIGHT", "JOIN"], ["INNER", "JOIN"], ["CROSS", "JOIN"], ["FULL", "JOIN"], ["JOIN"],
        ["INSERT", "INTO"], ["VALUES"], ["UPDATE"], ["SET"], ["DELETE", "FROM"], ["ON", "DUPLICATE", "KEY", "UPDATE"],
        ["RETURNING"], ["WITH"],
    ]
    static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "AS", "ON", "JOIN", "LEFT", "RIGHT", "FULL",
        "INNER", "OUTER", "CROSS", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CASE", "WHEN", "THEN", "ELSE", "END", "LIKE",
        "BETWEEN", "EXISTS", "ASC", "DESC", "WITH", "RETURNING", "DUPLICATE", "KEY", "EXCEPT", "INTERSECT", "TOP",
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "IFNULL", "TRUE", "FALSE",
    ]

    /// 절마다 줄을 바꾸고 AND / OR 는 들여 쓰며 키워드는 대문자로. 괄호 안(서브쿼리)은 한 단계 더 들여 쓴다.
    /// 문자열 · 주석 · 따옴표 식별자 글자는 바꾸지 않는다. 결과를 다시 정렬해도 같다.
    public static func format(_ sql: String, indent: String = "    ") -> String {
        let tokens = tokenize(sql)
        // 단어만 뽑아 절 시작을 찾는다
        var out = ""
        var depth = 0
        var i = 0
        var pendingSpace = false
        var lineStart = true
        func newline(_ extra: Int = 0) {
            while out.hasSuffix(" ") { out.removeLast() }
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            out += String(repeating: indent, count: max(0, depth + extra))
            lineStart = true
            pendingSpace = false
        }
        func emit(_ s: String) {
            if pendingSpace && !lineStart { out += " " }
            out += s
            pendingSpace = false
            lineStart = false
        }
        func wordsAhead(_ n: Int) -> [String] {
            var w: [String] = []
            var j = i
            while j < tokens.count, w.count < n {
                switch tokens[j] {
                case .word(let s): w.append(s.uppercased())
                case .space, .newline: break
                default: return w
                }
                j += 1
            }
            return w
        }
        while i < tokens.count {
            let t = tokens[i]
            switch t {
            case .space, .newline:
                pendingSpace = true
                i += 1
            case .comment(let s):
                emit(s)
                if s.hasPrefix("--") || s.hasPrefix("#") { newline() }
                i += 1
            case .quoted(let s):
                emit(s); i += 1
            case .symbol(let s):
                if s == "(" {
                    // 함수 호출 count(*) 처럼 원문에서 단어에 붙어 있던 괄호는 붙여 쓴다
                    if i > 0, case .word = tokens[i - 1] { pendingSpace = false }
                    emit(s); depth += 1; pendingSpace = false
                    // 괄호 바로 안이 SELECT 면 서브쿼리: 줄을 바꾼다
                    if wordsAheadAfter(i + 1, tokens).first == "SELECT" { newline() }
                } else if s == ")" {
                    depth = max(0, depth - 1)
                    while out.hasSuffix(" ") { out.removeLast() }
                    if out.hasSuffix("\n") || out.last?.isWhitespace == true && lineStart { }
                    pendingSpace = false
                    out += s; lineStart = false
                } else if s == "," {
                    while out.hasSuffix(" ") { out.removeLast() }
                    out += s; pendingSpace = true; lineStart = false
                } else if s == ";" {
                    while out.hasSuffix(" ") { out.removeLast() }
                    out += s
                    depth = 0
                    out += "\n"
                    lineStart = true; pendingSpace = false
                } else if s == "." {
                    while out.hasSuffix(" ") { out.removeLast() }
                    out += s; pendingSpace = false; lineStart = false
                } else {
                    emit(s); pendingSpace = true
                }
                i += 1
            case .word(let w):
                let upper = w.uppercased()
                if let clause = clauseStarts.first(where: { wordsAhead($0.count) == $0 }) {
                    if !(out.isEmpty || lineStart) { newline() } else if out.isEmpty { lineStart = true }
                    // 절 단어들을 한꺼번에 쓴다
                    var written = 0
                    while written < clause.count, i < tokens.count {
                        if case .word = tokens[i] { emit(clause[written]); pendingSpace = true; written += 1 }
                        i += 1
                    }
                    continue
                }
                if (upper == "AND" || upper == "OR") && !lineStart && !insideBetween(out) {
                    newline(1)
                }
                emit(keywords.contains(upper) ? upper : w)
                pendingSpace = true
                i += 1
            }
        }
        while out.hasSuffix(" ") || out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    static func wordsAheadAfter(_ start: Int, _ tokens: [Token]) -> [String] {
        var j = start
        while j < tokens.count {
            switch tokens[j] {
            case .word(let s): return [s.uppercased()]
            case .space, .newline: j += 1
            default: return []
            }
        }
        return []
    }

    /// BETWEEN a AND b 의 AND 는 줄을 바꾸지 않는다
    static func insideBetween(_ out: String) -> Bool {
        let tail = out.suffix(80).uppercased()
        guard let b = tail.range(of: "BETWEEN", options: .backwards) else { return false }
        return !tail[b.upperBound...].contains(" AND ")
    }
}
