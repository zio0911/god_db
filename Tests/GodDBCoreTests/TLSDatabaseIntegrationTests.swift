import Foundation
import Testing
@testable import GodDBCore

/// 실제 MySQL · PostgreSQL · SQL Server 로 TLS 인증서 확인 · 고정 · TLS 필수를 본다. (./scripts/test-dbs.sh test)
/// 테스트 MySQL · SQL Server(Docker)는 자동 생성 자체 서명 인증서, 테스트 PostgreSQL 은 TLS 꺼짐.
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

    // MARK: - SQL Server (F9-3: 인증서를 미리 받아 판정 → FreeTDS 도 ca file 로 다시 확인)

    func mssql(pin: String? = nil, verify: Bool = true) -> (ConnectionProfile, String)? {
        guard let (base, pw) = MultiDB.profile(.mssql, database: "master") else { return nil }
        var p = base
        p.useTLS = true
        p.tlsVerify = verify
        p.tlsPinSHA256 = pin
        return (p, pw)
    }

    @Test(.enabled(if: env["GODDB_MSSQL_PORT"] != nil))
    func mssqlSelfSignedAsksThenPinConnects() async throws {
        let (base, pw) = try #require(mssql())
        // 1) 처음: 자체 서명 → 인증서 정보를 담은 오류 (로그인하지 않음)
        var info: TLSCertInfo?
        do {
            let s = try await DBSession.connect(profile: base, password: pw)
            await s.close()
            Issue.record("자체 서명 인증서인데 연결됨")
        } catch TLSCertificateError.untrusted(let i, let reasons) {
            info = i
            #expect(reasons.contains(.untrustedIssuer))
        }
        let pin = try #require(info?.sha256)
        #expect(pin.count == 95)

        // 2) 고정하면 묻지 않고 연결, 상태 "고정 인증서", 실제로 암호화된 연결
        let s = try await DBSession.connect(profile: try #require(mssql(pin: pin)).0, password: pw)
        #expect(await s.tlsStatus == .pinned)
        let r = try await s.execute("SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID", limit: 1)
        #expect(r.rows.first?.values.first == .some("TRUE"))
        await s.close()

        // 3) 지문이 다르면 거부
        do {
            let s = try await DBSession.connect(profile: try #require(mssql(pin: "00:11:22")).0, password: pw)
            await s.close()
            Issue.record("다른 지문인데 연결됨")
        } catch TLSCertificateError.pinMismatch {
        }

        // 4) 확인 끔 → 암호화만 하고 연결
        let u = try await DBSession.connect(profile: try #require(mssql(verify: false)).0, password: pw)
        #expect(await u.tlsStatus == .unchecked)
        await u.close()
    }

    /// FreeTDS(OpenSSL) 쪽 확인이 실제로 동작하는지: 맞는 CA 면 연결, 다른 CA · 다른 이름이면 거부
    @Test(.enabled(if: env["GODDB_MSSQL_PORT"] != nil))
    func mssqlFreeTDSChecksCAFileAndName() async throws {
        let (p, pw) = try #require(mssql())
        let verifier = TLSVerifier(policy: TLSPolicy(verify: true, hostname: nil, pin: nil))
        let probe = try await MSSQLTLS.probe(ip: "127.0.0.1", port: p.port, serverName: nil, verifier: verifier)
        #expect(probe.verdict == .unchecked)
        #expect(MSSQLTLS.anchorable(probe.chain))
        let endpoint = DriverEndpoint(host: "127.0.0.1", port: p.port, serverName: nil, username: p.username,
                                      password: pw, database: "master", useTLS: true)
        let chainPEM = probe.chain.map(MSSQLTLS.pem).joined()

        // 서버 인증서를 CA 로 → 연결
        let ok = try await MSSQLDriver.open(endpoint, ip: "127.0.0.1", check: MSSQLTLS.FreeTDSCheck(caPEM: chainPEM, hostname: nil))
        await ok.close()
        // 시스템 루트 묶음과 함께 넣어도 OpenSSL 이 읽고 연결 (신뢰된 인증서 경로와 같은 모양), 인증서의 이름으로 이름 확인 통과
        let leaf = try #require(probe.chain.first)
        let cn: String = try #require(TLSVerify.certInfo(der: leaf).subject
            .components(separatedBy: ", ").first { $0.hasPrefix("CN=") }.map { String($0.dropFirst(3)) })
        let named = try await MSSQLDriver.open(endpoint, ip: "127.0.0.1",
                                               check: MSSQLTLS.FreeTDSCheck(caPEM: MSSQLTLS.systemRootsPEM + chainPEM, hostname: cn))
        await named.close()

        // 시스템 루트만 → 자체 서명이라 거부
        await #expect(throws: MSSQLError.self) {
            let d = try await MSSQLDriver.open(endpoint, ip: "127.0.0.1",
                                               check: MSSQLTLS.FreeTDSCheck(caPEM: MSSQLTLS.systemRootsPEM, hostname: nil))
            await d.close()
        }
        // CA 는 맞지만 이름이 다름 → 거부
        await #expect(throws: MSSQLError.self) {
            let d = try await MSSQLDriver.open(endpoint, ip: "127.0.0.1",
                                               check: MSSQLTLS.FreeTDSCheck(caPEM: chainPEM, hostname: "wrong.example.com"))
            await d.close()
        }
    }
}
