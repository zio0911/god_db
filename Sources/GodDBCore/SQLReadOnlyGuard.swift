import Foundation

/// 읽기전용 접속의 문장 검사.
/// DB 별 규칙으로 토큰을 나눈 뒤(문자열 · 따옴표 식별자 · 주석 · 달러 인용은 코드가 아님) 문장 전체를 본다.
/// - 첫 단어가 SELECT / SHOW / DESC / EXPLAIN / USE / WITH 중 하나여야 하고
/// - 쓰기 · DDL · 세션 변경 단어가 어디에도 없어야 하며 (SQL Server 는 `;` 없이 문장을 이어 쓸 수 있다)
/// - 상태를 바꾸는 함수 호출 · 행 잠금(FOR UPDATE 등)이 없어야 한다.
/// 애매하면 막는다 (멀쩡한 조회를 막는 쪽이 쓰기를 통과시키는 쪽보다 낫다).
extension SQLText {

    /// 읽기전용 검사에 걸린 이유
    public enum ReadOnlyViolation: Equatable, Sendable {
        /// 첫 단어가 허용 목록에 없음 (빈 문자열이면 첫 단어가 없음)
        case leading(String)
        /// 문장 안의 쓰기 · DDL · 세션 변경 단어
        case keyword(String)
        /// 상태를 바꾸는 함수 호출 (소문자 이름)
        case function(String)
        /// 행 잠금 절 (FOR UPDATE 등)
        case lock(String)

        /// 걸린 단어 · 함수 · 절
        public var trigger: String {
            switch self {
            case .leading(let s), .keyword(let s), .lock(let s): return s
            case .function(let s): return s + "()"
            }
        }

        public var message: String {
            switch self {
            case .leading(let s):
                if s.isEmpty { return tr("읽기전용 접속이라 이 쿼리는 실행할 수 없어요. (SELECT / SHOW / DESC / EXPLAIN 만 허용)") }
                return tr("읽기전용 접속에서는 실행할 수 없어요: %@ (SELECT / SHOW / DESC / EXPLAIN 만 허용)", s)
            case .keyword(let s):
                return tr("읽기전용 접속에서는 실행할 수 없어요: %@ (문장 안에 있음)", s)
            case .function:
                return tr("읽기전용 접속에서는 실행할 수 없어요: %@ (상태를 바꾸는 함수)", trigger)
            case .lock(let s):
                return tr("읽기전용 접속에서는 실행할 수 없어요: %@ (행을 잠금)", s)
            }
        }
    }

    /// 읽기전용 접속에서 실행 가능한 구문인지 판별한다. (DB 종류에 따라 주석 · 문자열 규칙이 다르다)
    public static func isReadOnly(_ sql: String, kind: DatabaseKind) -> Bool {
        readOnlyViolation(sql, kind: kind) == nil
    }

    /// 읽기전용 접속에서 막아야 하면 그 이유. 실행해도 되면 nil.
    public static func readOnlyViolation(_ sql: String, kind: DatabaseKind) -> ReadOnlyViolation? {
        if kind == .mssql { return scanReadOnly(sqlTokens(sql, kind: kind, backslash: false), kind: kind) }
        // MySQL NO_BACKSLASH_ESCAPES · PostgreSQL standard_conforming_strings 설정에 따라 \ 의 뜻이 달라지므로 둘 다 본다
        return scanReadOnly(sqlTokens(sql, kind: kind, backslash: true), kind: kind)
            ?? scanReadOnly(sqlTokens(sql, kind: kind, backslash: false), kind: kind)
    }

    // MARK: - 토큰

    struct SQLToken: Equatable {
        enum Kind { case word, quoted, string, number, symbol }
        let kind: Kind
        /// word 는 대문자, quoted 는 따옴표 안 글자, symbol 은 그 글자
        let text: String

        func isWord(_ w: String) -> Bool { kind == .word && text == w }
        func isSymbol(_ s: String) -> Bool { kind == .symbol && text == s }
        var isIdentifier: Bool { kind == .word || kind == .quoted }
    }

    /// DB 별 규칙으로 토큰을 나눈다. 주석과 공백은 버린다.
    /// - backslash: 일반 문자열 안의 `\` 를 이스케이프로 볼지 (PostgreSQL 의 E'…' 는 항상 이스케이프)
    static func sqlTokens(_ sql: String, kind: DatabaseKind, backslash: Bool) -> [SQLToken] {
        let c = Array(sql.unicodeScalars)
        let n = c.count
        let mysql = kind == .mysql || kind == .redis
        let pg = kind == .postgres
        let ms = kind == .mssql
        var out: [SQLToken] = []
        var i = 0
        var inExecutableComment = false  // MySQL /*! … */ 안 (서버가 실행하는 주석)

        func at(_ k: Int) -> Unicode.Scalar? { k < n ? c[k] : nil }
        func isASCIILetter(_ u: Unicode.Scalar) -> Bool { (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") }
        func isDigit(_ u: Unicode.Scalar) -> Bool { u >= "0" && u <= "9" }
        /// 식별자 글자. ASCII 밖은 글자(letter)만 — 다른 기호는 구분자로 본다 (더 많이 잘라 보는 쪽이 안전)
        func isWordChar(_ u: Unicode.Scalar) -> Bool {
            if isASCIILetter(u) || isDigit(u) || u == "_" || u == "$" { return true }
            if ms && (u == "#" || u == "@") { return true }
            if mysql && u == "@" { return true }
            return u.value > 0x7F && CharacterSet.letters.contains(u)
        }
        func isWordStart(_ u: Unicode.Scalar) -> Bool {
            if isASCIILetter(u) || u == "_" { return true }
            if (ms || mysql) && (u == "@" || u == "$") { return true }
            if ms && u == "#" { return true }
            return u.value > 0x7F && CharacterSet.letters.contains(u)
        }
        func text(_ from: Int, _ to: Int) -> String {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: c[from..<min(to, n)])
            return String(s)
        }
        /// i 는 여는 따옴표. 닫는 따옴표 다음 위치를 돌려준다. (겹쳐 쓴 따옴표는 글자 하나)
        func skipQuoted(_ start: Int, close: Unicode.Scalar, escapes: Bool) -> Int {
            var j = start + 1
            while j < n {
                if escapes && c[j] == "\\" { j += 2; continue }
                if c[j] == close {
                    if at(j + 1) == close { j += 2; continue }
                    return j + 1
                }
                j += 1
            }
            return n
        }
        /// PostgreSQL `$tag$` 의 끝 `$` 위치 (달러 인용 시작이 아니면 nil)
        func dollarTagEnd(_ start: Int) -> Int? {
            if start > 0, isWordChar(c[start - 1]) { return nil }
            var j = start + 1
            while j < n {
                if c[j] == "$" { return j }
                guard isASCIILetter(c[j]) || c[j] == "_" || c[j].value > 0x7F || (j > start + 1 && isDigit(c[j])) else { return nil }
                j += 1
            }
            return nil
        }

        while i < n {
            let u = c[i]
            // 공백 (유니코드 공백 · 제어 문자 포함)
            if CharacterSet.whitespacesAndNewlines.contains(u) || CharacterSet.controlCharacters.contains(u) {
                i += 1; continue
            }
            // MySQL 실행 주석의 끝
            if inExecutableComment && u == "*" && at(i + 1) == "/" {
                inExecutableComment = false
                i += 2; continue
            }
            // 줄 주석: --  (MySQL 은 뒤에 공백 · 제어 문자 · 끝이 와야 주석)
            if u == "-" && at(i + 1) == "-" {
                let next = at(i + 2)
                let isComment = !mysql || next == nil
                    || CharacterSet.whitespacesAndNewlines.contains(next!) || CharacterSet.controlCharacters.contains(next!)
                if isComment {
                    while i < n && c[i] != "\n" { i += 1 }
                    continue
                }
            }
            // # 줄 주석은 MySQL 만 (SQL Server 는 #임시테이블, PostgreSQL 은 연산자)
            if mysql && u == "#" {
                while i < n && c[i] != "\n" { i += 1 }
                continue
            }
            // 블록 주석
            if u == "/" && at(i + 1) == "*" {
                if mysql && !inExecutableComment && (at(i + 2) == "!" || (at(i + 2) == "M" && at(i + 3) == "!")) {
                    // /*!50000 … */, /*M! … */ 는 MySQL · MariaDB 가 실행하는 코드
                    i += at(i + 2) == "!" ? 3 : 4
                    while i < n && isDigit(c[i]) { i += 1 }
                    inExecutableComment = true
                    continue
                }
                if mysql {
                    i += 2
                    while i < n && !(c[i] == "*" && at(i + 1) == "/") { i += 1 }
                    i = min(n, i + 2)
                } else {
                    // PostgreSQL · SQL Server 는 블록 주석을 겹쳐 쓸 수 있다
                    var depth = 1
                    i += 2
                    while i < n && depth > 0 {
                        if c[i] == "/" && at(i + 1) == "*" { depth += 1; i += 2 }
                        else if c[i] == "*" && at(i + 1) == "/" { depth -= 1; i += 2 }
                        else { i += 1 }
                    }
                }
                continue
            }
            // 문자열
            if u == "'" {
                let end = skipQuoted(i, close: "'", escapes: (mysql || pg) && backslash)
                out.append(SQLToken(kind: .string, text: text(i + 1, end - 1)))
                i = end; continue
            }
            // 따옴표 식별자 (MySQL 의 "…" 은 문자열일 수도 있다 — 어느 쪽이든 코드가 아님)
            if u == "\"" {
                let end = skipQuoted(i, close: "\"", escapes: mysql && backslash)
                out.append(SQLToken(kind: .quoted, text: text(i + 1, end - 1)))
                i = end; continue
            }
            if mysql && u == "`" {
                let end = skipQuoted(i, close: "`", escapes: false)
                out.append(SQLToken(kind: .quoted, text: text(i + 1, end - 1)))
                i = end; continue
            }
            if ms && u == "[" {
                let end = skipQuoted(i, close: "]", escapes: false)
                out.append(SQLToken(kind: .quoted, text: text(i + 1, end - 1)))
                i = end; continue
            }
            // PostgreSQL 달러 인용 $$ … $$, $tag$ … $tag$
            if pg && u == "$", let tagEnd = dollarTagEnd(i) {
                let tag = Array(c[i...tagEnd])
                var j = tagEnd + 1
                var bodyEnd = n
                while j + tag.count <= n {
                    if Array(c[j..<(j + tag.count)]) == tag { bodyEnd = j; j += tag.count; break }
                    j += 1
                }
                if bodyEnd == n { j = n }
                out.append(SQLToken(kind: .string, text: text(tagEnd + 1, bodyEnd)))
                i = j; continue
            }
            // 숫자: 숫자 · 소수점 · 지수까지만. 뒤에 붙은 글자는 새 단어로 본다 (SQL Server 는 1DELETE 를 1 과 DELETE 로 읽는다)
            if isDigit(u) || (u == "." && at(i + 1).map(isDigit) == true) {
                var j = i
                while j < n && (isDigit(c[j]) || c[j] == ".") { j += 1 }
                if j < n, c[j] == "e" || c[j] == "E" {
                    var k = j + 1
                    if k < n, c[k] == "+" || c[k] == "-" { k += 1 }
                    if k < n, isDigit(c[k]) {
                        j = k
                        while j < n && isDigit(c[j]) { j += 1 }
                    }
                }
                out.append(SQLToken(kind: .number, text: text(i, j)))
                i = j; continue
            }
            // 단어
            if isWordStart(u) {
                var j = i + 1
                while j < n && isWordChar(c[j]) { j += 1 }
                let word = text(i, j).uppercased()
                // PostgreSQL E'…' 는 항상 \ 이스케이프
                if pg && word == "E" && at(j) == "'" {
                    let end = skipQuoted(j, close: "'", escapes: true)
                    out.append(SQLToken(kind: .string, text: text(j + 1, end - 1)))
                    i = end; continue
                }
                out.append(SQLToken(kind: .word, text: word))
                i = j; continue
            }
            // 그 밖의 글자는 기호 하나
            out.append(SQLToken(kind: .symbol, text: String(Character(u))))
            i += 1
        }
        return out
    }

    // MARK: - 검사

    static let readOnlyLeading: Set<String> = ["SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "USE", "WITH"]

    /// 문장 어디에 있어도 막는 단어
    static let readOnlyBlockedWords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "REPLACE", "INTO",
        "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME", "GRANT", "REVOKE", "DENY",
        "EXEC", "EXECUTE", "CALL", "DO", "COPY", "LOAD", "LOCK", "UNLOCK",
        "VACUUM", "ANALYZE", "CLUSTER", "REINDEX", "REFRESH", "COMMENT", "SET", "DECLARE",
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT",
        "KILL", "SHUTDOWN", "HANDLER", "OPTIMIZE", "REPAIR", "FLUSH", "RESET", "PURGE", "INSTALL", "UNINSTALL",
        // PostgreSQL
        "NOTIFY", "LISTEN", "UNLISTEN", "DISCARD", "PREPARE", "REASSIGN", "IMPORT", "CHECKPOINT",
        // SQL Server
        "DBCC", "BACKUP", "RESTORE", "BULK", "RECONFIGURE", "WRITETEXT", "UPDATETEXT", "SETUSER", "ENABLE", "DISABLE",
    ]

    /// 상태를 바꾸는 함수 (대문자). 스키마를 붙여 불러도 (pg_catalog.set_config) 잡는다.
    static let readOnlyBlockedFunctions: Set<String> = [
        // PostgreSQL
        "SET_CONFIG", "NEXTVAL", "SETVAL", "PG_TERMINATE_BACKEND", "PG_CANCEL_BACKEND",
        "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE", "PG_SWITCH_WAL", "PG_PROMOTE", "PG_NOTIFY",
        "PG_READ_FILE", "PG_READ_BINARY_FILE", "PG_LS_DIR", "PG_STAT_FILE", "PG_LOGICAL_EMIT_MESSAGE",
        "PG_FILE_WRITE", "PG_FILE_UNLINK", "PG_FILE_RENAME", "PG_IMPORT_SYSTEM_COLLATIONS", "LOWRITE",
        "QUERY_TO_XML", "QUERY_TO_XMLSCHEMA", "QUERY_TO_XML_AND_XMLSCHEMA", "CURSOR_TO_XML",
        // MySQL
        "GET_LOCK", "RELEASE_LOCK", "RELEASE_ALL_LOCKS", "LOAD_FILE",
        // SQL Server
        "OPENQUERY", "OPENROWSET", "OPENDATASOURCE",
    ]
    static let readOnlyBlockedFunctionPrefixes = [
        "PG_ADVISORY_", "PG_TRY_ADVISORY_", "PG_STAT_RESET", "PG_CREATE_", "PG_DROP_", "PG_REPLICATION_",
        "PG_COPY_", "PG_WAL_REPLAY_", "DBLINK", "LO_",
    ]

    static func isBlockedFunction(_ name: String) -> Bool {
        let u = name.uppercased()
        return readOnlyBlockedFunctions.contains(u) || readOnlyBlockedFunctionPrefixes.contains { u.hasPrefix($0) }
    }

    static func scanReadOnly(_ t: [SQLToken], kind: DatabaseKind) -> ReadOnlyViolation? {
        guard let first = t.first, first.kind == .word else { return .leading("") }
        guard readOnlyLeading.contains(first.text) else { return .leading(first.text) }
        // EXPLAIN 의 옵션 범위: EXPLAIN ANALYZE … / EXPLAIN (ANALYZE, …) …
        let explainOptionsEnd: Int = {
            guard first.text == "EXPLAIN", t.count > 1 else { return 0 }
            if t[1].isSymbol("(") { return t.firstIndex { $0.isSymbol(")") } ?? t.count }
            return 1
        }()

        for (idx, tok) in t.enumerated() {
            let prev = idx > 0 ? t[idx - 1] : nil
            let next = idx + 1 < t.count ? t[idx + 1] : nil
            func word(_ k: Int) -> String? { k < t.count && t[k].kind == .word ? t[k].text : nil }

            // 행 잠금
            if tok.isWord("FOR") {
                switch (word(idx + 1), word(idx + 2), word(idx + 3)) {
                case ("UPDATE", _, _): return .lock("FOR UPDATE")
                case ("SHARE", _, _): return .lock("FOR SHARE")
                case ("NO", "KEY", "UPDATE"): return .lock("FOR NO KEY UPDATE")
                case ("KEY", "SHARE", _): return .lock("FOR KEY SHARE")
                default: break
                }
            }
            if tok.isWord("LOCK"), word(idx + 1) == "IN", word(idx + 2) == "SHARE", word(idx + 3) == "MODE" {
                return .lock("LOCK IN SHARE MODE")
            }
            // 함수 호출 name(
            if tok.isIdentifier, next?.isSymbol("(") == true, isBlockedFunction(tok.text) {
                return .function(tok.text.lowercased())
            }
            // SQL Server 시스템 · 확장 프로시저
            if kind == .mssql, tok.isIdentifier {
                let u = tok.text.uppercased()
                if u.hasPrefix("SP_") || u.hasPrefix("XP_") { return .function(tok.text.lowercased()) }
            }
            // SQL Server 상태를 바꾸는 문장 · 식 (#193). send · receive 는 열 이름일 수 있어 문장 자리에서만 막는다
            if kind == .mssql, tok.kind == .word || tok.isIdentifier {
                let u = tok.text.uppercased()
                let statementStart = prev == nil || prev!.isSymbol(";")
                let n1 = word(idx + 1)?.uppercased() ?? (idx + 1 < t.count ? t[idx + 1].text.uppercased() : nil)
                // Service Broker: 큐에서 메시지를 꺼내 지움 / 메시지 보내기
                if u == "RECEIVE", statementStart { return .keyword("RECEIVE") }
                if u == "SEND", n1 == "ON" { return .keyword("SEND") }
                // 시퀀스 값 늘리기: NEXT VALUE FOR seq
                if u == "NEXT", n1 == "VALUE", (word(idx + 2)?.uppercased() ?? (idx + 2 < t.count ? t[idx + 2].text.uppercased() : nil)) == "FOR" {
                    return .keyword("NEXT VALUE FOR")
                }
            }
            guard tok.kind == .word, readOnlyBlockedWords.contains(tok.text) else { continue }
            // 예외: 열 이름 · 별칭으로 쓴 경우 (t.comment, AS lock)
            if let prev, prev.isSymbol("."), idx >= 2, t[idx - 2].isIdentifier { continue }
            if let prev, prev.isWord("AS") { continue }
            switch tok.text {
            case "REPLACE" where next?.isSymbol("(") == true: continue  // REPLACE(col, 'a', 'b') 문자열 함수
            case "ANALYZE" where idx <= explainOptionsEnd: continue     // EXPLAIN ANALYZE SELECT (뒤 문장도 검사한다)
            case "CREATE" where first.text == "SHOW" && idx == 1: continue  // SHOW CREATE TABLE
            case "SET" where (kind == .mysql || kind == .redis) && prev?.isWord("CHARACTER") == true: continue  // CHARACTER SET utf8mb4
            case "COMMENT" where next?.isWord("ON") != true: continue  // COMMENT ON … 만 문장 (comment 열 이름은 흔하다)
            default: break
            }
            return .keyword(tok.text)
        }
        return nil
    }
}
