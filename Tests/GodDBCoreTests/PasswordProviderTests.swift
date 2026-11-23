import Foundation
import Testing
@testable import GodDBCore

/// 키체인 비밀번호는 연결 뒤 세션이 들고 있지 않고, 새 연결이 필요할 때 다시 읽는다 (./scripts/test-dbs.sh test)
@Suite("Password provider", .serialized)
struct PasswordProviderTests {
    static let env = ProcessInfo.processInfo.environment

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func hit() { lock.lock(); n += 1; lock.unlock() }
    }

    func mysql() -> ConnectionProfile? {
        guard let port = Self.env["GODDB_IT_PORT"].flatMap(Int.init) else { return nil }
        return ConnectionProfile(name: "pw", host: "127.0.0.1", port: port, username: "root", database: "shop", useTLS: false)
    }
    var password: String { Self.env["GODDB_IT_PASSWORD"] ?? "" }

    @Test(.enabled(if: env["GODDB_IT_PORT"] != nil))
    func sideConnectionReadsPasswordFromProvider() async throws {
        let profile = try #require(mysql())
        let pw = password
        let calls = Counter()
        let s = try await DBSession.connect(profile: profile, password: pw, passwordProvider: { calls.hit(); return pw })
        defer { Task { await s.close() } }
        #expect(calls.value == 0)                       // 처음 연결은 받은 값으로
        let side = try #require(await s.sideConnection())
        _ = try await side.query("SELECT 1", timeout: 5)
        #expect(calls.value == 1)                       // 별도 연결은 다시 읽어서
        await side.close()
    }

    @Test(.enabled(if: env["GODDB_IT_PORT"] != nil))
    func sessionDoesNotKeepPasswordWhenProviderGiven() async throws {
        // 다시 읽어 온 값이 틀리면 별도 연결이 실패한다 = 세션이 처음 비밀번호를 들고 있지 않다
        let profile = try #require(mysql())
        let s = try await DBSession.connect(profile: profile, password: password, passwordProvider: { "wrong-password" })
        defer { Task { await s.close() } }
        let side = try #require(await s.sideConnection())
        await #expect(throws: (any Error).self) { _ = try await side.query("SELECT 1", timeout: 5) }
        await side.close()
    }

    @Test(.enabled(if: env["GODDB_IT_PORT"] != nil))
    func withoutProviderSessionKeepsPassword() async throws {
        // 이번 실행 중에만 기억하는 비밀번호(제공자 없음)는 세션이 들고 있어 별도 연결도 된다
        let profile = try #require(mysql())
        let s = try await DBSession.connect(profile: profile, password: password)
        defer { Task { await s.close() } }
        let side = try #require(await s.sideConnection())
        _ = try await side.query("SELECT 1", timeout: 5)
        await side.close()
    }
}
