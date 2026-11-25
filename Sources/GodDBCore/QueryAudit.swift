import Foundation

/// DB 로 나가는 모든 문장을 감사 로그에 남긴다 (#205).
/// SQL 은 `AuditingDriver`, Redis 는 `RedisConnection.raw` 에서 — 드라이버 바로 위 한 곳이라 빠지는 경로가 없다.
///
/// 이미 자세히 기록하는 곳(직접 실행 · 결과 편집 · 커밋 등)은 `callerAudits` 로 감싸고,
/// 세션은 그 작업의 주 문장에만 `skip` 을 켠다. 그 안에서 앱이 덧붙여 보내는 문장(BEGIN · SET 등)은 그대로 남는다.
public enum QueryAudit {
    /// 호출한 쪽이 이 작업의 주 문장을 직접 감사 기록한다
    @TaskLocal public static var callerAudits = false
    /// 지금 보내는 문장은 호출한 쪽이 기록한다 (세션이 주 문장에만 켠다)
    @TaskLocal static var skip = false
    /// 계속 묻는 명령(스트림 실시간 XREAD BLOCK): 받은 게 있을 때만 기록
    @TaskLocal public static var quietWhenEmpty = false
    /// 결과 칸 앞에 붙는 출처 (예: "메타데이터", "세션 설정", "다음 페이지")
    @TaskLocal public static var origin: String?

    /// 호출한 쪽이 기록하는 작업
    public static func audited<T>(_ body: () async throws -> T) async rethrows -> T {
        try await $callerAudits.withValue(true) { try await body() }
    }

    /// 출처를 붙여 실행
    public static func labeled<T>(_ origin: String, _ body: () async throws -> T) async rethrows -> T {
        try await $origin.withValue(origin) { try await body() }
    }

    /// 주 문장: 호출한 쪽이 기록하면 건너뛴다
    static func primary<T>(_ isPrimary: Bool, _ body: () async throws -> T) async rethrows -> T {
        try await $skip.withValue(isPrimary && callerAudits) { try await body() }
    }

    /// 기록할 곳: 기본은 감사 로그 파일. 테스트는 `$capture.withValue` 로 이 작업의 기록만 받아 본다.
    @TaskLocal public static var capture: (@Sendable (AuditRecord) -> Void)?
    static func sink(_ record: AuditRecord) {
        if let capture { capture(record); return }
        LogFile.shared.append(LogEntry(level: .info, source: .query, message: "", audit: record))
    }

    /// 한 문장 기록
    static func record(statement: String, action: AuditRecord.Action, target: String,
                       started: Date, rows: Int?, error: (any Error)?) {
        guard !skip else { return }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        var parts: [String] = []
        if let origin { parts.append(origin) }
        if let error {
            parts.append(String(ErrorText.describe(error).message.prefix(300)))
            sink(AuditRecord(action, target: target, result: "실패: " + parts.joined(separator: " · "), statement: statement))
        } else {
            if let rows { parts.append("\(rows)행") }
            parts.append("\(ms)ms")
            sink(AuditRecord(action, target: target, result: parts.joined(separator: " · "), statement: statement))
        }
    }

    /// Redis 명령을 기록용 글로: 비밀번호가 들어가는 자리는 가린다
    public static func redisStatement(_ args: [String]) -> String {
        var a = args
        let upper = a.map { $0.uppercased() }
        func mask(_ i: Int) { if a.indices.contains(i) { a[i] = "******" } }
        switch upper.first {
        case "AUTH":
            mask(a.count - 1)                       // AUTH pw · AUTH user pw
        case "HELLO":
            if let i = upper.firstIndex(of: "AUTH") { mask(i + 2) }   // HELLO 3 AUTH user pw
        case "MIGRATE":
            if let i = upper.firstIndex(of: "AUTH") { mask(i + 1) }
            if let i = upper.firstIndex(of: "AUTH2") { mask(i + 2) }
        case "CONFIG":
            if upper.count >= 4, upper[1] == "SET" {
                var i = 2
                while i + 1 < a.count {
                    if ["REQUIREPASS", "MASTERAUTH", "MASTERUSER"].contains(upper[i]) { mask(i + 1) }
                    i += 2
                }
            }
        case "ACL":
            if upper.count >= 2, upper[1] == "SETUSER" {
                for i in a.indices.dropFirst(3) where a[i].hasPrefix(">") || a[i].hasPrefix("#") || a[i].hasPrefix("<") {
                    a[i] = String(a[i].prefix(1)) + "******"
                }
            }
        default: break
        }
        return a.map { v in
            v.isEmpty || v.contains(where: { $0.isWhitespace || $0 == "\"" }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : v
        }.joined(separator: " ")
    }
}

/// 드라이버를 감싸 보내는 문장마다 감사 기록을 남긴다 (#205)
final class AuditingDriver: DBDriver, @unchecked Sendable {
    let inner: any DBDriver
    private let lock = NSLock()
    private let name: String
    private var database: String

    init(_ inner: any DBDriver, name: String, database: String) {
        self.inner = inner
        self.name = name
        self.database = database
    }

    /// 대상 칸: "접속/DB"
    var target: String {
        lock.lock(); defer { lock.unlock() }
        return database.isEmpty ? name : "\(name)/\(database)"
    }

    /// 지금 DB 가 바뀌었을 때 (USE 등)
    func setDatabase(_ db: String) {
        lock.lock(); database = db; lock.unlock()
    }

    func query(_ sql: String) async throws -> (columns: [String], rows: [[String?]]) {
        let started = Date()
        let target = target
        do {
            let r = try await inner.query(sql)
            QueryAudit.record(statement: sql, action: AuditRecord.classify(sql: sql), target: target,
                              started: started, rows: r.columns.isEmpty ? nil : r.rows.count, error: nil)
            return r
        } catch {
            QueryAudit.record(statement: sql, action: AuditRecord.classify(sql: sql), target: target,
                              started: started, rows: nil, error: error)
            throw error
        }
    }

    func close() async { await inner.close() }
    var isOpen: Bool { inner.isOpen }
    var tlsStatus: TLSStatus { inner.tlsStatus }
}
