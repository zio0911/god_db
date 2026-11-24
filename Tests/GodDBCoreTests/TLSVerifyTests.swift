import Foundation
import Testing
@testable import GodDBCore

@Suite("TLSVerify", .timeLimit(.minutes(1)))
struct TLSVerifyTests {
    /// 테스트용 자체 서명 인증서 (CN=goddb-test.local, SAN DNS:goddb-test.local, 2026-11-20 ~ 2036-11-17). 개인키는 버렸다.
    static let selfSignedPEM = """
    -----BEGIN CERTIFICATE-----
    MIIBsTCCAVegAwIBAgIUQ/qf3P/PaO/yeeJWQWwvR4lvi1UwCgYIKoZIzj0EAwIw
    MDEZMBcGA1UEAwwQZ29kZGItdGVzdC5sb2NhbDETMBEGA1UECgwKR29kREIgVGVz
    dDAeFw0yNjExMjAwMTQ2MDdaFw0zNjExMTcwMTQ2MDdaMDAxGTAXBgNVBAMMEGdv
    ZGRiLXRlc3QubG9jYWwxEzARBgNVBAoMCkdvZERCIFRlc3QwWTATBgcqhkjOPQIB
    BggqhkjOPQMBBwNCAATMmpK9cQap0r6EBs6Q7U9tFMGuWfaR4wRRvdW5oT29QEFu
    64uXgYAOpCL1RjrcEvRpyYe2IaHPvej4PbZ3cnxYo08wTTAdBgNVHQ4EFgQUQe8D
    Urbsb9ksnfenSznfHcXyhwEwDwYDVR0TAQH/BAUwAwEB/zAbBgNVHREEFDASghBn
    b2RkYi10ZXN0LmxvY2FsMAoGCCqGSM49BAMCA0gAMEUCIQDGF5rpDY3xa+39XozO
    0wMCCnIjFfvyxP6oikE5rSG/zgIgSYPvVzIGSmyDNaFCnp4bM+SazrVwwCAgn+gY
    snrgrBs=
    -----END CERTIFICATE-----
    """
    static let selfSignedSHA = "2E:28:02:F7:6D:D2:5C:CF:F1:42:AB:3B:1F:2E:B7:5A:30:7F:B6:6B:32:94:BF:03:66:78:07:15:0A:7C:09:F6"

    static func selfSignedDER() throws -> [UInt8] {
        try #require(TLSVerify.der(fromPEM: selfSignedPEM))
    }

    // MARK: 지문

    @Test func fingerprintFormat() {
        #expect(TLSVerify.fingerprint([0x3F, 0xA2, 0x00, 0x9C]) == "3F:A2:00:9C")
        #expect(TLSVerify.fingerprint([]) == "")
        // "abc" 의 SHA-256
        #expect(TLSVerify.sha256Fingerprint(der: Array("abc".utf8))
                == "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD")
    }

    @Test func pinComparisonIgnoresFormatting() {
        let fp = "3F:A2:00:9C"
        #expect(TLSVerify.pinMatches("3fa2009c", fp))
        #expect(TLSVerify.pinMatches("SHA256:3F:A2:00:9C", fp))
        #expect(TLSVerify.pinMatches(" 3f a2 00 9c ", fp))
        #expect(!TLSVerify.pinMatches("3F:A2:00:9D", fp))
        #expect(!TLSVerify.pinMatches("", fp))
    }

    // MARK: 판정 표

    @Test func decisionTableDirect() {
        let fp = "AA:BB"
        // 체인 통과 · 고정 없음 → 확인됨
        #expect(TLSVerify.decide(checkChain: true, chainOK: true, reasons: [], leafSHA256: fp, pin: nil) == .trusted)
        // 체인 실패 · 고정 없음 → 묻기 (이유 그대로)
        #expect(TLSVerify.decide(checkChain: true, chainOK: false, reasons: [.nameMismatch, .expired], leafSHA256: fp, pin: nil)
                == .untrusted([.nameMismatch, .expired]))
        // 이유를 못 찾았으면 신뢰할 수 없는 발급자
        #expect(TLSVerify.decide(checkChain: true, chainOK: false, reasons: [], leafSHA256: fp, pin: nil)
                == .untrusted([.untrustedIssuer]))
        // 체인 실패 · 고정 지문 같음 → 고정 인증서로 연결
        #expect(TLSVerify.decide(checkChain: true, chainOK: false, reasons: [.untrustedIssuer], leafSHA256: fp, pin: "aabb") == .pinned)
        // 체인 통과 · 고정 지문 같음 → 확인됨
        #expect(TLSVerify.decide(checkChain: true, chainOK: true, reasons: [], leafSHA256: fp, pin: fp) == .trusted)
        // 고정 지문 다름 → 체인이 통과해도 거부
        #expect(TLSVerify.decide(checkChain: true, chainOK: true, reasons: [], leafSHA256: fp, pin: "CC:DD") == .pinMismatch)
        #expect(TLSVerify.decide(checkChain: true, chainOK: false, reasons: [], leafSHA256: fp, pin: "CC:DD") == .pinMismatch)
        // 빈 고정 값은 없는 것으로
        #expect(TLSVerify.decide(checkChain: true, chainOK: true, reasons: [], leafSHA256: fp, pin: "") == .trusted)
    }

    @Test func decisionTableTunnel() {
        let fp = "AA:BB"
        #expect(TLSVerify.decide(checkChain: false, chainOK: false, reasons: [], leafSHA256: fp, pin: nil) == .unchecked)
        #expect(TLSVerify.decide(checkChain: false, chainOK: false, reasons: [], leafSHA256: fp, pin: fp) == .pinned)
        #expect(TLSVerify.decide(checkChain: false, chainOK: false, reasons: [], leafSHA256: fp, pin: "CC") == .pinMismatch)
    }

    @Test func verdictAllowsConnection() {
        #expect(TLSVerdict.trusted.allowsConnection)
        #expect(TLSVerdict.pinned.allowsConnection)
        #expect(TLSVerdict.unchecked.allowsConnection)
        #expect(!TLSVerdict.untrusted([.expired]).allowsConnection)
        #expect(!TLSVerdict.pinMismatch.allowsConnection)
    }

    @Test func statusText() {
        #expect(TLSStatus.verified.text == "TLS 사용 · 인증서 확인됨")
        #expect(TLSStatus.pinned.text == "TLS 사용 · 고정 인증서")
        #expect(TLSStatus.tunnelUnchecked.text == "TLS 사용 · 확인 안 함(SSH 터널)")
        #expect(TLSStatus.off.text == "TLS 안 씀")
        #expect(TLSVerify.status(.trusted) == .verified)
        #expect(TLSVerify.status(.pinned) == .pinned)
        #expect(TLSVerify.status(.unchecked) == .tunnelUnchecked)
    }

    // MARK: 정책

    @Test func policyFromProfile() {
        var p = ConnectionProfile(host: "db.example.com")
        #expect(TLSPolicy.of(p) == TLSPolicy(verify: true, hostname: "db.example.com", pin: nil))
        p.tlsPinSHA256 = ""
        #expect(TLSPolicy.of(p).pin == nil)
        p.tlsPinSHA256 = "AA:BB"
        p.ssh = SSHConfig(host: "bastion")
        // 터널이어도 원래 DB 호스트 이름으로 확인 (#197) — 고정 지문은 함께
        #expect(TLSPolicy.of(p) == TLSPolicy(verify: true, hostname: "db.example.com", pin: "AA:BB"))
        p.tlsVerify = false
        #expect(!TLSPolicy.of(p).verify)
    }

    // MARK: 프로필 저장 형식

    @Test func oldProfileDecodesWithVerifyOn() throws {
        let json = """
        [{"id":"7D3C2D8E-1A3B-4C55-9F00-2B9C0E7A1111","kind":"mysql","name":"old","host":"db","port":3306,
          "username":"u","useTLS":true}]
        """
        let p = try JSONDecoder().decode([ConnectionProfile].self, from: Data(json.utf8))[0]
        #expect(p.tlsVerify == true)
        #expect(p.tlsPinSHA256 == nil)
    }

    @Test func profileRoundTripsTLSFields() throws {
        var p = ConnectionProfile(name: "x", host: "h")
        p.tlsVerify = false
        p.tlsPinSHA256 = "AA:BB"
        let data = try JSONEncoder().encode(p)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"tlsVerify\":false"))
        #expect(text.contains("\"tlsPinSHA256\":\"AA:BB\""))
        let back = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        #expect(back.tlsVerify == false)
        #expect(back.tlsPinSHA256 == "AA:BB")
    }

    // MARK: 실제 인증서 (자체 서명)

    @Test func certInfoFromSelfSigned() throws {
        let info = TLSVerify.certInfo(der: try Self.selfSignedDER())
        #expect(info.sha256 == Self.selfSignedSHA)
        #expect(info.subject == "CN=goddb-test.local, O=GodDB Test")
        #expect(info.issuer == "CN=goddb-test.local, O=GodDB Test")
        #expect(info.validityText == "2026-11-20 ~ 2036-11-17")
    }

    @Test func selfSignedIsUntrusted() throws {
        let der = try Self.selfSignedDER()
        let r = TLSVerify.evaluate(chain: [der], hostname: "goddb-test.local")
        #expect(!r.ok)
        #expect(r.reasons == [.untrustedIssuer])
        // 다른 이름으로 접속 → 이름도 다름
        let other = TLSVerify.evaluate(chain: [der], hostname: "127.0.0.1")
        #expect(other.reasons.contains(.untrustedIssuer))
        #expect(other.reasons.contains(.nameMismatch))
        // 유효 기간이 지난 시각 → 만료됨
        let later = TLSVerify.evaluate(chain: [der], hostname: "goddb-test.local", now: Date(timeIntervalSince1970: 2_200_000_000))
        #expect(later.reasons.contains(.expired))
    }

    @Test func reasonsFromTrustDetails() {
        #expect(TLSVerify.reasons(failedChecks: ["AnchorTrusted", "ServerAuthEKU"]) == [.untrustedIssuer])
        #expect(TLSVerify.reasons(failedChecks: ["SSLHostname"]) == [.nameMismatch])
        #expect(TLSVerify.reasons(failedChecks: ["TemporalValidity"]) == [.expired])
        #expect(TLSVerify.reasons(failedChecks: ["AnchorTrusted", "SSLHostname", "TemporalValidity"])
                == [.untrustedIssuer, .nameMismatch, .expired])
        #expect(TLSVerify.reasons(failedChecks: []) == [.untrustedIssuer])
    }

    @Test func verifierFlow() throws {
        let der = try Self.selfSignedDER()
        // 고정 없음 → 묻기 (오류에 인증서 정보)
        let first = TLSVerifier(policy: TLSPolicy(verify: true, hostname: "goddb-test.local", pin: nil))
        #expect(first.judge(chain: [der]) == .untrusted([.untrustedIssuer]))
        guard case .untrusted(let info, _)? = first.failure else { Issue.record("인증서 오류 없음"); return }
        #expect(info.sha256 == Self.selfSignedSHA)
        // 신뢰(고정) 후 → 연결
        let pinned = TLSVerifier(policy: TLSPolicy(verify: true, hostname: "goddb-test.local", pin: info.sha256))
        #expect(pinned.judge(chain: [der]) == .pinned)
        #expect(pinned.failure == nil)
        #expect(pinned.status == .pinned)
        // 인증서가 바뀜 → 거부
        let changed = TLSVerifier(policy: TLSPolicy(verify: true, hostname: "goddb-test.local", pin: "00:11"))
        #expect(changed.judge(chain: [der]) == .pinMismatch)
        #expect(changed.failure == .pinMismatch(info, expected: "00:11"))
        // 터널 · 고정 없음 → 확인 안 함
        let tunnel = TLSVerifier(policy: TLSPolicy(verify: true, hostname: nil, pin: nil))
        #expect(tunnel.judge(chain: [der]) == .unchecked)
        #expect(tunnel.status == .tunnelUnchecked)
        // 오류 바꾸기: 거부했으면 인증서 오류, 아니면 원래 오류
        #expect(changed.map(DBError.notConnected) as? TLSCertificateError != nil)
        #expect(pinned.map(DBError.notConnected) is DBError)
    }

    @Test func errorMessages() {
        #expect(TLSCertificateError.serverNoTLS.errorDescription == "서버가 TLS 를 지원하지 않아요. TLS 를 끄거나 SSH 터널을 쓰세요.")
        let info = TLSCertInfo(subject: "CN=a", issuer: "CN=a", notBefore: nil, notAfter: nil, sha256: "AA")
        #expect(TLSCertificateError.pinMismatch(info, expected: "BB").errorDescription?.hasPrefix("서버 인증서가 바뀌었어요.") == true)
        #expect(ErrorText.describe(TLSCertificateError.serverNoTLS).message == "서버가 TLS 를 지원하지 않아요. TLS 를 끄거나 SSH 터널을 쓰세요.")
    }

    @Test func redisCertificateHost() {
        #expect(RedisSession.certificateHost(node: "node1.cache.example.com", configured: "cfg.example.com") == "node1.cache.example.com")
        #expect(RedisSession.certificateHost(node: "10.0.0.5", configured: "cfg.example.com") == "cfg.example.com")
        #expect(RedisSession.certificateHost(node: "10.0.0.5", configured: "s1.example.com:26379, s2:26379") == "s1.example.com")
        #expect(RedisSession.certificateHost(node: "10.0.0.5", configured: "10.0.0.1") == "10.0.0.5")
    }
}

/// 실제 TLS 서버 (자체 서명 인증서) — 로컬 redis-server 를 TLS 로 띄우고 포트를 넘긴다. 비밀번호 goddbtest.
///   redis-server --port 0 --tls-port 46379 --tls-cert-file a.crt --tls-key-file a.key --tls-auth-clients no --requirepass goddbtest
///   GODDB_REDIS_TLS_PORT=46379 ./scripts/test.sh --filter TLSIntegrationTests
@Suite("TLS integration", .serialized, .enabled(if: ProcessInfo.processInfo.environment["GODDB_REDIS_TLS_PORT"] != nil))
struct TLSIntegrationTests {
    func profile(host: String = "127.0.0.1", pin: String? = nil, verify: Bool = true) -> ConnectionProfile {
        var p = ConnectionProfile(kind: .redis, name: "redis-tls", host: host,
                                  port: Int(ProcessInfo.processInfo.environment["GODDB_REDIS_TLS_PORT"]!)!,
                                  username: "", database: "0", useTLS: true)
        p.tlsVerify = verify
        p.tlsPinSHA256 = pin
        return p
    }

    @Test func selfSignedAsksThenPinConnects() async throws {
        // 1) 처음: 신뢰할 수 없는 발급자 → 인증서 정보를 담은 오류
        var info: TLSCertInfo?
        do {
            _ = try await RedisSession.connect(profile: profile(), password: "goddbtest")
            Issue.record("자체 서명 인증서인데 연결됨")
        } catch TLSCertificateError.untrusted(let i, let reasons) {
            info = i
            #expect(reasons.contains(.untrustedIssuer))
        }
        let pin = try #require(info?.sha256)
        #expect(pin.count == 95)

        // 2) 고정 후: 묻지 않고 연결, 상태 "고정 인증서"
        let s = try await RedisSession.connect(profile: profile(pin: pin), password: "goddbtest")
        #expect(await s.tlsStatus == .pinned)
        await s.close()

        // 3) 다른 지문 → 거부
        await #expect(throws: TLSCertificateError.self) {
            _ = try await RedisSession.connect(profile: profile(pin: "00:11:22"), password: "goddbtest")
        }

        // 4) 확인 끔 → 암호화만
        let off = try await RedisSession.connect(profile: profile(verify: false), password: "goddbtest")
        #expect(await off.tlsStatus == .unchecked)
        await off.close()
    }

    /// SSH 터널로 붙어도 인증서 이름을 원래 DB 호스트로 확인한다 — 고정 안 한 터널 접속이 아무 인증서나 받지 않게 (#197)
    @Test func tunnelStillChecksHostName() {
        var p = ConnectionProfile(kind: .postgres, name: "t", host: "db.example.test", port: 5432)
        p.ssh = SSHConfig(host: "bastion.example.test")
        let policy = TLSPolicy.of(p)
        #expect(policy.hostname == "db.example.test")
        // 체인을 확인하므로, 고정 없이 확인 안 된 인증서는 "확인 안 함" 으로 통과하지 않고 거부(확인 창)
        #expect(TLSVerify.decide(checkChain: policy.hostname != nil, chainOK: false, reasons: [.nameMismatch],
                                 leafSHA256: "AA", pin: policy.pin) == .untrusted([.nameMismatch]))
    }
}
