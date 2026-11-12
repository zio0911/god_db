import Foundation

public enum SSHTunnelError: LocalizedError {
    case noFreePort
    case exited(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .noFreePort: return "로컬 포트를 확보하지 못했어요."
        case .exited(let msg): return "SSH 터널 연결에 실패했어요.\n\(msg)"
        case .timeout: return "SSH 터널이 15초 안에 열리지 않았어요."
        }
    }
}

/// 시스템 `/usr/bin/ssh -N -L` 로 바스티온 포트포워딩을 연다.
/// ssh-agent, ~/.ssh/config, known_hosts 를 그대로 활용하기 위해 직접 구현하지 않고 ssh 프로세스를 띄운다.
public final class SSHTunnel: @unchecked Sendable {
    public let localPort: Int
    private let process: Process
    private let stderrPipe = Pipe()

    public init(config: SSHConfig, remoteHost: String, remotePort: Int) throws {
        guard let port = SSHTunnel.findFreePort() else { throw SSHTunnelError.noFreePort }
        localPort = port
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHTunnel.arguments(
            config: config, localPort: port, remoteHost: remoteHost, remotePort: remotePort)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
    }

    public static func arguments(config: SSHConfig, localPort: Int, remoteHost: String, remotePort: Int) -> [String] {
        var args = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=10",
            "-p", String(config.port),
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
        ]
        let key = (config.keyPath as NSString).expandingTildeInPath
        if !key.isEmpty {
            args += ["-i", key, "-o", "IdentitiesOnly=yes"]
        }
        args.append(config.username.isEmpty ? config.host : "\(config.username)@\(config.host)")
        return args
    }

    /// ssh 를 실행하고 로컬 포트가 열릴 때까지 기다린다.
    public func start() async throws {
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !process.isRunning {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw SSHTunnelError.exited(msg.isEmpty ? "ssh 종료 코드 \(process.terminationStatus)" : msg)
            }
            if SSHTunnel.canConnect(port: localPort) { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        stop()
        throw SSHTunnelError.timeout
    }

    public func stop() {
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }

    // MARK: - 소켓 유틸

    static func findFreePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
