import Foundation

/// 쿼리 편집기에 빨간 밑줄로 보여 줄 문제
public struct SQLIssue: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case local, server }
    /// 편집기 전체 글자 기준 위치 (UTF-16)
    public var range: NSRange
    public var message: String
    /// 덧붙일 안내 (예: 비슷한 컬럼)
    public var hint: String?
    public var source: Source

    public init(range: NSRange, message: String, hint: String? = nil, source: Source = .local) {
        self.range = range
        self.message = message
        self.hint = hint
        self.source = source
    }

    public var text: String { hint.map { message + "\n" + $0 } ?? message }
}

/// 서버에 묻지 않고 바로 찾는 쿼리 문제.
/// 틀린 경고를 내지 않는 것을 우선한다 — 확실한 경우만 표시하고, 애매하면 넘어간다.
public enum SQLLint {
    // MARK: - 토큰

    struct Token {
        enum Kind { case word, quoted, string, number, punct, op }
        var kind: Kind
        var text: String
        /// 문장 안 위치 (UTF-16)
        var range: NSRange
        var upper: String { text.uppercased() }
        /// 따옴표를 벗긴 이름
        var name: String {
            guard kind == .quoted, text.count >= 2 else { return text }
            return String(text.dropFirst().dropLast())
        }
        func isPunct(_ s: String) -> Bool { kind == .punct && text == s }
        var isName: Bool { kind == .word || kind == .quoted }
    }

    /// 닫히지 않은 따옴표/주석 위치
    struct Unclosed { var location: Int; var isComment: Bool }

    static func tokenize(_ s: String, kind: DatabaseKind?) -> (tokens: [Token], unclosed: Unclosed?) {
        let u = Array(s.utf16)
        var tokens: [Token] = []
        var i = 0
        func ch(_ k: Int) -> UInt16 { k < u.count ? u[k] : 0 }
        func isWordChar(_ c: UInt16) -> Bool {
            if c >= 0x80 { return true }  // 한글 등
            guard let sc = UnicodeScalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(sc) || c == 0x5F || c == 0x24 || c == 0x40
                || (c == 0x23 && kind == .mssql)
        }
        func add(_ k: Token.Kind, _ start: Int, _ end: Int) {
            let r = NSRange(location: start, length: end - start)
            tokens.append(Token(kind: k, text: String(utf16CodeUnits: Array(u[start..<end]), count: end - start), range: r))
        }
        while i < u.count {
            let c = u[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1; continue }
            // 주석
            if c == 0x2D, ch(i + 1) == 0x2D {
                while i < u.count, u[i] != 0x0A { i += 1 }
                continue
            }
            if c == 0x23, kind == .mysql {
                while i < u.count, u[i] != 0x0A { i += 1 }
                continue
            }
            if c == 0x2F, ch(i + 1) == 0x2A {
                let start = i
                i += 2
                while i < u.count, !(u[i] == 0x2A && ch(i + 1) == 0x2F) { i += 1 }
                if i >= u.count { return (tokens, Unclosed(location: start, isComment: true)) }
                i += 2
                continue
            }
            // PostgreSQL $태그$ … $태그$
            if c == 0x24, kind != .mysql, kind != .mssql {
                var j = i + 1
                while j < u.count, isWordChar(u[j]), u[j] != 0x24 { j += 1 }
                if j < u.count, u[j] == 0x24 {
                    let tag = Array(u[i...j])
                    var k = j + 1
                    var found = -1
                    while k + tag.count <= u.count {
                        if Array(u[k..<(k + tag.count)]) == tag { found = k; break }
                        k += 1
                    }
                    if found < 0 { return (tokens, Unclosed(location: i, isComment: false)) }
                    add(.string, i, found + tag.count)
                    i = found + tag.count
                    continue
                }
            }
            // 따옴표
            let doubleIsIdent = kind != .mysql
            if c == 0x27 || c == 0x22 || c == 0x60 || (c == 0x5B && kind == .mssql) {
                let close: UInt16 = c == 0x5B ? 0x5D : c
                let start = i
                i += 1
                var closed = false
                while i < u.count {
                    if u[i] == 0x5C, c != 0x5B, kind == .mysql || kind == nil { i += 2; continue }
                    if u[i] == close {
                        if ch(i + 1) == close, c != 0x5B { i += 2; continue }  // '' 이스케이프
                        i += 1
                        closed = true
                        break
                    }
                    i += 1
                }
                if !closed { return (tokens, Unclosed(location: start, isComment: false)) }
                let isString = c == 0x27 || (c == 0x22 && !doubleIsIdent)
                add(isString ? .string : .quoted, start, i)
                continue
            }
            if c >= 0x30 && c <= 0x39 {
                let start = i
                while i < u.count, (u[i] >= 0x30 && u[i] <= 0x39) || u[i] == 0x2E || u[i] == 0x65 || u[i] == 0x45 || u[i] == 0x78 {
                    i += 1
                }
                add(.number, start, i)
                continue
            }
            if isWordChar(c) || c == 0x3A && ch(i + 1) != 0x3A && isWordChar(ch(i + 1)) {
                let start = i
                i += 1
                while i < u.count, isWordChar(u[i]) { i += 1 }
                add(.word, start, i)
                continue
            }
            if c == 0x28 || c == 0x29 || c == 0x2C || c == 0x2E || c == 0x3B {
                add(.punct, i, i + 1)
                i += 1
                continue
            }
            // 연산자 (::, <=, >=, <>, !=, ->>, ->, ||)
            let start = i
            i += 1
            let ops: Set<UInt16> = [0x3A, 0x3C, 0x3E, 0x3D, 0x21, 0x7C, 0x2D, 0x26]
            while i < u.count, ops.contains(u[i]), i - start < 3 { i += 1 }
            add(.op, start, i)
        }
        return (tokens, nil)
    }

    // MARK: - 단어 목록

    static let clauseEnders: Set<String> = [
        "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION", "INTERSECT", "EXCEPT", "INTO", "OFFSET",
        "FETCH", "FOR", "WINDOW", "RETURNING", "ON", "USING", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS",
        "FULL", "NATURAL", "SET", "VALUES", "QUALIFY", "OPTION",
    ]

    /// 컬럼 이름이 아닌 단어 (키워드 · 괄호 없이 쓰는 함수 · 단위 · 타입)
    static let keywords: Set<String> = {
        let words = """
        SELECT FROM WHERE AND OR NOT IN IS NULL AS ON JOIN LEFT RIGHT INNER OUTER CROSS FULL NATURAL GROUP ORDER BY
        HAVING LIMIT OFFSET UNION ALL DISTINCT DISTINCTROW INTERSECT EXCEPT INSERT INTO VALUES VALUE UPDATE SET DELETE
        CREATE ALTER DROP TRUNCATE TABLE VIEW INDEX WITH RECURSIVE CASE WHEN THEN ELSE END LIKE ILIKE RLIKE REGEXP
        SIMILAR ESCAPE BETWEEN EXISTS ANY SOME ASC DESC NULLS FIRST LAST TRUE FALSE UNKNOWN XOR DIV MOD
        CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER SESSION_USER SYSTEM_USER USER LOCALTIME
        LOCALTIMESTAMP SYSDATE INTERVAL DATE TIME TIMESTAMP YEAR MONTH WEEK DAY HOUR MINUTE SECOND MICROSECOND
        QUARTER EPOCH ZONE AT COLLATE BINARY OVER PARTITION WINDOW ROWS RANGE UNBOUNDED PRECEDING FOLLOWING CURRENT
        ROW FETCH NEXT ONLY TOP PERCENT TIES FOR SHARE LOCK NOWAIT SKIP LOCKED USING ROLLUP CUBE GROUPING SETS
        FILTER WITHIN LATERAL RETURNING DUAL ROWNUM IGNORE REPLACE HIGH_PRIORITY LOW_PRIORITY STRAIGHT_JOIN
        SQL_CALC_FOUND_ROWS SQL_NO_CACHE SQL_CACHE SQL_SMALL_RESULT SQL_BIG_RESULT INT INTEGER BIGINT SMALLINT
        TINYINT DECIMAL NUMERIC FLOAT DOUBLE REAL CHAR VARCHAR NVARCHAR NCHAR TEXT BOOLEAN BOOL JSON JSONB UUID
        SIGNED UNSIGNED PRECISION VARYING CHARACTER NOLOCK OPTION QUALIFY MATCH AGAINST MODE BOOLEAN EXPANSION
        LANGUAGE NATURAL DEFAULT IDENTITY KEY PRIMARY FOREIGN REFERENCES CHECK CONSTRAINT UNIQUE
        """
        return Set(words.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }()

    static let statementStarters = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "WITH", "CREATE", "ALTER", "DROP", "TRUNCATE", "SHOW", "DESC",
        "DESCRIBE", "EXPLAIN", "USE", "CALL", "EXEC", "EXECUTE", "SET", "BEGIN", "COMMIT", "ROLLBACK", "GRANT",
        "REVOKE", "MERGE", "REPLACE", "VALUES", "DECLARE", "IF", "PRINT", "ANALYZE", "VACUUM", "COPY", "LOCK",
        "UNLOCK", "START", "RENAME", "OPTIMIZE", "KILL", "SAVEPOINT", "RELEASE", "PREPARE", "DEALLOCATE", "LOAD",
        "HANDLER", "CHECKPOINT", "REINDEX", "CLUSTER", "COMMENT", "DO", "GO", "WHILE", "RETURN", "TABLE", "UNLOAD",
    ]

    static let typoTargets = ["SELECT", "FROM", "WHERE", "JOIN", "ORDER", "GROUP", "HAVING", "LIMIT", "UPDATE",
                              "DELETE", "INSERT", "VALUES", "INNER", "LEFT", "RIGHT", "OUTER", "UNION", "DISTINCT"]

    /// 옆 글자 바꿈도 1 로 세는 편집 거리
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }

    static func typo(of word: String, in targets: [String], maxDistance: Int) -> String? {
        let w = word.uppercased()
        guard w.count >= 4, !keywords.contains(w), !targets.contains(w) else { return nil }
        return targets.first { abs($0.count - w.count) <= 1 && distance(w, $0) <= maxDistance }
    }

    // MARK: - 검사

    /// - Parameters:
    ///   - tables: 지금 스키마의 테이블 (컬럼 포함). 비어 있으면 컬럼 검사는 하지 않는다.
    ///   - schema: 지금 스키마 이름 (다른 스키마의 테이블을 잘못 검사하지 않게)
    public static func check(_ text: String, tables: [TableMeta], kind: DatabaseKind?, schema: String? = nil) -> [SQLIssue] {
        guard (text as NSString).length < 200_000 else { return [] }
        var out: [SQLIssue] = []
        for stmt in SQLText.statements(in: text) {
            let issues = checkStatement(stmt.sql, tables: tables, kind: kind, schema: schema)
            // SQLText 는 구문 앞 공백을 잘라낸다 → 원문에서 구문 시작 위치를 다시 찾는다
            let ns = text as NSString
            let searchStart = max(0, min(stmt.range.lowerBound, ns.length))
            let found = ns.range(of: stmt.sql, options: [], range: NSRange(location: searchStart, length: ns.length - searchStart))
            let base = found.location == NSNotFound ? stmt.range.lowerBound : found.location
            for var i in issues {
                i.range.location += base
                out.append(i)
            }
        }
        return out
    }

    static func checkStatement(_ sql: String, tables: [TableMeta], kind: DatabaseKind?, schema: String?) -> [SQLIssue] {
        let (tokens, unclosed) = tokenize(sql, kind: kind)
        var out: [SQLIssue] = []
        if let unclosed {
            let len = (sql as NSString).length - unclosed.location
            out.append(SQLIssue(range: NSRange(location: unclosed.location, length: max(1, len)),
                                message: unclosed.isComment ? tr("닫히지 않은 주석이에요.") : tr("닫히지 않은 따옴표예요.")))
        }
        guard let first = tokens.first else { return out }

        // 첫 단어 오타 (SELEC, UPDTAE …)
        if first.kind == .word, !statementStarters.contains(first.upper),
           let fix = typo(of: first.text, in: statementStarters, maxDistance: 2) {
            out.append(SQLIssue(range: first.range, message: tr("%@ 의 오타 같아요.", fix)))
        }

        // 괄호
        var stack: [Int] = []
        for (i, t) in tokens.enumerated() {
            if t.isPunct("(") { stack.append(i) }
            if t.isPunct(")") {
                if stack.isEmpty {
                    out.append(SQLIssue(range: t.range, message: tr("여는 괄호가 없어요.")))
                } else {
                    stack.removeLast()
                }
            }
        }
        if unclosed == nil {
            for i in stack { out.append(SQLIssue(range: tokens[i].range, message: tr("닫는 괄호가 없어요."))) }
        }

        // 콤마
        for (i, t) in tokens.enumerated() where t.isPunct(",") {
            let prev = i > 0 ? tokens[i - 1] : nil
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil
            if let next, next.isPunct(",") {
                out.append(SQLIssue(range: next.range, message: tr("콤마가 두 번 있어요.")))
            } else if next == nil || next!.isPunct(")") || next!.isPunct(";")
                        || (next!.kind == .word && ["FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION"].contains(next!.upper)) {
                out.append(SQLIssue(range: t.range, message: tr("콤마 뒤에 항목이 없어요.")))
            } else if let prev, prev.isPunct("(") || (prev.kind == .word && ["SELECT", "BY"].contains(prev.upper)) {
                out.append(SQLIssue(range: t.range, message: tr("콤마 앞에 항목이 없어요.")))
            }
        }

        out += missingCommas(tokens)

        // 키워드 오타 (FORM, WEHRE …): 아는 테이블 · 컬럼 이름이 아닐 때만
        let known = Set(tables.flatMap { [$0.name.uppercased()] + $0.columns.map { $0.name.uppercased() } })
        for (i, t) in tokens.enumerated() where i > 0 && t.kind == .word && !known.contains(t.upper) {
            let prev = tokens[i - 1]
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil
            if prev.isPunct(".") || next?.isPunct(".") == true || next?.isPunct("(") == true || prev.upper == "AS" { continue }
            if let fix = typo(of: t.text, in: typoTargets, maxDistance: 1) {
                out.append(SQLIssue(range: t.range, message: tr("%@ 의 오타 같아요.", fix)))
            }
        }

        if !tables.isEmpty, unclosed == nil {
            out += unknownColumns(tokens, tables: tables, schema: schema)
        }
        // 같은 자리 중복 제거
        var seen = Set<String>()
        return out.filter { seen.insert("\($0.range.location):\($0.range.length)").inserted }
    }

    /// 자리를 확실히 아는 경우만: 값/이름 뒤에 콤마 없이 `별칭.컬럼` 이 바로 오면 (`a.id a.name`)
    static func missingCommas(_ tokens: [Token]) -> [SQLIssue] {
        var out: [SQLIssue] = []
        // 깊이별 지금 절 (SELECT 목록 / GROUP BY / ORDER BY 만 검사)
        var clause: [Int: String] = [:]
        var depth = 0
        var i = 0
        var listStart = -1   // 목록 첫 항목 (앞에 수식어가 와도 콤마를 요구하지 않음)
        while i < tokens.count {
            let t = tokens[i]
            if t.isPunct("(") { depth += 1; clause[depth] = nil; i += 1; continue }
            if t.isPunct(")") { clause[depth] = nil; depth = max(0, depth - 1); i += 1; continue }
            if t.kind == .word {
                let up = t.upper
                if up == "SELECT" {
                    clause[depth] = "list"
                    // SELECT 수식어 건너뛰기: DISTINCT [ON (…)], ALL, TOP n / TOP (n) [PERCENT] [WITH TIES]
                    var j = i + 1
                    while j < tokens.count {
                        let m = tokens[j].upper
                        if ["DISTINCT", "ALL", "DISTINCTROW", "HIGH_PRIORITY", "STRAIGHT_JOIN", "PERCENT"].contains(m) || m.hasPrefix("SQL_") {
                            j += 1
                            if m == "DISTINCT", j < tokens.count, tokens[j].upper == "ON", j + 1 < tokens.count, tokens[j + 1].isPunct("(") {
                                j = skipParens(tokens, from: j + 1)
                            }
                        } else if m == "TOP" {
                            j += 1
                            if j < tokens.count, tokens[j].isPunct("(") { j = skipParens(tokens, from: j) } else { j += 1 }
                        } else if m == "WITH", j + 1 < tokens.count, tokens[j + 1].upper == "TIES" {
                            j += 2
                        } else {
                            break
                        }
                    }
                    i = j
                    listStart = j
                    continue
                }
                if up == "BY", i > 0, ["GROUP", "ORDER"].contains(tokens[i - 1].upper) {
                    clause[depth] = "list"
                    i += 1
                    listStart = i
                    continue
                }
                if clauseEnders.contains(up) && up != "ORDER" && up != "GROUP" { clause[depth] = nil }
                if up == "ORDER" || up == "GROUP" { clause[depth] = nil }
            }
            if clause[depth] == "list", i > 0, i != listStart, t.isName, !keywords.contains(t.upper) || t.kind == .quoted,
               i + 2 < tokens.count, tokens[i + 1].isPunct("."), tokens[i + 2].isName || tokens[i + 2].kind == .op,
               !tokens[i - 1].isPunct(".") {
                let prev = tokens[i - 1]
                let prevEndsValue = (prev.kind == .word && !keywords.contains(prev.upper)) || prev.kind == .quoted
                    || prev.kind == .number || prev.kind == .string || prev.isPunct(")")
                if prevEndsValue {
                    let end = tokens[i + 2].range
                    out.append(SQLIssue(range: NSRange(location: t.range.location, length: end.location + end.length - t.range.location),
                                        message: tr("앞 항목과 사이에 콤마가 빠진 것 같아요.")))
                }
            }
            i += 1
        }
        return out
    }

    static func skipParens(_ tokens: [Token], from start: Int) -> Int {
        var d = 0
        var j = start
        while j < tokens.count {
            if tokens[j].isPunct("(") { d += 1 }
            if tokens[j].isPunct(")") { d -= 1; if d == 0 { return j + 1 } }
            j += 1
        }
        return j
    }

    // MARK: - 없는 컬럼

    struct TableRef {
        var table: String
        var alias: String?
        /// db.table / schema.table 처럼 앞에 붙은 이름
        var qualifier: String?
    }

    /// FROM / JOIN / UPDATE / INTO / 쉼표 뒤 테이블과 별칭
    static func tableRefs(_ tokens: [Token]) -> (refs: [TableRef], hasSubquery: Bool, cteNames: Set<String>) {
        var refs: [TableRef] = []
        var hasSubquery = false
        var ctes: Set<String> = []
        var inFrom = false
        var depth = 0
        var fromDepth = 0
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.isPunct("(") {
                depth += 1
                if i + 1 < tokens.count, ["SELECT", "WITH"].contains(tokens[i + 1].upper) { hasSubquery = true }
            }
            if t.isPunct(")") { depth -= 1 }
            // WITH 이름 AS (
            if t.isName, i + 2 < tokens.count, tokens[i + 1].upper == "AS", tokens[i + 2].isPunct("("),
               i > 0, tokens[i - 1].upper == "WITH" || tokens[i - 1].isPunct(",") || tokens[i - 1].upper == "RECURSIVE" {
                ctes.insert(t.name.lowercased())
            }
            let up = t.kind == .word ? t.upper : ""
            let startsRef = ["FROM", "JOIN", "UPDATE", "INTO"].contains(up) || (inFrom && depth == fromDepth && t.isPunct(","))
            if ["WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION", "SET", "ON", "USING", "VALUES", "WINDOW"].contains(up) && depth == fromDepth {
                inFrom = false
            }
            if startsRef {
                if up == "FROM" || up == "JOIN" { inFrom = true; fromDepth = depth }
                var j = i + 1
                var parts: [String] = []
                while j < tokens.count, tokens[j].isName, !(tokens[j].kind == .word && keywords.contains(tokens[j].upper) && parts.isEmpty && tokens[j].upper != "USER") {
                    parts.append(tokens[j].name)
                    if j + 1 < tokens.count, tokens[j + 1].isPunct(".") { j += 2 } else { j += 1; break }
                }
                if let table = parts.last {
                    var ref = TableRef(table: table, alias: nil, qualifier: parts.count > 1 ? parts[parts.count - 2] : nil)
                    if j < tokens.count, tokens[j].upper == "AS" { j += 1 }
                    if j < tokens.count, tokens[j].isName, !(tokens[j].kind == .word && (keywords.contains(tokens[j].upper) || clauseEnders.contains(tokens[j].upper))) {
                        ref.alias = tokens[j].name
                        j += 1
                    }
                    refs.append(ref)
                    i = j
                    continue
                }
            }
            i += 1
        }
        return (refs, hasSubquery, ctes)
    }

    static func unknownColumns(_ tokens: [Token], tables: [TableMeta], schema: String?) -> [SQLIssue] {
        let byName = Dictionary(tables.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let (refs, hasSubquery, ctes) = tableRefs(tokens)
        // 별칭/테이블 이름 → 테이블 (다른 스키마 · CTE · 모르는 테이블은 빼서 검사하지 않음)
        var resolve: [String: TableMeta] = [:]
        var blocked: Set<String> = ctes
        for r in refs {
            let key = r.table.lowercased()
            let otherSchema = r.qualifier.map { q in schema.map { q.lowercased() != $0.lowercased() } ?? true } ?? false
            guard !ctes.contains(key), !otherSchema, let t = byName[key], !t.columns.isEmpty else {
                blocked.insert(key)
                if let a = r.alias { blocked.insert(a.lowercased()) }
                continue
            }
            if let a = r.alias { resolve[a.lowercased()] = t } else { resolve[key] = t }
            if r.alias == nil { resolve[key] = t }
        }
        var out: [SQLIssue] = []
        func columnIssue(_ name: Token, table: TableMeta) -> SQLIssue? {
            let col = name.name
            guard !table.columns.contains(where: { $0.name.caseInsensitiveCompare(col) == .orderedSame }) else { return nil }
            var hint: String? = nil
            if let best = SQLCompleter.closest(to: col, in: table.columns.map(\.name)).first,
               best.lowercased().contains(col.lowercased()) || col.lowercased().contains(best.lowercased())
                || distance(best.lowercased(), col.lowercased()) <= max(2, col.count / 3) {
                hint = tr("비슷한 컬럼: %@", best)
            }
            return SQLIssue(range: name.range, message: tr("%@ 테이블에 %@ 컬럼이 없어요.", table.name, col), hint: hint)
        }

        // 1) 별칭.컬럼
        for i in tokens.indices where i + 2 < tokens.count {
            let q = tokens[i], dot = tokens[i + 1], c = tokens[i + 2]
            guard q.isName, dot.isPunct("."), c.isName else { continue }
            if i > 0, tokens[i - 1].isPunct(".") { continue }                      // a.b.c
            if i + 3 < tokens.count, tokens[i + 3].isPunct(".") || tokens[i + 3].isPunct("(") { continue }  // 스키마.테이블. / 함수
            if i > 0, ["FROM", "JOIN", "UPDATE", "INTO", "TABLE"].contains(tokens[i - 1].upper) { continue }
            let key = q.name.lowercased()
            guard !blocked.contains(key), let table = resolve[key] else { continue }
            if let issue = columnIssue(c, table: table) { out.append(issue) }
        }

        // 2) 테이블 하나짜리 단순 SELECT 의 이름만 쓴 컬럼
        guard tokens.first?.upper == "SELECT", refs.count == 1, !hasSubquery, ctes.isEmpty,
              let only = refs.first, let table = resolve[(only.alias ?? only.table).lowercased()],
              !tokens.contains(where: { ["JOIN", "UNION", "INTO", "INTERSECT", "EXCEPT"].contains($0.upper) }) else { return out }
        // SELECT 목록에서 만든 별칭 (x AS y, x y) 은 컬럼이 아님
        var selectAliases: Set<String> = []
        for (i, t) in tokens.enumerated() where t.isName && i > 0 {
            let prev = tokens[i - 1]
            if prev.upper == "AS" { selectAliases.insert(t.name.lowercased()) }
        }
        var clause = ""
        var depth = 0
        for (i, t) in tokens.enumerated() {
            if t.isPunct("(") { depth += 1; continue }
            if t.isPunct(")") { depth -= 1; continue }
            guard depth == 0 else { continue }
            let up = t.kind == .word ? t.upper : ""
            if up == "SELECT" { clause = "select"; continue }
            if up == "FROM" { clause = "from"; continue }
            if ["WHERE", "HAVING"].contains(up) { clause = "cond"; continue }
            if up == "BY", i > 0, ["GROUP", "ORDER"].contains(tokens[i - 1].upper) { clause = "by"; continue }
            if ["LIMIT", "OFFSET", "FETCH", "FOR", "WINDOW", "OPTION"].contains(up) { clause = "other"; continue }
            guard ["select", "cond", "by"].contains(clause), t.isName else { continue }
            if t.kind == .word && (keywords.contains(up) || t.text.hasPrefix("@") || t.text.hasPrefix(":") || t.text.hasPrefix("#")) { continue }
            let prev = i > 0 ? tokens[i - 1] : nil
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil
            if prev?.isPunct(".") == true || next?.isPunct(".") == true || next?.isPunct("(") == true { continue }
            if prev?.upper == "AS" || prev?.kind == .op && prev?.text == "::" { continue }
            let lower = t.name.lowercased()
            if selectAliases.contains(lower) || lower == only.table.lowercased() || lower == only.alias?.lowercased() { continue }
            // SELECT 목록의 "값 별칭" (a.x name, COUNT(*) cnt) 은 넘어간다
            if clause == "select", let prev,
               (prev.kind == .word && !keywords.contains(prev.upper)) || prev.kind == .quoted || prev.kind == .number
                || prev.kind == .string || prev.isPunct(")") {
                continue
            }
            if let issue = columnIssue(t, table: table) { out.append(issue) }
        }
        return out
    }
}
