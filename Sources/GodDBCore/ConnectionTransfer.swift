import CommonCrypto
import CryptoKit
import Foundation

/// 접속 정보 내보내기 / 가져오기 파일.
/// 비밀번호는 기본으로 넣지 않는다. 넣을 때는 사용자가 정한 암호로 AES-GCM 암호화한다
/// (PBKDF2-SHA256 로 키를 만든다). SSH 개인키 파일은 넣지 않고 경로만 넣는다.
public struct ConnectionBundle: Codable, Sendable {
    public static let formatName = "goddb-connections"

    public struct EncryptedPasswords: Codable, Sendable {
        public var kdf: String = "pbkdf2-sha256"
        public var rounds: Int
        public var salt: String
        /// AES-GCM combined (nonce + ciphertext + tag), base64. 안에는 {접속 id: 비밀번호} JSON.
        public var data: String
    }

    public var format: String = ConnectionBundle.formatName
    public var version: Int = 1
    public var exportedAt: Date
    public var app: String
    public var profiles: [ConnectionProfile]
    public var passwords: EncryptedPasswords?

    public var hasPasswords: Bool { passwords != nil }

    public init(exportedAt: Date, app: String, profiles: [ConnectionProfile], passwords: EncryptedPasswords?) {
        self.exportedAt = exportedAt
        self.app = app
        self.profiles = profiles
        self.passwords = passwords
    }
}

public enum ConnectionTransferError: LocalizedError, Equatable {
    case notGodDBFile
    case unsupportedVersion(Int)
    case wrongPassphrase
    case emptyPassphrase

    public var errorDescription: String? {
        switch self {
        case .notGodDBFile: return tr("GodDB 접속 정보 파일이 아니에요.")
        case .unsupportedVersion(let v): return tr("지원하지 않는 파일 버전이에요 (%@). GodDB 를 업데이트해 주세요.", "\(v)")
        case .wrongPassphrase: return tr("암호가 맞지 않아요.")
        case .emptyPassphrase: return tr("비밀번호를 넣으려면 암호를 정해 주세요.")
        }
    }
}

public enum ConnectionTransfer {
    static let rounds = 200_000

    /// 내보내기 파일 내용을 만든다.
    /// - Parameters:
    ///   - passwords: 함께 넣을 비밀번호 (nil 이면 넣지 않음)
    ///   - passphrase: passwords 를 암호화할 암호
    public static func export(_ profiles: [ConnectionProfile], passwords: [UUID: String]? = nil,
                              passphrase: String? = nil, appVersion: String = "", now: Date = Date()) throws -> Data {
        var bundle = ConnectionBundle(exportedAt: now, app: "GodDB \(appVersion)".trimmingCharacters(in: .whitespaces),
                                      profiles: profiles, passwords: nil)
        if let passwords {
            guard let passphrase, !passphrase.isEmpty else { throw ConnectionTransferError.emptyPassphrase }
            let ids = Set(profiles.map(\.id))
            let plain = Dictionary(uniqueKeysWithValues: passwords.filter { ids.contains($0.key) }.map { ($0.key.uuidString, $0.value) })
            bundle.passwords = try encrypt(JSONEncoder().encode(plain), passphrase: passphrase)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    /// 파일을 읽는다. 비밀번호는 아직 풀지 않는다.
    public static func parse(_ data: Data) throws -> ConnectionBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(ConnectionBundle.self, from: data),
              bundle.format == ConnectionBundle.formatName else {
            throw ConnectionTransferError.notGodDBFile
        }
        guard bundle.version <= 1 else { throw ConnectionTransferError.unsupportedVersion(bundle.version) }
        return bundle
    }

    /// 들어 있는 비밀번호를 푼다.
    public static func passwords(in bundle: ConnectionBundle, passphrase: String) throws -> [UUID: String] {
        guard let enc = bundle.passwords else { return [:] }
        let plain = try decrypt(enc, passphrase: passphrase)
        guard let dict = try? JSONDecoder().decode([String: String].self, from: plain) else {
            throw ConnectionTransferError.wrongPassphrase
        }
        return Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }

    // MARK: - 가져오기 계획

    public enum ImportAction: Equatable, Sendable {
        /// 새로 추가
        case add
        /// 같은 접속(id)이 이미 있음 → 덮어쓰기
        case replace(existingName: String)
    }

    public static func action(for profile: ConnectionProfile, existing: [ConnectionProfile]) -> ImportAction {
        if let e = existing.first(where: { $0.id == profile.id }) { return .replace(existingName: e.name) }
        return .add
    }

    /// 가져온 접속을 기존 목록에 합친다. 같은 id 는 덮어쓰고, 새 접속은 뒤에 붙인다.
    /// 이름이 다른 접속과 겹치면 " (2)" 를 붙인다.
    public static func merge(_ incoming: [ConnectionProfile], into existing: [ConnectionProfile]) -> [ConnectionProfile] {
        var result = existing
        for var p in incoming {
            if let i = result.firstIndex(where: { $0.id == p.id }) {
                result[i] = p
                continue
            }
            let names = Set(result.map(\.name))
            if names.contains(p.name) {
                var n = 2
                while names.contains("\(p.name) (\(n))") { n += 1 }
                p.name = "\(p.name) (\(n))"
            }
            result.append(p)
        }
        return result
    }

    // MARK: - 암호화

    static func key(_ passphrase: String, salt: Data, rounds: Int) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(passphrase.utf8)
        let saltBytes = [UInt8](salt)
        _ = pw.withUnsafeBufferPointer { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: Int8.self), pw.count,
                                 saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                 &out, out.count)
        }
        return SymmetricKey(data: out)
    }

    static func encrypt(_ plain: Data, passphrase: String) throws -> ConnectionBundle.EncryptedPasswords {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let sealed = try AES.GCM.seal(plain, using: key(passphrase, salt: salt, rounds: rounds))
        return .init(rounds: rounds, salt: salt.base64EncodedString(), data: sealed.combined!.base64EncodedString())
    }

    static func decrypt(_ enc: ConnectionBundle.EncryptedPasswords, passphrase: String) throws -> Data {
        guard let salt = Data(base64Encoded: enc.salt), let data = Data(base64Encoded: enc.data),
              let box = try? AES.GCM.SealedBox(combined: data) else {
            throw ConnectionTransferError.notGodDBFile
        }
        do {
            return try AES.GCM.open(box, using: key(passphrase, salt: salt, rounds: enc.rounds))
        } catch {
            throw ConnectionTransferError.wrongPassphrase
        }
    }
}
