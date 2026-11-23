import Foundation
import MySQLNIO
import PostgresNIO

/// 쿼리를 **실행하지 않고** DB 에 문법 · 이름 검사만 맡긴다.
///   - MySQL: `PREPARE` 후 바로 `DEALLOCATE` (준비만 하고 실행 안 함)
///   - PostgreSQL · Redshift: `PREPARE … AS` 후 `DEALLOCATE`
///   - SQL Server: `sp_describe_first_result_set` (컴파일만, 실행 안 함)
public enum SQLServerCheck {
    /// 검사 결과 오류
    public struct Failure: Equatable, Sendable {
        public var message: String
        /// 구문 안 위치 (UTF-16), 모르면 nil
        public var range: NSRange?
    }

    static let name = "goddb_syntax_check"

    /// 이 구문을 검사할 수 있는 종류 (PREPARE 가 받는 문장만)
    static func checkable(_ sql: String, kind: DatabaseKind) -> Bool {
        let first = SQLText.stripComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0.isLetter }.uppercased()
        switch kind {
        case .mysql: return ["SELECT", "INSERT", "UPDATE", "DELETE", "REPLACE", "WITH"].contains(first)
        case .postgres: return ["SELECT", "INSERT", "UPDATE", "DELETE", "VALUES", "WITH"].contains(first)
        case .mssql: return ["SELECT", "INSERT", "UPDATE", "DELETE", "WITH", "MERGE"].contains(first)
        case .redis: return false
        }
    }

    /// 검사용 SQL 들 (차례로 실행), 마지막은 정리용 (실패해도 무시)
    static func commands(for sql: String, kind: DatabaseKind) -> (check: [String], cleanup: [String]) {
        let body = trimmed(sql)
        switch kind {
        case .mysql:
            // 따옴표 · 역슬래시 처리 문제를 피하려고 16진수로 넘긴다
            let hex = Data(body.utf8).map { String(format: "%02X", $0) }.joined()
            return (["SET @\(name) = CONVERT(X'\(hex)' USING utf8mb4)", "PREPARE \(name) FROM @\(name)"],
                    ["DEALLOCATE PREPARE \(name)", "SET @\(name) = NULL"])
        case .postgres:
            return (["PREPARE \(name) AS " + body], ["DEALLOCATE \(name)"])
        case .mssql:
            return (["EXEC sp_describe_first_result_set @tsql = N'" + body.replacingOccurrences(of: "'", with: "''") + "'"], [])
        case .redis:
            return ([], [])
        }
    }

    static func trimmed(_ sql: String) -> String {
        var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") { s.removeLast(); s = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return s
    }

    /// 무시할 오류 (검사 방식 자체의 한계)
    static func ignorable(_ message: String, kind: DatabaseKind) -> Bool {
        let m = message.lowercased()
        switch kind {
        case .mssql:
            // sp_describe_first_result_set 이 임시 테이블 · 동적 SQL 등을 분석하지 못한 경우
            return m.contains("could not be determined") || m.contains("sp_describe_first_result_set")
                || m.contains("#") || m.contains("temp")
        case .mysql:
            // PREPARE 가 받지 않는 문장
            return m.contains("not supported in the prepared statement protocol")
        case .postgres:
            return m.contains("already exists")
        case .redis:
            return true
        }
    }

    /// 오류를 구문 안 위치로 바꾼다.
    static func failure(from error: Error, sql: String, kind: DatabaseKind) -> Failure? {
        let body = trimmed(sql)
        var message = "\(error)"
        var range: NSRange? = nil
        var pgPosition: Int? = nil
        if let pg = error as? PSQLError {
            message = pg.serverInfo?[.message] ?? message
            pgPosition = pg.serverInfo?[.position].flatMap(Int.init)
        } else if let pg = error as? PostgresError, case .server(let e) = pg {
            message = e.fields[.message] ?? message
            pgPosition = e.fields[.position].flatMap(Int.init)
        }
        if kind == .postgres {
            // 위치는 "PREPARE … AS " 를 포함한 1부터 세는 글자 수
            if let p = pgPosition {
                let prefix = "PREPARE \(name) AS ".count
                let charIndex = p - 1 - prefix
                if charIndex >= 0, charIndex < body.count {
                    let idx = body.index(body.startIndex, offsetBy: charIndex)
                    let loc = body.utf16.distance(from: body.utf16.startIndex, to: idx.samePosition(in: body.utf16) ?? body.utf16.startIndex)
                    range = wordRange(in: body, at: loc)
                }
            }
        } else if let my = error as? MySQLError, case .server(let packet) = my {
            message = packet.errorMessage
        } else if let ms = error as? MSSQLError {
            message = ms.message
        }
        if ignorable(message, kind: kind) { return nil }
        if range == nil { range = guessRange(message: message, in: body) }
        return Failure(message: message, range: range)
    }

    /// 메시지 안의 'near …' · 'column …' 이름을 구문에서 찾아 위치를 정한다.
    static func guessRange(message: String, in sql: String) -> NSRange? {
        let ns = sql as NSString
        // MySQL: near 'xxx' at line N
        if let r = message.range(of: "near '"), let end = message[r.upperBound...].range(of: "' at line") {
            let snippet = String(message[r.upperBound..<end.lowerBound])
            let probe = String(snippet.prefix(40))
            if !probe.isEmpty {
                let found = ns.range(of: probe)
                if found.location != NSNotFound { return wordRange(in: sql, at: found.location) }
            } else {
                return NSRange(location: max(0, ns.length - 1), length: min(1, ns.length))  // 끝에서 끊김
            }
        }
        // 따옴표 안 이름: Unknown column 'a.username', Invalid column name 'username', column "username" does not exist
        let patterns = ["'([^']+)'", "\"([^\"]+)\""]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let r = Range(m.range(at: 1), in: message) else { continue }
            var name = String(message[r])
            // 'a.username' → 그대로 먼저, 없으면 마지막 부분
            for candidate in [name, String(name.split(separator: ".").last ?? "")] where !candidate.isEmpty {
                let found = ns.range(of: candidate, options: .caseInsensitive)
                if found.location != NSNotFound { return found }
            }
            name = ""
        }
        return nil
    }

    static func wordRange(in sql: String, at location: Int) -> NSRange {
        let ns = sql as NSString
        guard location < ns.length else { return NSRange(location: max(0, ns.length - 1), length: min(1, ns.length)) }
        var end = location
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$.`\"[]"))
        while end < ns.length, let u = UnicodeScalar(ns.character(at: end)), word.contains(u) { end += 1 }
        return NSRange(location: location, length: max(1, end - location))
    }
}

extension DBSession {
    /// 구문을 실행하지 않고 DB 에 검사만 맡긴다. 검사할 수 없거나 바쁘면 nil (오류 없음과 구분하지 않음).
    /// 실행 기록 · 감사 로그 · 유휴 시간에 남기지 않는다.
    public func serverCheck(_ sql: String) async -> SQLServerCheck.Failure?? {
        let kind = profile.kind
        guard kind != .redis, SQLServerCheck.checkable(sql, kind: kind), !isRunning else { return nil }
        // PostgreSQL 은 열린 트랜잭션 안에서 오류가 나면 트랜잭션 전체가 실패 상태가 된다 → 그때는 묻지 않음
        if kind == .postgres, inTransaction { return nil }
        guard let failure = await runCheck(sql) else { return .some(nil) }
        return .some(failure)
    }
}
