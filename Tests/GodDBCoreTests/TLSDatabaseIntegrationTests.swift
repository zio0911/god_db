import Foundation
import Testing
@testable import GodDBCore

/// 실제 MySQL · PostgreSQL 로 TLS 인증서 확인 · 고정 · TLS 필수를 본다. (./scripts/test-dbs.sh test)
/// 테스트 MySQL(Docker)은 자동 생성 자체 서명 인증서, 테스트 PostgreSQL 은 TLS 꺼짐.
@Suite("TLS DB integration", .serialized)
struct TLSDatabaseIntegrationTests {
    static let env = ProcessInfo.processInfo.environment

    func mysql(pin: String? = nil, verify: Bool = true) -> ConnectionProfile? {
        guard let port = Self.env["GODDB_IT_PORT"].flatMap(Int.init) else { return nil }
        var p = ConnectionProfile(name: "mysql-tls", host: "127.0.0.1", port: port, username: "root", database: "shop", useTLS: true)
        p.tlsVerify = verify
        p.tlsPinSHA256 = pin
        return p
    }
    var mysqlPassword: String { Self.env["GODDB_IT_PASSWORD"] ?? "" }

    @Test(.enabled(if: env["GODDB_IT_PORT"] != nil))
    func mysqlSelfSignedAsksThenPinConnects() async throws {
        // 1) 처음: 자체 서명 → 인증서 정보를 담은 오류 (연결 안 함)
        var info: TLSCertInfo?
        do {
            let s = try await DBSession.connect(profile: try #require(mysql()), password: mysqlPassword)
            await s.close()
            Issue.record("자체 서명 인증서인데 연결됨")
        } catch TLSCertificateError.untrusted(let i, let reasons) {
            info = i
            #expect(reasons.contains(.untrustedIssuer))
        }
        let pin = try #require(info?.sha256)

        // 2) 고정하면 묻지 않고 연결, 상태 "고정 인증서", 실제 쿼리 동작
        let s = try await DBSession.connect(profile: try #require(mysql(pin: pin)), password: mysqlPassword)
        #expect(await s.tlsStatus == .pinned)
        _ = try await s.execute("SELECT 1", limit: 1)
        await s.close()

        // 3) 지문이 다르면 거부
        do {
            let s = try await DBSession.connect(profile: try #require(mysql(pin: "00:11:22")), password: mysqlPassword)
            await s.close()
            Issue.record("다른 지문인데 연결됨")
        } catch TLSCertificateError.pinMismatch {
        }

        // 4) 확인 끔 → 암호화만 하고 연결
        let u = try await DBSession.connect(profile: try #require(mysql(verify: false)), password: mysqlPassword)
        #expect(await u.tlsStatus == .unchecked)
        await u.close()
    }

    @Test(.enabled(if: env["GODDB_PG_PORT"] != nil))
    func postgresTLSIsRequired() async throws {
        // 테스트 PostgreSQL 은 TLS 를 안 한다 → TLS 를 켜면 평문으로 붙지 않고 "TLS 를 지원하지 않아요"
        guard let (base, pw) = MultiDB.profile(.postgres, database: "shop") else { return }
        var p = base
        p.useTLS = true
        do {
            let s = try await DBSession.connect(profile: p, password: pw)
            await s.close()
            Issue.record("TLS 를 켰는데 평문으로 연결됨")
        } catch let e as TLSCertificateError {
            #expect(e == .serverNoTLS)
        }
        // TLS 끄면 정상
        p.useTLS = false
        let s = try await DBSession.connect(profile: p, password: pw)
        #expect(await s.tlsStatus == .off)
        await s.close()
    }
}
