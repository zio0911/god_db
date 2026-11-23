import CryptoKit
import Foundation
import os
import Security

// MARK: - 로컬 데이터 암호화 (쿼리 히스토리 · 탭 내용 · 저장 쿼리 · AI 대화)
//
// 파일 형식 `GDBENC1` (Windows 판도 같은 형식을 쓴다. 키 보관만 OS 별로 다르다):
//
//     GDBENC1\n
//     <base64(sealed box)>\n
//     <base64(sealed box)>\n      ← 줄 단위 파일(history.jsonl)만 여러 줄
//
// - 첫 줄은 ASCII `GDBENC1` 한 줄 (끝 `\n`). 이 줄이 없으면 예전 평문 파일로 보고 한 번 옮긴다.
// - 그다음 줄마다 AES-256-GCM 봉투 하나: `nonce(12) ‖ ciphertext ‖ tag(16)` (CryptoKit `combined`) 를
//   표준 base64(줄바꿈 없음)로. 추가 인증 데이터(AAD)는 쓰지 않는다.
// - 통째 파일(tabs.json 등)은 봉투가 하나 = 원래 JSON 전체.
//   줄 단위 파일(history.jsonl)은 한 줄 = 한 건의 JSON (덧붙이기가 싸다).
// - 키: 무작위 256비트. macOS 는 키체인 generic password
//   (service `GodDB-local-data`, account `local-data-key-v1`, AfterFirstUnlockThisDeviceOnly, 동기화 안 함).
//   키는 이 기기에서만 쓰이므로 파일을 다른 PC 로 옮기면 열 수 없다.
// - 봉투마다 위변조(GCM 태그)는 잡지만, 줄을 통째로 빼거나 순서를 바꾸는 것은 잡지 않는다 (기밀성이 목적).

/// 키가 없거나 복호화가 안 될 때
public enum LocalDataCryptoError: Error, Equatable, LocalizedError {
    /// 키체인에서 키를 읽거나 만들 수 없음 (OSStatus)
    case keyUnavailable(Int32)
    /// `GDBENC1` 형식이 아님 (base64 · 봉투 모양이 틀림)
    case malformed
    /// 위변조됐거나 다른 키로 잠긴 데이터
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .keyUnavailable(let s): return "local data key unavailable (OSStatus \(s))"
        case .malformed: return "not a GDBENC1 sealed box"
        case .authenticationFailed: return "local data failed authentication (tampered or wrong key)"
        }
    }
}

/// 암호화 키를 주는 곳. 테스트는 메모리 키를 넣어 실제 키체인을 건드리지 않는다.
public protocol LocalDataKeyProvider: Sendable {
    func key() throws -> SymmetricKey
}

/// 메모리 키 (테스트 · 자동 화면 테스트용)
public struct StaticLocalDataKeyProvider: LocalDataKeyProvider {
    public let value: SymmetricKey
    public init(_ key: SymmetricKey = SymmetricKey(size: .bits256)) { value = key }
    public func key() throws -> SymmetricKey { value }
}

/// 언제나 실패하는 키 (키체인 오류 흉내)
public struct UnavailableLocalDataKeyProvider: LocalDataKeyProvider {
    public init() {}
    public func key() throws -> SymmetricKey { throw LocalDataCryptoError.keyUnavailable(errSecInteractionNotAllowed) }
}

/// macOS 키체인 키: 처음이면 무작위 256비트를 만들어 둔다.
public struct KeychainLocalDataKeyProvider: LocalDataKeyProvider {
    public static let service = "GodDB-local-data"
    public static let account = "local-data-key-v1"

    public init() {}

    public func key() throws -> SymmetricKey {
        if let data = try load() { return SymmetricKey(data: data) }
        var bytes = Data(count: 32)
        let rc = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard rc == errSecSuccess else { throw LocalDataCryptoError.keyUnavailable(rc) }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrLabel as String: "GodDB local data key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: bytes,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem, let data = try load() { return SymmetricKey(data: data) }  // 다른 창 · 앱이 먼저 만듦
        guard status == errSecSuccess else { throw LocalDataCryptoError.keyUnavailable(status) }
        return SymmetricKey(data: bytes)
    }

    private func load() throws -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data, data.count == 32 else {
            throw LocalDataCryptoError.keyUnavailable(status == errSecSuccess ? errSecDecode : status)
        }
        return data
    }
}

/// `GDBENC1` 암호화 · 복호화와 파일 읽기 · 쓰기
public final class LocalDataCrypto: @unchecked Sendable {
    /// 앱 전체가 쓰는 것. 단위 테스트 프로세스와 화면 자동 테스트에서는 실제 키체인 대신 메모리 · 임시 키를 쓴다.
    public static let shared: LocalDataCrypto = {
        if isTestProcess { return LocalDataCrypto(provider: StaticLocalDataKeyProvider()) }
        if AppPaths.uiTest {
            // 임시 데이터 폴더마다 정해지는 키 (다시 켜도 탭이 열리게, 키체인은 건드리지 않음)
            let seed = Data(("GodDB-ui-test|" + AppPaths.dataDirectory.path).utf8)
            return LocalDataCrypto(provider: StaticLocalDataKeyProvider(SymmetricKey(data: SHA256.hash(data: seed))))
        }
        return LocalDataCrypto(provider: KeychainLocalDataKeyProvider())
    }()

    static let isTestProcess: Bool = {
        let name = ProcessInfo.processInfo.processName
        return name == "xctest" || name.hasPrefix("swiftpm-testing-helper") || name.hasSuffix("PackageTests")
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()

    /// 파일 첫 줄 (끝 `\n` 포함)
    public static let header = Data("GDBENC1\n".utf8)

    static let log = Logger(subsystem: "local.goddb.app", category: "local-data")

    private let provider: any LocalDataKeyProvider
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?

    public init(provider: any LocalDataKeyProvider) {
        self.provider = provider
    }

    /// 키 (성공한 키만 기억한다. 실패는 다음에 다시 시도)
    public func key() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let k = try provider.key()
        cachedKey = k
        return k
    }

    public var isKeyAvailable: Bool { (try? key()) != nil }

    // MARK: 봉투

    /// AES-GCM 봉투 (combined = nonce ‖ ciphertext ‖ tag)
    public func seal(_ plain: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key())
        guard let combined = box.combined else { throw LocalDataCryptoError.malformed }
        return combined
    }

    public func open(_ combined: Data) throws -> Data {
        let k = try key()
        guard let box = try? AES.GCM.SealedBox(combined: combined) else { throw LocalDataCryptoError.malformed }
        do { return try AES.GCM.open(box, using: k) } catch { throw LocalDataCryptoError.authenticationFailed }
    }

    /// 한 줄 (base64, 줄바꿈 없음)
    public func sealLine(_ plain: Data) throws -> String { try seal(plain).base64EncodedString() }

    public func openLine<S: StringProtocol>(_ line: S) throws -> Data {
        guard let data = Data(base64Encoded: String(line.trimmingCharacters(in: .whitespacesAndNewlines))) else {
            throw LocalDataCryptoError.malformed
        }
        return try open(data)
    }

    // MARK: 문자열 (UserDefaults 등에 넣을 때)

    /// `GDBENC1:` + base64 봉투
    public static let stringPrefix = "GDBENC1:"

    public func sealString(_ text: String) throws -> String { Self.stringPrefix + (try sealLine(Data(text.utf8))) }

    /// 접두어가 없으면 예전 평문으로 보고 그대로 돌려준다.
    public func openString(_ stored: String) throws -> String {
        guard stored.hasPrefix(Self.stringPrefix) else { return stored }
        return String(decoding: try openLine(stored.dropFirst(Self.stringPrefix.count)), as: UTF8.self)
    }

    // MARK: 파일

    public static func isEncrypted(_ data: Data) -> Bool { data.starts(with: header) }

    /// 통째 파일 내용: 머리 줄 + 봉투 한 줄
    public func encryptDocument(_ plain: Data) throws -> Data {
        var out = Self.header
        out.append(Data(try sealLine(plain).utf8))
        out.append(0x0A)
        return out
    }

    /// 통째 파일 복호화 (봉투가 정확히 하나여야 한다)
    public func decryptDocument(_ data: Data) throws -> Data {
        guard Self.isEncrypted(data) else { throw LocalDataCryptoError.malformed }
        let lines = Self.bodyLines(data)
        guard lines.count == 1 else { throw LocalDataCryptoError.malformed }
        return try openLine(lines[0])
    }

    /// 머리 줄 다음의 봉투 줄들 (빈 줄 제외)
    static func bodyLines(_ data: Data) -> [Substring] {
        String(decoding: data.dropFirst(header.count), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
    }

    /// 통째 파일 읽기 결과
    public enum ReadResult: Equatable {
        case missing
        /// 복호화한 내용
        case decrypted(Data)
        /// 예전 평문 파일 (옮기지 못했으면 그대로 남아 있다)
        case plaintext(Data)
        /// 암호화돼 있지만 키를 못 얻음 — 파일은 그대로 둔다
        case keyUnavailable
        /// 위변조 · 다른 키 — 파일은 `<이름>.undecryptable` 로 옮겼다
        case damaged
    }

    /// 통째 파일 읽기. 예전 평문이면 바로 암호화해 바꿔 쓴다 (키가 없으면 평문은 손대지 않는다).
    public func readDocument(at url: URL) -> ReadResult {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        if !Self.isEncrypted(data) {
            if data.isEmpty { return .plaintext(data) }
            do {
                try writeDocument(data, to: url)
            } catch {
                Self.log.warning("GodDB: kept plaintext \(url.lastPathComponent, privacy: .public), key unavailable: \(error.localizedDescription, privacy: .public)")
            }
            return .plaintext(data)
        }
        do {
            return .decrypted(try decryptDocument(data))
        } catch LocalDataCryptoError.keyUnavailable {
            Self.log.warning("GodDB: cannot read \(url.lastPathComponent, privacy: .public), key unavailable")
            return .keyUnavailable
        } catch {
            Self.moveAside(url)
            return .damaged
        }
    }

    /// 읽은 평문 (없거나 못 읽으면 nil)
    public func readDocumentData(at url: URL) -> Data? {
        switch readDocument(at: url) {
        case .decrypted(let d), .plaintext(let d): return d
        case .missing, .keyUnavailable, .damaged: return nil
        }
    }

    /// 통째 파일 쓰기 (원자적, 권한 600). 키가 없으면 throw 하고 아무것도 쓰지 않는다 (평문을 쓰지 않음).
    public func writeDocument(_ plain: Data, to url: URL) throws {
        let body = try encryptDocument(plain)
        try Self.writeAtomically(body, to: url)
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: 설정(UserDefaults)에 두는 글

    /// 암호화해 둔 글 읽기. 예전 평문이면 그대로 돌려주고 암호화해 바꿔 둔다. 못 열면 nil.
    public func defaultsString(forKey key: String, in defaults: UserDefaults = .standard) -> String? {
        guard let stored = defaults.string(forKey: key) else { return nil }
        if !stored.hasPrefix(Self.stringPrefix) {
            if let sealed = try? sealString(stored) { defaults.set(sealed, forKey: key) }
            return stored
        }
        return try? openString(stored)
    }

    /// 암호화해서 저장. 키가 없으면 쓰지 않는다 (평문으로 쓰지 않음).
    public func setDefaultsString(_ text: String, forKey key: String, in defaults: UserDefaults = .standard) {
        guard let sealed = try? sealString(text) else { return }
        defaults.set(sealed, forKey: key)
    }

    /// 열 수 없는 파일을 지우지 않고 옆으로 치운다 (`<이름>.undecryptable`, 이전 것은 덮어씀)
    static func moveAside(_ url: URL) {
        let fm = FileManager.default
        let dest = url.appendingPathExtension("undecryptable")
        try? fm.removeItem(at: dest)
        try? fm.moveItem(at: url, to: dest)
        log.warning("GodDB: \(url.lastPathComponent, privacy: .public) could not be decrypted, moved to \(dest.lastPathComponent, privacy: .public)")
    }
}
