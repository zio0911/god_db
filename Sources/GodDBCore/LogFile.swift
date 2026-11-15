import Foundation

/// 감사 로그를 날짜별 파일로 남긴다. (나중에 누가 언제 어느 DB 에 무엇을 했는지 분석하는 용도)
///   ~/Library/Logs/GodDB/goddb-audit-2026-11-13.tsv
/// 한 줄 = 한 행위, 탭으로 나눈 열: 시각 · 사용자@PC · 구분 · 대상 · 결과 · 내용 (엑셀로 바로 열 수 있다)
/// 감사 대상(AuditRecord)이 있는 항목만 쓴다. 화면 이동·AI 내용 같은 건 상태창에만 남는다.
/// 파일 쓰기는 별도 큐에서 하므로 화면을 막지 않는다. 사내 감사 요구로 기본은 영구 보관 (지우지 않음).
public final class LogFile: @unchecked Sendable {
    public static let shared = LogFile(directory: defaultDirectory)

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GodDB", isDirectory: true)
    }

    public let directory: URL
    /// 보관 일수. nil 이면 영구 보관 (기본)
    public let keepDays: Int?
    private let queue = DispatchQueue(label: "goddb.logfile")
    private var cleaned = false
    /// 파일별 마지막 해시 (체인 이어 쓰기용)
    private var lastHash: [String: String] = [:]
    /// 기기 서명 키 (기본: Secure Enclave/키체인). 테스트는 고정 키를 넘긴다.
    private let signer: @Sendable () -> AuditChain.Signer?

    /// 보관 기간 설정을 읽는 곳 (기본: 사용자 설정). 테스트는 고정 값을 넘긴다.
    private let retention: @Sendable () -> Int

    public init(directory: URL, keepDays: Int? = nil, retention: @escaping @Sendable () -> Int = { LogFile.retentionDays },
                signer: @escaping @Sendable () -> AuditChain.Signer? = { AuditChain.deviceSigner() }) {
        self.directory = directory
        self.keepDays = keepDays
        self.retention = retention
        self.signer = signer
    }

    /// 그 날짜의 로그 파일 경로
    public func url(for date: Date) -> URL {
        directory.appendingPathComponent("goddb-audit-\(Self.dayFormatter.string(from: date)).tsv")
    }

    /// 설정 > 일반 > 로그 > 보관 기간 (일). 0 이면 영구 보관 (기본). 최소 90일.
    public static let retentionChoices = [0, 90, 180, 365]
    public static var retentionDays: Int {
        get { UserDefaults.standard.object(forKey: "GodDB.logFile.keepDays") as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue == 0 ? 0 : max(90, newValue), forKey: "GodDB.logFile.keepDays") }
    }

    /// 보관 기간이 바뀌었을 때 바로 정리
    public func cleanNow() {
        queue.async { [self] in removeOld() }
    }

    /// 설정 > 일반 > 로그 파일 남기기 (기본 켜짐)
    public static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "GodDB.logFile.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "GodDB.logFile.enabled") }
    }

    /// 개발용 화면 그리기 실행에서는 로그 파일을 쓰지 않는다
    public static let suspended = CommandLine.arguments.contains { $0.hasPrefix("--render-") }

    public func append(_ entry: LogEntry) {
        guard Self.enabled, !Self.suspended, entry.audit != nil else { return }
        let text = Self.format(entry)
        let identity = ClientInfo.identity
        queue.async { [self] in write(text, date: entry.date, identity: identity) }
    }

    /// 쌓인 쓰기를 모두 끝낼 때까지 기다린다. (테스트·종료용)
    public func flush() {
        queue.sync {}
    }

    /// 한 항목을 파일 한 줄로 (탭 구분). 실패한 행위는 결과 칸이 "실패: …".
    public static func format(_ e: LogEntry, identity: String = ClientInfo.identity) -> String {
        guard let a = e.audit else { return "" }
        let cols = [timeFormatter.string(from: e.date), identity, a.action.rawValue, a.target, a.result, a.statement]
        return cols.map { AuditRecord.cell($0) }.joined(separator: "\t") + "\n"
    }

    private func write(_ text: String, date: Date, identity: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !cleaned { cleaned = true; removeOld() }
        let url = url(for: date)
        let name = url.lastPathComponent
        guard let signer = signer() else {
            // 기기 키를 못 쓰면 무결성 칸 없이 쓴다 (검사에서 예전 형식으로 보인다)
            append(Data(text.utf8), to: url, header: true)
            return
        }
        var out = ""
        if !fm.fileExists(atPath: url.path) {
            // 새 날짜 파일: 머리글 + 공개 키·이전 파일 연결 "체인" 줄. 이전 파일 마지막 값은 시스템 로그에도 봉인
            let (prevName, prevHash) = previousFileTail(before: name)
            if let prevName { AuditChain.sealToSystemLog(file: prevName, lastHash: prevHash) }
            out += "\u{FEFF}" + (AuditRecord.header + AuditChain.columns).joined(separator: "\t") + "\n"
            let link = AuditChain.linkLine(time: Self.timeFormatter.string(from: date), identity: identity,
                                           previousFile: prevName, previousHash: prevHash, signer: signer)
            let sealed = AuditChain.seal(prev: AuditChain.seed(fileName: name), line: link, signer: signer)
            out += link + "\t" + sealed.suffix + "\n"
            lastHash[name] = sealed.hash
        } else if lastHash[name] == nil {
            lastHash[name] = Self.lastHash(in: url) ?? AuditChain.seed(fileName: name)
        }
        var prev = lastHash[name]!
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let sealed = AuditChain.seal(prev: prev, line: String(line), signer: signer)
            out += line + "\t" + sealed.suffix + "\n"
            prev = sealed.hash
        }
        lastHash[name] = prev
        append(Data(out.utf8), to: url, header: false)
    }

    private func append(_ data: Data, to url: URL, header: Bool) {
        let fm = FileManager.default
        var data = data
        if header && !fm.fileExists(atPath: url.path) {
            data = Data(("\u{FEFF}" + AuditRecord.header.joined(separator: "\t") + "\n").utf8) + data
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
            // 다른 사용자가 못 읽게
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// 파일 마지막 줄의 무결성 값 (끝에서 두 번째 칸)
    static func lastHash(in url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let last = text.split(separator: "\n").last.map(String.init) ?? ""
        let cols = last.components(separatedBy: "\t")
        guard cols.count >= 2 else { return nil }
        let h = cols[cols.count - 2]
        return h.count == 64 && h.allSatisfy(\.isHexDigit) ? h : nil
    }

    /// 이 파일보다 앞 날짜의 가장 최근 감사 로그와 그 마지막 해시
    private func previousFileTail(before name: String) -> (String?, String) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("goddb-audit-") && $0.pathExtension == "tsv" && $0.lastPathComponent < name }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let prev = files.last else { return (nil, AuditChain.zero) }
        return (prev.lastPathComponent, Self.lastHash(in: prev) ?? AuditChain.zero)
    }

    private func removeOld() {
        // 생성할 때 정한 값(테스트) 이 없으면 설정 값. 0 이면 영구 보관
        let setting = retention()
        guard let keepDays = keepDays ?? (setting > 0 ? setting : nil) else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) ?? .distantPast
        for f in files where f.lastPathComponent.hasPrefix("goddb-") && ["log", "tsv"].contains(f.pathExtension) {
            let name = f.deletingPathExtension().lastPathComponent
            let day = name.hasPrefix("goddb-audit-") ? name.dropFirst("goddb-audit-".count) : name.dropFirst("goddb-".count)
            if let d = Self.dayFormatter.date(from: String(day)), d < cutoff {
                try? fm.removeItem(at: f)
            }
        }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
