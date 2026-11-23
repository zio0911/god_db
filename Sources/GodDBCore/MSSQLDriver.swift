import CFreeTDS
import Foundation

/// SQL Server 오류 (서버 메시지 번호 또는 DB-Library 오류 번호)
public struct MSSQLError: LocalizedError, Sendable {
    public let number: Int
    public let message: String

    public var errorDescription: String? { "[\(number)] \(message)" }
}

/// FreeTDS 콜백은 C 함수 포인터라 상태를 캡처할 수 없다.
/// DB-Library 호출은 항상 한 스레드에서 동기로 실행되고 콜백도 같은 스레드에서 불리므로 스레드 로컬에 모은다.
private enum MessageBox {
    static let key = "GodDB.mssql.messages"

    static func reset() { Thread.current.threadDictionary[key] = [MSSQLError]() }

    static func append(_ e: MSSQLError) {
        var list = Thread.current.threadDictionary[key] as? [MSSQLError] ?? []
        list.append(e)
        Thread.current.threadDictionary[key] = list
    }

    static var errors: [MSSQLError] { Thread.current.threadDictionary[key] as? [MSSQLError] ?? [] }
}

private let errHandler: EHANDLEFUNC = { _, _, dberr, _, dberrstr, oserrstr in
    var text = dberrstr.map { String(cString: $0) } ?? tr("DB-Library 오류")
    if let os = oserrstr.map({ String(cString: $0) }), !os.isEmpty, os != "Success" { text += " (\(os))" }
    MessageBox.append(MSSQLError(number: Int(dberr), message: text))
    return INT_CANCEL
}

private let msgHandler: MHANDLEFUNC = { _, msgno, _, severity, msgtext, _, _, _ in
    // severity 10 이하는 정보 메시지 (예: "Changed database context to ...")
    if severity > 10 {
        MessageBox.append(MSSQLError(number: Int(msgno), message: msgtext.map { String(cString: $0) } ?? ""))
    }
    return 0
}

private let dblibInit: Void = {
    dbinit()
    dberrhandle(errHandler)
    dbmsghandle(msgHandler)
    dbsetlogintime(10)
    // 연결별 TLS 섹션을 넣는 설정 파일 (MSSQLConfigFile). 파일이 없거나 섹션이 없으면 FreeTDS 는 원래대로 찾는다.
    dbsetifile(strdup(MSSQLConfigFile.path))
}()

/// FreeTDS DB-Library 기반 SQL Server 드라이버. 블로킹 API 라서 전용 직렬 큐에서 실행한다.
final class MSSQLDriver: DBDriver, @unchecked Sendable {
    private let queue = DispatchQueue(label: "GodDB.mssql")
    private var proc: OpaquePointer?
    /// 연결 후 상태창에 남길 TLS 상태 (F9-3)
    private(set) var tlsStatus: TLSStatus = .off

    private init(_ proc: OpaquePointer) { self.proc = proc }

    static func connect(_ e: DriverEndpoint) async throws -> MSSQLDriver {
        _ = dblibInit
        // F9-3: 확인을 켜면 서버 인증서를 먼저 받아 판정하고(MSSQLTLS), FreeTDS 도 그 결과에 맞게 다시 확인하게 한다.
        // 터널 · 고정 없음이면 확인할 게 없어 받지 않는다 (다른 DB 와 같이 "확인 안 함(SSH 터널)").
        let verifier = e.useTLS && e.tls.verify ? TLSVerifier(policy: e.tls) : nil
        let needsProbe = verifier.map { $0.policy.hostname != nil || $0.policy.pin != nil } ?? false
        let driver: MSSQLDriver = try await HostResolver.withTLS(verifier) {
            try await HostResolver.tryEach(e.host, port: e.port) { ip in
                var check: MSSQLTLS.FreeTDSCheck?
                if let verifier, needsProbe {
                    let probe = try await MSSQLTLS.probe(ip: ip, port: e.port, serverName: e.serverName, verifier: verifier)
                    check = MSSQLTLS.freeTDSCheck(verdict: probe.verdict, chain: probe.chain, hostname: verifier.policy.hostname)
                }
                return try await open(e, ip: ip, check: check)
            }
        }
        driver.tlsStatus = e.useTLS ? (verifier?.status ?? .unchecked) : .off
        // DB-Library 기본 세션은 ANSI_PADDING 등이 꺼져 있다 (varbinary 끝의 0 이 잘리고, 컬럼 기본값이 NOT NULL 등).
        // JDBC · ODBC 드라이버와 같은 표준 설정으로 맞춘다.
        _ = try await driver.query("""
            SET ANSI_NULLS ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ANSI_NULL_DFLT_ON ON;
            SET CONCAT_NULL_YIELDS_NULL ON; SET QUOTED_IDENTIFIER ON; SET ARITHABORT ON
            """)
        return driver
    }

    /// DB-Library 로 한 주소에 연결한다. check 가 있으면 연결별 freetds.conf 섹션(ca file · 이름 확인)으로 연결한다.
    static func open(_ e: DriverEndpoint, ip: String, check: MSSQLTLS.FreeTDSCheck?) async throws -> MSSQLDriver {
        _ = dblibInit
        let entry = try check.map { try MSSQLConfigFile.add(ip: ip, port: e.port, check: $0) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MSSQLDriver, Error>) in
            DispatchQueue.global().async {
                let result = Result { try openSync(e, server: entry?.name ?? ip, ip: ip, checked: check != nil) }
                // 설정 파일은 dbopen 안에서 읽으므로 연결이 끝나면(성공 · 실패) 섹션과 CA 파일을 지운다 (결과를 넘기기 전에)
                entry.map(MSSQLConfigFile.remove)
                cont.resume(with: result)
            }
        }
    }

    /// - server: FreeTDS 에 넘길 서버 이름 (인증서를 확인하면 섹션 이름 — 섹션의 host 가 같은 IP)
    private static func openSync(_ e: DriverEndpoint, server: String, ip: String, checked: Bool) throws -> MSSQLDriver {
        MessageBox.reset()
        guard let login = dblogin() else {
            throw MSSQLError(number: 0, message: tr("로그인 정보를 만들 수 없어요."))
        }
        defer { dbloginfree(login) }
        dbsetlname(login, e.username, DBSETUSER)
        dbsetlname(login, e.password ?? "", DBSETPWD)
        dbsetlname(login, "GodDB", DBSETAPP)
        dbsetlname(login, "UTF-8", DBSETCHARSET)
        dbsetlname(login, e.useTLS ? "require" : "off", DBSETENCRYPTION)
        if !e.database.isEmpty { dbsetlname(login, e.database, DBSETDBNAME) }
        dbsetlversion(login, BYTE(DBVERSION_74))
        // 포트는 서버 이름에 붙이지 않고 로그인 옵션으로 넘긴다.
        dbsetlshort(login, Int32(e.port), DBSETPORT)
        // C 헤더의 dbopen 은 tdsdbopen 을 부르는 매크로라 Swift 에서는 tdsdbopen 을 직접 부른다.
        // (라이브러리의 dbopen 심볼은 호환용이라 바로 NULL 을 돌려준다)
        if let p = tdsdbopen(login, server, 1) { return MSSQLDriver(p) }
        let errors = MessageBox.errors
        // 서버 메시지(로그인 실패 등)를 우선으로 보여준다.
        let main = errors.first { $0.number < 20000 } ?? errors.last
            ?? MSSQLError(number: 20009, message: tr("서버에 연결할 수 없어요."))
        guard checked, main.number >= 20000 else { throw main }
        // 미리 받은 인증서는 통과했는데 FreeTDS 연결이 실패 — TLS 확인 실패일 수 있다 (그 사이 인증서가 바뀌었거나)
        throw MSSQLError(number: main.number, message: main.message.replacingOccurrences(of: server, with: ip) + " — "
            + tr("FreeTDS 연결의 인증서 확인에서 실패했을 수 있어요. 다시 연결해 보고, 계속되면 관리자에게 서버 인증서를 확인하세요."))
    }

    var isOpen: Bool {
        queue.sync { proc.map { dbdead($0) == 0 } ?? false }
    }

    func close() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if let p = self.proc { dbclose(p) }
                self.proc = nil
                cont.resume()
            }
        }
    }

    func query(_ sql: String) async throws -> (columns: [String], rows: [[String?]]) {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.runSync(sql)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// 여러 결과 집합이 오면 컬럼이 있는 첫 번째 집합을 돌려준다. (나머지는 읽고 버림)
    private func runSync(_ sql: String) throws -> (columns: [String], rows: [[String?]]) {
        guard let p = proc, dbdead(p) == 0 else { throw DBError.notConnected }
        MessageBox.reset()
        func fail() -> MSSQLError {
            let errors = MessageBox.errors
            return errors.first { $0.number < 20000 } ?? errors.last ?? MSSQLError(number: 0, message: tr("알 수 없는 오류"))
        }
        guard dbcmd(p, sql) == SUCCEED, dbsqlexec(p) == SUCCEED else {
            dbcancel(p)
            throw fail()
        }
        var columns: [String] = []
        var rows: [[String?]] = []
        var captured = false
        while true {
            let rc = dbresults(p)
            if rc == NO_MORE_RESULTS { break }
            if rc == FAIL { dbcancel(p); throw fail() }
            let n = Int(dbnumcols(p))
            if n == 0 || captured {
                while dbnextrow(p) != NO_MORE_ROWS {}
                continue
            }
            columns = (1...n).map { String(cString: dbcolname(p, Int32($0))) }
            while true {
                let status = dbnextrow(p)
                if status == NO_MORE_ROWS { break }
                if status == FAIL { throw fail() }
                rows.append((1...n).map { value(p, Int32($0)) })
            }
            captured = true
        }
        // 실행 중 서버 오류(심각도 > 10)가 있었으면 실패로 본다.
        if let error = MessageBox.errors.first(where: { $0.number < 20000 }) { throw error }
        return (columns, rows)
    }

    private func value(_ p: OpaquePointer, _ col: Int32) -> String? {
        guard let data = dbdata(p, col) else { return nil }
        let len = Int(dbdatlen(p, col))
        let type = dbcoltype(p, col)
        switch type {
        case Int32(SYBBINARY), Int32(SYBVARBINARY), Int32(SYBIMAGE):
            // dbconvert 는 끝의 0 바이트를 잘라서, 원래 바이트로 직접 16진수를 만든다
            return BinaryText.hex(UnsafeBufferPointer(start: data, count: len))
        case Int32(SYBCHAR), Int32(SYBVARCHAR), Int32(SYBTEXT),
             Int32(SYBNTEXT), Int32(SYBNVARCHAR):
            return String(decoding: UnsafeBufferPointer(start: data, count: len), as: UTF8.self)
        case Int32(SYBDATETIME), Int32(SYBDATETIME4), Int32(SYBDATETIMN),
             Int32(SYBMSDATE), Int32(SYBMSTIME), Int32(SYBMSDATETIME2),
             Int32(SYBMSDATETIMEOFFSET), Int32(SYBDATE), Int32(SYBTIME):
            var rec = DBDATEREC2()
            if dbanydatecrack(p, &rec, type, data) == SUCCEED {
                return Self.format(rec, type: type)
            }
            fallthrough
        default:
            let size = max(64, len * 2 + 8)
            var buf = [UInt8](repeating: 0, count: size)
            let n = dbconvert(p, type, data, DBINT(len), Int32(SYBCHAR), &buf, DBINT(size))
            guard n >= 0 else { return nil }
            var s = String(decoding: buf.prefix(Int(n)), as: UTF8.self)
            if type == Int32(SYBBINARY) || type == Int32(SYBVARBINARY) || type == Int32(SYBIMAGE) {
                if !s.hasPrefix("0x") { s = "0x" + s.uppercased() }
            }
            return s.trimmingCharacters(in: .whitespaces)
        }
    }

    static func format(_ r: DBDATEREC2, type: Int32) -> String {
        let date = String(format: "%04d-%02d-%02d", r.year, r.month, r.day)
        var time = String(format: "%02d:%02d:%02d", r.hour, r.minute, r.second)
        if r.nanosecond > 0 {
            var frac = String(format: "%09d", r.nanosecond)
            while frac.hasSuffix("0") { frac.removeLast() }
            time += "." + frac
        }
        if type == Int32(SYBMSDATE) || type == Int32(SYBDATE) { return date }
        if type == Int32(SYBMSTIME) || type == Int32(SYBTIME) { return time }
        return "\(date) \(time)"
    }
}
