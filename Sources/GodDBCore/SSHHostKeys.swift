import Foundation

// F9-4. SSH 호스트 키 확인
// 연결 전에 known_hosts(~/.ssh/known_hosts + GodDB 전용)에서 찾고, 없으면 ssh-keyscan 으로 키를 받아 지문을 보여 준 뒤
// 사용자가 신뢰하면 GodDB 전용 known_hosts 에 더한다. ssh 는 StrictHostKeyChecking=yes 로 실행한다.

/// 서버 키 하나의 지문
public struct SSHHostKeyFingerprint: Sendable, Hashable {
    /// "ED25519", "ECDSA", "RSA"
    public var type: String
    /// "SHA256:9cP3…"
    public var fingerprint: String
    public var bits: Int?

    public init(type: String, fingerprint: String, bits: Int? = nil) {
        self.type = type
        self.fingerprint = fingerprint
        self.bits = bits
    }
}

/// 처음 접속하는 서버의 키 (확인 창에 보여 주고, 신뢰하면 lines 를 저장)
public struct SSHHostScan: Sendable, Hashable, Identifiable {
    public var id: String { "\(host):\(port)" }
    /// 화면에 보이는 주소
    public var host: String
    public var port: Int
    /// known_hosts 에서 찾는 이름 ("host" 또는 "[host]:port")
    public var pattern: String
    /// known_hosts 에 더할 줄 ("pattern keytype base64")
    public var lines: [String]
    public var keys: [SSHHostKeyFingerprint]

    public init(host: String, port: Int, pattern: String, lines: [String], keys: [SSHHostKeyFingerprint]) {
        self.host = host
        self.port = port
        self.pattern = pattern
        self.lines = lines
        self.keys = keys
    }
}

public enum SSHHostKeyError: LocalizedError, Sendable, Equatable {
    /// 모르는 서버 — 확인 창
    case unknown(SSHHostScan)
    /// 서버 키가 바뀜 — 연결 거부, [저장된 키 지우기]
    case changed(host: String, port: Int, pattern: String)
    /// 키를 받지 못함
    case scanFailed(host: String, port: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .unknown(let scan):
            return ([tr("처음 접속하는 SSH 서버예요 — %@", "\(scan.host):\(scan.port)")]
                    + scan.keys.map { "\($0.type)  \($0.fingerprint)" }).joined(separator: "\n")
        case .changed:
            return tr("SSH 서버 키가 바뀌었어요. 서버를 다시 설치한 게 아니라면 중간에서 가로채는 공격일 수 있어요. 관리자에게 확인한 뒤 [저장된 키 지우기] (GodDB 전용 파일에서만 지움).")
        case .scanFailed(let host, let port, let message):
            return tr("SSH 서버 키를 받지 못했어요 — %@", "\(host):\(port)") + (message.isEmpty ? "" : "\n" + message)
        }
    }
}

public enum SSHHostKeys {
    /// GodDB 전용 known_hosts (~/Library/Application Support/GodDB/known_hosts, 권한 0600)
    public static var godDBFile: URL { AppPaths.dataDirectory.appendingPathComponent("known_hosts") }

    /// 사용자 known_hosts
    public static var userFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
    }

    // MARK: - 이름 · 옵션

    /// known_hosts 에서 찾는 이름: 22 번이면 host, 아니면 "[host]:port"
    public static func pattern(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// ssh 옵션 값 안에서 쓰는 큰따옴표 경로 (공백이 있는 "Application Support")
    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `-o` 에 넘길 옵션들
    public static func sshOptions(godDBFile: URL = godDBFile) -> [String] {
        [
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=" + quoted("~/.ssh/known_hosts") + " " + quoted(godDBFile.path),
        ]
    }

    // MARK: - 출력 해석

    /// ssh-keyscan 출력에서 키 줄만 (주석 · 빈 줄 빼고). 이름 칸은 pattern 으로 바꾼다.
    public static func keyLines(fromScan output: String, pattern: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, isKeyType(String(parts[1])) else { return nil }
            return "\(pattern) \(parts[1]) \(parts[2])"
        }
    }

    static func isKeyType(_ s: String) -> Bool {
        s.hasPrefix("ssh-") || s.hasPrefix("ecdsa-") || s.hasPrefix("sk-")
    }

    /// `ssh-keygen -lf -` 출력: "256 SHA256:abc… [host]:2222 (ED25519)"
    public static func parseFingerprints(_ output: String) -> [SSHHostKeyFingerprint] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, let fp = parts.first(where: { $0.hasPrefix("SHA256:") }) else { return nil }
            var type = "?"
            if let last = parts.last, last.hasPrefix("("), last.hasSuffix(")") {
                type = String(last.dropFirst().dropLast())
            }
            return SSHHostKeyFingerprint(type: type, fingerprint: fp, bits: Int(parts[0]))
        }
    }

    /// ssh 오류 출력으로 키 문제를 가린다
    public enum StderrKind: Equatable, Sendable { case changed, unknown }

    public static func classify(stderr: String) -> StderrKind? {
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .changed }
        if stderr.range(of: "host key is known for", options: .caseInsensitive) != nil
            || stderr.contains("No matching host key") { return .unknown }
        if stderr.contains("Host key verification failed") { return .changed }
        return nil
    }

    // MARK: - ssh -G (~/.ssh/config 의 HostName · Port · HostKeyAlias 반영)

    public struct Resolved: Sendable, Equatable {
        public var hostname: String
        public var port: Int
        public var hostKeyAlias: String?

        /// known_hosts 에서 찾을 이름 (HostKeyAlias 가 있으면 그것 그대로 — ssh 와 같은 규칙)
        public var pattern: String {
            hostKeyAlias ?? SSHHostKeys.pattern(host: hostname, port: port)
        }
    }

    /// `ssh -G` 출력 해석
    public static func parseConfig(_ output: String, fallbackHost: String, fallbackPort: Int) -> Resolved {
        var r = Resolved(hostname: fallbackHost, port: fallbackPort, hostKeyAlias: nil)
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "hostname": r.hostname = parts[1]
            case "port": r.port = Int(parts[1]) ?? r.port
            case "hostkeyalias": r.hostKeyAlias = parts[1] == "none" ? nil : parts[1]
            default: break
            }
        }
        return r
    }

    public static func resolve(_ config: SSHConfig) -> Resolved {
        var args = ["-G", "-p", String(config.port)]
        if !config.username.isEmpty { args += ["-l", config.username] }
        args.append(config.host)
        let out = run("/usr/bin/ssh", args, timeout: 5)
        return parseConfig(out.status == 0 ? out.stdout : "", fallbackHost: config.host, fallbackPort: config.port)
    }

    // MARK: - 찾기 · 받기 · 저장 · 지우기

    /// known_hosts 파일들에서 이름을 찾는다 (해시된 줄도 ssh-keygen 이 찾는다)
    public static func isKnown(pattern: String, files: [URL]) -> Bool {
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            let r = run("/usr/bin/ssh-keygen", ["-F", pattern, "-f", file.path], timeout: 5)
            if r.status == 0, !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        return false
    }

    /// 서버 키를 받아 지문을 계산한다
    public static func scan(host: String, port: Int, pattern: String, displayHost: String, displayPort: Int,
                            timeout: Int = 5) throws -> SSHHostScan {
        let r = run("/usr/bin/ssh-keyscan", ["-T", String(timeout), "-p", String(port), host], timeout: TimeInterval(timeout + 5))
        let lines = keyLines(fromScan: r.stdout, pattern: pattern)
        guard !lines.isEmpty else {
            let msg = r.stderr.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.joined(separator: "\n")
            throw SSHHostKeyError.scanFailed(host: displayHost, port: displayPort, message: msg)
        }
        let fp = run("/usr/bin/ssh-keygen", ["-l", "-f", "-"], stdin: lines.joined(separator: "\n") + "\n", timeout: 5)
        return SSHHostScan(host: displayHost, port: displayPort, pattern: pattern, lines: lines,
                           keys: parseFingerprints(fp.stdout))
    }

    /// 연결 전 확인: 알려진 서버면 그냥 지나가고, 모르면 키를 받아 `.unknown` 을 던진다.
    public static func check(_ config: SSHConfig, godDBFile: URL = godDBFile, userFile: URL = userFile) throws {
        let resolved = resolve(config)
        if isKnown(pattern: resolved.pattern, files: [userFile, godDBFile]) { return }
        let scan = try scan(host: resolved.hostname, port: resolved.port, pattern: resolved.pattern,
                            displayHost: config.host, displayPort: config.port)
        throw SSHHostKeyError.unknown(scan)
    }

    /// 신뢰한 키를 GodDB 전용 known_hosts 에 더한다 (파일 권한 0600)
    public static func trust(_ scan: SSHHostScan, file: URL = godDBFile) throws {
        try append(scan.lines, to: file)
    }

    public static func append(_ lines: [String], to file: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var text = lines.joined(separator: "\n") + "\n"
        if end > 0 {
            // 마지막 줄이 줄바꿈으로 끝나지 않았으면 붙여 쓰지 않게
            try handle.seek(toOffset: end - 1)
            if let last = try handle.read(upToCount: 1), last != Data("\n".utf8) { text = "\n" + text }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// GodDB 전용 파일에서만 이 서버의 키를 지운다 (`ssh-keygen -R`)
    @discardableResult
    public static func remove(pattern: String, file: URL = godDBFile) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let r = run("/usr/bin/ssh-keygen", ["-R", pattern, "-f", file.path], timeout: 5)
        // ssh-keygen 이 남기는 백업(.old)은 지운다 (지운 키가 남지 않게)
        try? FileManager.default.removeItem(atPath: file.path + ".old")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return r.status == 0
    }

    // MARK: - 프로세스

    struct RunResult { var status: Int32; var stdout: String; var stderr: String }

    static func run(_ path: String, _ args: [String], stdin: String? = nil, timeout: TimeInterval) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let input = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        do { try p.run() } catch { return RunResult(status: -1, stdout: "", stderr: error.localizedDescription) }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        // 출력을 끝까지 읽으며 기다린다 (파이프가 차서 멈추지 않게). 제한 시간이 지나면 끝낸다.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var o = Data(), e = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        e = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        killer.cancel()
        return RunResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self),
                         stderr: String(decoding: e, as: UTF8.self))
    }
}
