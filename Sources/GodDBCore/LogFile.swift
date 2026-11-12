import Foundation

/// 상태창 로그를 날짜별 파일로 남긴다. (나중에 무엇을 했는지 확인하는 용도)
///   ~/Library/Logs/GodDB/goddb-2026-11-12.log
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
        directory.appendingPathComponent("goddb-\(Self.dayFormatter.string(from: date)).log")
    }

    /// 설정 > 일반 > 로그 파일 남기기 (기본 켜짐)
    public static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "GodDB.logFile.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "GodDB.logFile.enabled") }
    }

    /// 개발용 화면 그리기 실행에서는 로그 파일을 쓰지 않는다
    public static let suspended = CommandLine.arguments.contains { $0.hasPrefix("--render-") }

    public func append(_ entry: LogEntry) {
        guard Self.enabled, !Self.suspended else { return }
        let text = Self.format(entry)
        queue.async { [self] in write(text, date: entry.date) }
    }

    /// 쌓인 쓰기를 모두 끝낼 때까지 기다린다. (테스트·종료용)
    public func flush() {
        queue.sync {}
    }

    /// 한 항목을 파일용 텍스트로. 첫 줄은 시간·수준·종류·메시지, 나머지(SQL, 오류 원문)는 들여쓴다.
    public static func format(_ e: LogEntry) -> String {
        var line = "\(timeFormatter.string(from: e.date)) \(e.level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)) [\(e.source.title)] \(e.message)"
        var extra: [String] = []
        if let hint = e.hint { extra.append(tr("해결 방법: %@", hint)) }
        if let detail = e.detail, !detail.isEmpty { extra.append(detail) }
        for block in extra {
            for l in block.components(separatedBy: "\n") { line += "\n    " + l }
        }
        return line + "\n"
    }

    private func write(_ text: String, date: Date) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !cleaned { cleaned = true; removeOld() }
        let url = url(for: date)
        guard let data = text.data(using: .utf8) else { return }
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
        for f in files where f.lastPathComponent.hasPrefix("goddb-") && f.pathExtension == "log" {
            let day = f.deletingPathExtension().lastPathComponent.dropFirst("goddb-".count)
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
