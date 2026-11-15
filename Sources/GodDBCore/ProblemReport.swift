import Foundation

/// 앱 안 "문제 보고": 버전·환경·최근 오류·크래시 요약을 모아 GitHub 이슈 작성 화면을 미리 채운다 (서버 없음).
/// 회사 정보가 새지 않도록 호스트·IP·이메일·계정·홈 경로를 가린다. 사용자가 보내기 전에 고칠 수 있다.
public enum ProblemReport {
    public static let repo = "zio0911/god_db"

    public struct Crash: Sendable, Equatable {
        public var date: String
        public var appVersion: String
        public var exception: String
        public var frames: [String]
    }

    // MARK: 가리기

    /// 공개 이슈에 올라가면 안 되는 값을 가린다
    public static func redact(_ text: String, identity: String = ClientInfo.identity, home: String = NSHomeDirectory()) -> String {
        var s = text
        if !home.isEmpty { s = s.replacingOccurrences(of: home, with: "~") }
        if !identity.isEmpty { s = s.replacingOccurrences(of: identity, with: "<user>") }
        let user = NSUserName()
        let rules: [(String, String)] = [
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>"),
            ("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", "<ip>"),
            // 점이 두 개 이상인 호스트 이름 (db.example.co.kr, xxx.rds.amazonaws.com)
            ("\\b(?:[A-Za-z0-9-]+\\.){2,}[A-Za-z]{2,}\\b", "<host>"),
        ]
        for (pattern, repl) in rules {
            s = s.replacingOccurrences(of: pattern, with: repl, options: .regularExpression)
        }
        if user.count >= 3 {
            s = s.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: user))\\b", with: "<user>",
                                       options: .regularExpression)
        }
        return s
    }

    // MARK: 크래시 보고서

    public static var crashDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// GodDB 크래시 보고서(.ips) 최근 것부터
    public static func recentCrashes(limit: Int = 3, in dir: URL = crashDirectory) -> [Crash] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let mine = files.filter { $0.lastPathComponent.hasPrefix("GodDB") && $0.pathExtension == "ips" }
            .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        return mine.prefix(limit).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.compactMap(parseCrash)
    }

    /// .ips: 첫 줄은 머리 JSON, 나머지는 본문 JSON
    public static func parseCrash(_ text: String) -> Crash? {
        guard let nl = text.firstIndex(of: "\n") else { return nil }
        guard let head = try? JSONSerialization.jsonObject(with: Data(text[..<nl].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: nl)...].utf8)) as? [String: Any]
        else { return nil }
        let exc = body["exception"] as? [String: Any]
        let exception = [exc?["type"] as? String, exc?["signal"] as? String].compactMap { $0 }.joined(separator: " ")
        var frames: [String] = []
        if let threads = body["threads"] as? [[String: Any]] {
            let idx = body["faultingThread"] as? Int ?? 0
            let images = (body["usedImages"] as? [[String: Any]])?.map { $0["name"] as? String ?? "?" } ?? []
            if threads.indices.contains(idx), let fs = threads[idx]["frames"] as? [[String: Any]] {
                frames = fs.prefix(12).map { f in
                    let image = (f["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
                    return "\(image)  \(f["symbol"] as? String ?? "?")"
                }
            }
        }
        return Crash(date: head["timestamp"] as? String ?? "", appVersion: head["app_version"] as? String ?? "",
                     exception: exception, frames: frames)
    }

    // MARK: 본문

    public static func environment(appVersion: String) -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "GodDB \(appVersion) · macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) · \(machine)"
    }

    public static func logText(errors: [String], crashes: [Crash]) -> String {
        var out: [String] = []
        if !errors.isEmpty {
            out.append("# 최근 오류")
            out += errors
        }
        for c in crashes {
            out.append("")
            out.append("# 크래시 \(c.date) · \(c.appVersion) · \(c.exception)")
            out += c.frames
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 버그 신고 템플릿(.github/ISSUE_TEMPLATE/bug.yml)의 칸 id 로 미리 채운 이슈 작성 주소.
    /// 주소 길이 제한 때문에 로그는 앞부분만 넣는다.
    public static func issueURL(title: String, version: String, db: String?, steps: String, expected: String, log: String,
                                maxLength: Int = 7_500) -> URL? {
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")!
        func items(_ log: String) -> [URLQueryItem] {
            var q = [URLQueryItem(name: "template", value: "bug.yml"),
                     URLQueryItem(name: "title", value: title),
                     URLQueryItem(name: "labels", value: "type:bug"),
                     URLQueryItem(name: "version", value: version),
                     URLQueryItem(name: "steps", value: steps),
                     URLQueryItem(name: "expected", value: expected),
                     URLQueryItem(name: "log", value: log)]
            if let db { q.append(URLQueryItem(name: "db", value: db)) }
            return q
        }
        var body = log
        c.queryItems = items(body)
        while (c.url?.absoluteString.count ?? 0) > maxLength && !body.isEmpty {
            body = String(body.prefix(body.count * 3 / 4)) + "\n…(잘림)"
            if body.count < 40 { body = ""; }
            c.queryItems = items(body)
        }
        return c.url
    }
}

private extension URL {
    var modificationDate: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}
