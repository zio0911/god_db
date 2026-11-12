import Foundation

/// INSERT … VALUES (…) 의 각 값이 어느 컬럼에 들어가는지 찾는다. (편집기에 회색 글씨로 보여주기만 하고 SQL 은 바꾸지 않는다)
public enum InsertHints {
    public struct Hint: Equatable, Sendable {
        /// 값이 시작하는 위치 (UTF-16 오프셋, NSString 기준)
        public let location: Int
        public let column: String
    }

    private static let insertRegex = try! NSRegularExpression(
        pattern: #"\bINSERT\s+(?:IGNORE\s+)?INTO\s+((?:`[^`]+`|"[^"]+"|\[[^\]]+\]|[A-Za-z0-9_$#@]+)(?:\s*\.\s*(?:`[^`]+`|"[^"]+"|\[[^\]]+\]|[A-Za-z0-9_$#@]+))*)\s*"#,
        options: [.caseInsensitive])

    /// - Parameter tables: 컬럼 목록을 쓰지 않은 INSERT 에서 테이블 컬럼 순서를 알기 위해
    public static func hints(in text: String, tables: [TableMeta], limit: Int = 2000) -> [Hint] {
        let s = text as NSString
        guard s.length < 200_000 else { return [] }
        var out: [Hint] = []
        let masked = maskCommentsAndStrings(s)
        for m in insertRegex.matches(in: masked, range: NSRange(location: 0, length: s.length)) {
            let tableName = unquote(s.substring(with: m.range(at: 1)))
            var i = m.range.location + m.range.length
            var columns: [String]? = nil
            // (컬럼 목록)
            if i < s.length, s.character(at: i) == 0x28 {
                guard let (items, end) = tuple(s, from: i) else { continue }
                columns = items.map { unquote(s.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                i = end
            }
            i = skipSpace(s, i)
            guard i + 6 <= s.length, s.substring(with: NSRange(location: i, length: 6)).uppercased() == "VALUES" else { continue }
            i = skipSpace(s, i + 6)
            let names = columns ?? table(tableName, in: tables)?.columns.sorted { $0.position < $1.position }.map(\.name)
            guard let names, !names.isEmpty else { continue }
            // (값, …), (값, …)
            while i < s.length, s.character(at: i) == 0x28 {
                guard let (items, end) = tuple(s, from: i) else { break }
                for (k, r) in items.enumerated() where k < names.count {
                    let start = skipSpace(s, r.location)
                    if start < r.location + r.length { out.append(Hint(location: start, column: names[k])) }
                }
                if out.count >= limit { return out }
                i = skipSpace(s, end)
                guard i < s.length, s.character(at: i) == 0x2C else { break }   // ,
                i = skipSpace(s, i + 1)
            }
        }
        return out
    }

    static func table(_ name: String, in tables: [TableMeta]) -> TableMeta? {
        let lower = name.lowercased()
        let last = name.split(separator: ".").last.map { String($0).lowercased() } ?? lower
        return tables.first { $0.name.lowercased() == lower } ?? tables.first { $0.name.lowercased() == last }
            ?? tables.first { $0.name.lowercased().hasSuffix("." + last) }
    }

    static func unquote(_ s: String) -> String {
        s.split(separator: ".").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`\"[]"))
        }.joined(separator: ".")
    }

    static func skipSpace(_ s: NSString, _ i: Int) -> Int {
        var i = i
        while i < s.length {
            let c = s.character(at: i)
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1; continue }
            // -- 주석
            if c == 0x2D, i + 1 < s.length, s.character(at: i + 1) == 0x2D {
                while i < s.length, s.character(at: i) != 0x0A { i += 1 }
                continue
            }
            if c == 0x2F, i + 1 < s.length, s.character(at: i + 1) == 0x2A {
                let r = s.range(of: "*/", range: NSRange(location: i + 2, length: s.length - i - 2))
                i = r.location == NSNotFound ? s.length : r.location + 2
                continue
            }
            break
        }
        return i
    }

    /// i 가 "(" 일 때 최상위 쉼표로 나눈 항목 범위들과 ")" 다음 위치. 닫히지 않았으면 끝까지 (입력 중).
    static func tuple(_ s: NSString, from start: Int) -> ([NSRange], Int)? {
        var depth = 0
        var i = start + 1
        var itemStart = i
        var items: [NSRange] = []
        while i < s.length {
            let c = s.character(at: i)
            switch c {
            case 0x27, 0x22, 0x60:   // ' " `
                i = skipQuoted(s, i, quote: c)
                continue
            case 0x28: depth += 1
            case 0x29:
                if depth == 0 {
                    items.append(NSRange(location: itemStart, length: i - itemStart))
                    return (items, i + 1)
                }
                depth -= 1
            case 0x2C where depth == 0:
                items.append(NSRange(location: itemStart, length: i - itemStart))
                itemStart = i + 1
            case 0x3B where depth == 0:   // ; 이면 구문이 끝남 (괄호가 안 닫힘)
                items.append(NSRange(location: itemStart, length: i - itemStart))
                return (items, i)
            default: break
            }
            i += 1
        }
        items.append(NSRange(location: itemStart, length: i - itemStart))
        return (items, i)
    }

    static func skipQuoted(_ s: NSString, _ start: Int, quote: unichar) -> Int {
        var i = start + 1
        while i < s.length {
            let c = s.character(at: i)
            if c == 0x5C && quote != 0x60 { i += 2; continue }   // \ 이스케이프
            if c == quote {
                if i + 1 < s.length, s.character(at: i + 1) == quote { i += 2; continue }   // '' 이스케이프
                return i + 1
            }
            i += 1
        }
        return i
    }

    /// 주석과 문자열 안의 INSERT 는 찾지 않도록 같은 길이의 공백으로 가린다.
    static func maskCommentsAndStrings(_ s: NSString) -> String {
        var chars = [unichar](repeating: 0, count: s.length)
        s.getCharacters(&chars, range: NSRange(location: 0, length: s.length))
        var i = 0
        func blank(_ a: Int, _ b: Int) { for k in a..<min(b, chars.count) where chars[k] != 0x0A { chars[k] = 0x20 } }
        while i < chars.count {
            let c = chars[i]
            if c == 0x27 || c == 0x22 {
                let end = skipQuoted(s, i, quote: c)
                blank(i, end); i = end; continue
            }
            if c == 0x2D, i + 1 < chars.count, chars[i + 1] == 0x2D {
                var e = i
                while e < chars.count, chars[e] != 0x0A { e += 1 }
                blank(i, e); i = e; continue
            }
            if c == 0x2F, i + 1 < chars.count, chars[i + 1] == 0x2A {
                let r = s.range(of: "*/", range: NSRange(location: i + 2, length: chars.count - i - 2))
                let e = r.location == NSNotFound ? chars.count : r.location + 2
                blank(i, e); i = e; continue
            }
            i += 1
        }
        return String(utf16CodeUnits: chars, count: chars.count)
    }
}
