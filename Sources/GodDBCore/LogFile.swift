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

    public init(directory: URL, keepDays: Int? = nil) {
        self.directory = directory
        self.keepDays = keepDays
    }

    /// 그 날짜의 로그 파일 경로
    public func url(for date: Date) -> URL {
        directory.appendingPathComponent("goddb-audit-\(Self.dayFormatter.string(from: date)).tsv")
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
        queue.async { [self] in write(text, date: entry.date) }
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

    private func write(_ text: String, date: Date) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !cleaned { cleaned = true; removeOld() }
        let url = url(for: date)
        guard var data = text.data(using: .utf8) else { return }
        // 새 파일이면 머리글 (엑셀 한글 깨짐 방지 BOM 포함)
        if !fm.fileExists(atPath: url.path) {
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

    private func removeOld() {
        guard let keepDays else { return }
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
