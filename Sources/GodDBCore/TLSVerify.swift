import CryptoKit
import Foundation
import NIOCore
import NIOSSL
import Security

// F9-3. TLS 서버 인증서 확인 (MySQL · PostgreSQL · Redis)
// 직접 접속: 시스템 신뢰 저장소로 체인 + 호스트 이름 확인 → 실패하면 고정 지문(tlsPinSHA256) 비교.
// SSH 터널 경유: 이름 확인을 하지 않고, 고정 지문이 있으면 지문만 비교.

/// 접속할 때 인증서를 어떻게 확인할지
public struct TLSPolicy: Sendable, Equatable {
    /// 서버 인증서 확인 (접속 편집의 "서버 인증서 확인")
    public var verify: Bool
    /// 체인 · 이름을 확인할 호스트 이름. nil 이면 SSH 터널 경유라 지문만 확인한다.
    public var hostname: String?
    /// 고정한 인증서 지문 (SHA-256)
    public var pin: String?

    public init(verify: Bool, hostname: String?, pin: String?) {
        self.verify = verify
        self.hostname = hostname
        self.pin = pin
    }

    /// 접속 정보로 정한다. 터널이면 hostname 없음.
    public static func of(_ profile: ConnectionProfile, host: String? = nil) -> TLSPolicy {
        let pin = profile.tlsPinSHA256.flatMap { $0.isEmpty ? nil : $0 }
        return TLSPolicy(verify: profile.tlsVerify, hostname: profile.ssh == nil ? (host ?? profile.host) : nil, pin: pin)
    }
}

/// 인증서 확인을 통과하지 못한 이유
public enum TLSFailureReason: String, Sendable, Hashable, CaseIterable {
    case untrustedIssuer
    case nameMismatch
    case expired

    public var text: String {
        switch self {
        case .untrustedIssuer: return tr("신뢰할 수 없는 발급자")
        case .nameMismatch: return tr("이름이 다름")
        case .expired: return tr("만료됨")
        }
    }
}

/// 인증서 정보 (확인 창에 보여 줌)
public struct TLSCertInfo: Sendable, Hashable {
    public var subject: String
    public var issuer: String
    public var notBefore: Date?
    public var notAfter: Date?
    /// 맨 앞(서버) 인증서 DER 의 SHA-256, "3F:A2:…" 형식
    public var sha256: String

    public init(subject: String, issuer: String, notBefore: Date?, notAfter: Date?, sha256: String) {
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.sha256 = sha256
    }

    /// "2026-01-01 ~ 2027-01-01"
    public var validityText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "\(notBefore.map(f.string) ?? "?") ~ \(notAfter.map(f.string) ?? "?")"
    }
}

/// 확인 결과
public enum TLSVerdict: Sendable, Hashable {
    /// 시스템 신뢰 저장소로 체인 · 이름 확인 통과
    case trusted
    /// 체인 확인은 안 됐지만(또는 터널이라 하지 않았지만) 고정 지문과 같음
    case pinned
    /// 터널 경유 · 고정 지문 없음 → 확인하지 않음
    case unchecked
    /// 체인 확인 실패 · 고정 지문 없음 → 사용자에게 묻는다
    case untrusted([TLSFailureReason])
    /// 고정 지문과 다름 → 연결하지 않는다
    case pinMismatch

    public var allowsConnection: Bool {
        switch self {
        case .trusted, .pinned, .unchecked: return true
        case .untrusted, .pinMismatch: return false
        }
    }
}

/// 연결 후 상태창에 남기는 TLS 상태
public enum TLSStatus: Sendable, Hashable {
    case verified
    case pinned
    case tunnelUnchecked
    /// "서버 인증서 확인" 을 끔
    case unchecked
    /// SQL Server: 암호화만 (인증서 확인 불가)
    case encryptOnly
    case off

    public var text: String {
        switch self {
        case .verified: return tr("TLS 사용 · 인증서 확인됨")
        case .pinned: return tr("TLS 사용 · 고정 인증서")
        case .tunnelUnchecked: return tr("TLS 사용 · 확인 안 함(SSH 터널)")
        case .unchecked: return tr("TLS 사용 · 확인 안 함")
        case .encryptOnly: return tr("TLS 사용 · 암호화만(인증서 확인 불가)")
        case .off: return tr("TLS 안 씀")
        }
    }
}

/// 인증서 때문에 연결하지 않았을 때. 화면이 이 정보를 보여 주고, 신뢰하면 지문을 저장한 뒤 다시 연결한다.
public enum TLSCertificateError: LocalizedError, Sendable, Equatable {
    case untrusted(TLSCertInfo, [TLSFailureReason])
    case pinMismatch(TLSCertInfo, expected: String)
    /// TLS 를 켰는데 서버가 TLS 를 하지 않음
    case serverNoTLS

    public var errorDescription: String? {
        switch self {
        case .untrusted(let info, let reasons):
            return tr("서버 인증서를 확인할 수 없어요 (%@). SHA-256: %@",
                      reasons.map(\.text).joined(separator: ", "), info.sha256)
        case .pinMismatch:
            return tr("서버 인증서가 바뀌었어요. 서버를 교체한 게 아니라면 중간에서 가로채는 공격일 수 있어요. 관리자에게 확인한 뒤 [저장된 인증서 지우기] 를 누르세요.")
        case .serverNoTLS:
            return tr("서버가 TLS 를 지원하지 않아요. TLS 를 끄거나 SSH 터널을 쓰세요.")
        }
    }
}

public enum TLSVerify {
    // MARK: - 지문

    /// 바이트 → "3F:A2:…:9C"
    public static func fingerprint(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// DER 의 SHA-256 지문
    public static func sha256Fingerprint(der: some DataProtocol) -> String {
        fingerprint(SHA256.hash(data: Data(der)))
    }

    /// 비교용: 콜론 · 공백 · "SHA256:" 접두사를 빼고 대문자로
    public static func normalize(_ fingerprint: String) -> String {
        var s = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.uppercased().hasPrefix("SHA256:") { s = String(s.dropFirst(7)) }
        return s.filter { $0.isHexDigit }.uppercased()
    }

    public static func pinMatches(_ pin: String, _ fingerprint: String) -> Bool {
        let a = normalize(pin)
        return !a.isEmpty && a == normalize(fingerprint)
    }

    /// PEM(첫 인증서) → DER
    public static func der(fromPEM pem: String) -> [UInt8]? {
        guard let start = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = pem.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<pem.endIndex) else { return nil }
        let body = pem[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        return Data(base64Encoded: String(body)).map { [UInt8]($0) }
    }

    // MARK: - 판정

    /// 판정 표.
    /// - checkChain: 직접 접속이면 true (체인 · 이름 확인 결과를 본다), 터널이면 false
    /// - chainOK: 시스템 신뢰 저장소 확인 통과 여부
    public static func decide(checkChain: Bool, chainOK: Bool, reasons: [TLSFailureReason],
                              leafSHA256: String, pin: String?) -> TLSVerdict {
        if let pin, !normalize(pin).isEmpty {
            // 고정한 인증서가 있으면 지문이 달라질 때 항상 거부 (체인이 통과해도)
            guard pinMatches(pin, leafSHA256) else { return .pinMismatch }
            return checkChain && chainOK ? .trusted : .pinned
        }
        guard checkChain else { return .unchecked }
        return chainOK ? .trusted : .untrusted(reasons.isEmpty ? [.untrustedIssuer] : reasons)
    }

    /// 판정 → 상태창 문구
    public static func status(_ verdict: TLSVerdict) -> TLSStatus {
        switch verdict {
        case .trusted: return .verified
        case .pinned: return .pinned
        default: return .tunnelUnchecked
        }
    }

    // MARK: - 인증서 정보

    /// DER → 주체 · 발급자 · 유효 기간 · 지문
    public static func certInfo(der: [UInt8]) -> TLSCertInfo {
        let sha = sha256Fingerprint(der: der)
        guard let cert = try? NIOSSLCertificate(bytes: der, format: .der) else {
            return TLSCertInfo(subject: "?", issuer: "?", notBefore: nil, notAfter: nil, sha256: sha)
        }
        return TLSCertInfo(subject: nameText(cert.subjectName), issuer: nameText(cert.issuerName),
                           notBefore: Date(timeIntervalSince1970: TimeInterval(cert.notValidBefore)),
                           notAfter: Date(timeIntervalSince1970: TimeInterval(cert.notValidAfter)),
                           sha256: sha)
    }

    /// "CN=db.example.com, O=Example" — CN 을 먼저
    static func nameText(_ names: [SSLCertificateName]) -> String {
        func label(_ t: SSLCertificateNameType) -> String? {
            switch t {
            case .commonName: return "CN"
            case .organization: return "O"
            case .organizationalUnit: return "OU"
            case .country: return "C"
            case .state: return "ST"
            case .city: return "L"
            default: return nil
            }
        }
        let parts = names.compactMap { n in label(n.type).map { (key: $0, value: n.value) } }
        let ordered = parts.filter { $0.key == "CN" } + parts.filter { $0.key != "CN" }
        let text = ordered.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return text.isEmpty ? "?" : text
    }

    // MARK: - 시스템 신뢰 저장소 확인 (Security.framework)

    /// 체인을 시스템 신뢰 저장소로 확인한다. 네트워크(폐기 확인)를 쓸 수 있어 이벤트 루프에서 부르지 않는다.
    /// 실패하면 SecTrust 결과 상세(TrustResultDetails)로 이유를 나눈다.
    /// - hostname: nil 이면 이름 확인을 하지 않는다
    public static func evaluate(chain ders: [[UInt8]], hostname: String?, now: Date? = nil)
        -> (ok: Bool, reasons: [TLSFailureReason]) {
        let certs = ders.compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
        guard !certs.isEmpty else { return (false, [.untrustedIssuer]) }
        let policy = SecPolicyCreateSSL(true, hostname as CFString?)
        var created: SecTrust?
        guard SecTrustCreateWithCertificates(certs as CFArray, policy, &created) == errSecSuccess, let trust = created else {
            return (false, [.untrustedIssuer])
        }
        if let now { SecTrustSetVerifyDate(trust, now as CFDate) }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return (true, []) }

        let details = (SecTrustCopyResult(trust) as? [String: Any])?["TrustResultDetails"] as? [[String: Any]] ?? []
        let failed = Set(details.flatMap(\.keys)).subtracting(["StatusCodes"])
        return (false, reasons(failedChecks: failed))
    }

    /// SecTrust 상세의 실패 항목 이름 → 이유 (이름 · 기간 말고는 모두 신뢰할 수 없는 발급자로 본다)
    static func reasons(failedChecks: Set<String>) -> [TLSFailureReason] {
        var r: [TLSFailureReason] = []
        if !failedChecks.subtracting(["SSLHostname", "TemporalValidity"]).isEmpty || failedChecks.isEmpty {
            r.append(.untrustedIssuer)
        }
        if failedChecks.contains("SSLHostname") { r.append(.nameMismatch) }
        if failedChecks.contains("TemporalValidity") { r.append(.expired) }
        return r
    }

    // MARK: - NIOSSL

    /// 확인을 켜면 NIOSSL 기본 확인 대신 사용자 정의 콜백이 불리도록 한다 (`.none` 이면 콜백이 불리지 않는다)
    public static func tlsConfiguration(verify: Bool) -> TLSConfiguration {
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateVerification = verify ? .noHostnameVerification : .none
        return config
    }
}

/// 연결 한 번의 인증서 확인. NIOSSL 콜백에서 판정하고 결과를 기억한다 (연결 오류를 인증서 오류로 바꾸는 데 씀).
public final class TLSVerifier: @unchecked Sendable {
    public let policy: TLSPolicy
    private let lock = NSLock()
    private var _verdict: TLSVerdict?
    private var _info: TLSCertInfo?

    public init(policy: TLSPolicy) { self.policy = policy }

    public var verdict: TLSVerdict? { lock.withLock { _verdict } }
    public var certInfo: TLSCertInfo? { lock.withLock { _info } }

    /// 연결 후 상태창 문구
    public var status: TLSStatus {
        guard policy.verify else { return .unchecked }
        return verdict.map(TLSVerify.status) ?? (policy.hostname == nil ? .tunnelUnchecked : .verified)
    }

    /// 확인 결과가 거부면 화면용 오류
    public var failure: TLSCertificateError? {
        lock.withLock {
            guard let v = _verdict, let info = _info else { return nil }
            switch v {
            case .untrusted(let reasons): return .untrusted(info, reasons)
            case .pinMismatch: return .pinMismatch(info, expected: policy.pin ?? "")
            default: return nil
            }
        }
    }

    /// 체인을 판정한다 (동기 — 테스트 · 콜백 공용)
    public func judge(chain ders: [[UInt8]]) -> TLSVerdict {
        guard let leaf = ders.first else { return .untrusted([.untrustedIssuer]) }
        let info = TLSVerify.certInfo(der: leaf)
        let checkChain = policy.hostname != nil
        // 고정 지문이 맞으면 체인 확인(네트워크 가능)을 건너뛸 수 있지만, "확인됨" 표시를 위해 직접 접속이면 확인한다
        let result = checkChain ? TLSVerify.evaluate(chain: ders, hostname: policy.hostname) : (ok: false, reasons: [])
        let v = TLSVerify.decide(checkChain: checkChain, chainOK: result.ok, reasons: result.reasons,
                                 leafSHA256: info.sha256, pin: policy.pin)
        lock.withLock {
            // 여러 연결(주소 · 노드) 중 거부가 한 번이라도 있으면 그 결과를 남긴다
            if _verdict == nil || !v.allowsConnection { _verdict = v; _info = info }
        }
        return v
    }

    /// NIOSSL 사용자 정의 확인 콜백
    public var callback: @Sendable ([NIOSSLCertificate], EventLoopPromise<NIOSSLVerificationResult>) -> Void {
        { [self] certs, promise in
            let ders = certs.compactMap { try? $0.toDERBytes() }
            // 시스템 확인은 네트워크를 쓸 수 있어 이벤트 루프 밖에서
            DispatchQueue.global(qos: .userInitiated).async {
                let v = self.judge(chain: ders)
                promise.succeed(v.allowsConnection ? .certificateVerified : .failed)
            }
        }
    }

    /// 연결 오류를 인증서 오류로 바꾼다 (확인에서 거부했으면)
    public func map(_ error: any Error) -> any Error {
        failure ?? error
    }
}
