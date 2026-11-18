import Foundation
import Testing
@testable import GodDBCore

/// 연결은 받지만 아무 응답도 안 하는 서버 (네트워크가 잠깐 끊김, SSH 터널 너머가 안 붙음, TLS 설정 다름 등)
@Suite("Redis connect timeout", .serialized)
struct RedisTimeoutTests {
    /// nc 로 연결만 받고 응답하지 않는 포트를 연다
    func silentServer() throws -> (Process, Int) {
        let port = Int.random(in: 39_000..<39_900)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        p.arguments = ["-l", "127.0.0.1", "\(port)"]
        p.standardInput = Pipe()  // 입력이 열려 있어야 연결을 받은 뒤 닫지 않는다
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        Thread.sleep(forTimeInterval: 0.5)
        return (p, port)
    }

    @Test(arguments: ["secret", ""])
    func silentServerFailsWithinTimeout(_ password: String) async throws {
        let (nc, port) = try silentServer()
        defer { nc.terminate() }
        let profile = ConnectionProfile(kind: .redis, name: "silent", host: "127.0.0.1", port: port,
                                        username: "", database: "", useTLS: false)
        let started = Date()
        await #expect(throws: RedisTimeoutError.self) {
            _ = try await RedisSession.connect(profile: profile, password: password, timeout: .seconds(2))
        }
        #expect(Date().timeIntervalSince(started) < 6)
    }

    /// 연결 과정 중에 서버가 연결을 끊으면 "연결됨"으로 넘어가지 않고 실패한다
    @Test func serverClosingDuringHandshakeFails() async throws {
        let port = Int.random(in: 39_900..<39_990)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        p.arguments = ["-l", "127.0.0.1", "\(port)"]
        p.standardInput = FileHandle.nullDevice  // 입력이 바로 끝나서 연결을 받자마자 닫는다
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.5)
        let profile = ConnectionProfile(kind: .redis, name: "closing", host: "127.0.0.1", port: port,
                                        username: "", database: "", useTLS: false)
        await #expect(throws: (any Error).self) {
            _ = try await RedisSession.connect(profile: profile, password: "", timeout: .seconds(2))
        }
    }
}
