import CryptoKit
import Foundation
import os
import Security

/// 감사 로그 위변조 확인 — **파일만 있으면 어디서든 검사** 할 수 있는 방식.
/// - 줄마다 `무결성` = SHA-256(이전 줄 무결성 + 이 줄 내용) (해시 체인: 한 줄이라도 고치거나 지우거나 끼워 넣으면 그 줄부터 깨짐)
/// - 줄마다 `서명` = 이 PC 의 기기 키로 무결성 값에 전자서명 (ECDSA P-256)
///   기기 키는 가능하면 **Secure Enclave** 에 만든다 → 칩 밖으로 꺼낼 수 없어 다른 PC 에서는 서명을 만들 수 없다.
/// - 날짜 파일 첫 줄("체인")에 **검증용 공개 키** 와 이전 날짜 파일의 마지막 무결성 값을 남긴다
///   → 공개 키만으로 검사, 파일을 통째로 지우거나 바꿔도 드러남. 이전 파일 마지막 값은 시스템 로그(os_log)에도 봉인.
/// 사용자 화면에는 아무것도 안 보인다. 검사는 `GodDB --verify-audit <폴더>` (분석할 때).
/// 한계: 같은 Mac 에서 앱과 같은 키로 다시 서명하는 특수한 조작은 파일만으로는 못 막는다 (외부 저장소가 필요).
public enum AuditChain {
    public static let zero = String(repeating: "0", count: 64)
    /// 파일 머리글에 붙는 칸 이름
    public static let columns = ["무결성", "서명"]

    // MARK: 기기 서명 키

    /// 서명할 수 있는 키 (Secure Enclave 또는 소프트웨어 키)
    public struct Signer: Sendable {
        public let publicKey: P256.Signing.PublicKey
        public let kind: String
        let signFn: @Sendable (Data) throws -> P256.Signing.ECDSASignature

        public init(publicKey: P256.Signing.PublicKey, kind: String, sign: @escaping @Sendable (Data) throws -> P256.Signing.ECDSASignature) {
            self.publicKey = publicKey
            self.kind = kind
            self.signFn = sign
        }

        public func sign(_ data: Data) -> String? {
            (try? signFn(data)).map { $0.rawRepresentation.base64EncodedString() }
        }

        public var publicKeyText: String { publicKey.rawRepresentation.base64EncodedString() }

        /// 테스트용 소프트웨어 키
        public static func software(_ key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) -> Signer {
            Signer(publicKey: key.publicKey, kind: "sw") { try key.signature(for: $0) }
        }
    }

    private static let service = "GodDB-audit"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Signer?

    /// 이 PC 의 기기 키. 처음이면 만든다 (Secure Enclave 우선). 키체인을 못 쓰면 nil.
    public static func deviceSigner() -> Signer? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if SecureEnclave.isAvailable {
            if let data = load("device-key-se"), let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
                cached = Signer(publicKey: k.publicKey, kind: "se") { try k.signature(for: $0) }
                return cached
            }
            if let k = try? SecureEnclave.P256.Signing.PrivateKey(), save("device-key-se", k.dataRepresentation) {
                cached = Signer(publicKey: k.publicKey, kind: "se") { try k.signature(for: $0) }
                return cached
            }
        }
        if let data = load("device-key-sw"), let k = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            cached = .software(k)
            return cached
        }
        let k = P256.Signing.PrivateKey()
        guard save("device-key-sw", k.rawRepresentation) else { return nil }
        cached = .software(k)
        return cached
    }

    private static func load(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private static func save(_ account: String, _ data: Data) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: data,
                                kSecAttrLabel as String: "GodDB 감사 로그 기기 키",
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    // MARK: 해시

    public static func hash(prev: String, line: String) -> String {
        SHA256.hash(data: Data((prev + "\n" + line).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 파일 체인의 시작 값 (파일 이름에 묶어서 다른 날짜로 바꿔치기해도 드러나게)
    public static func seed(fileName: String) -> String { hash(prev: zero, line: "GodDB-audit|" + fileName) }

    /// 파일 첫 줄: 검증용 공개 키 + 이전 파일과의 연결 (6칸 — 무결성·서명은 쓰는 쪽에서 붙인다)
    public static func linkLine(time: String, identity: String, previousFile: String?, previousHash: String, signer: Signer) -> String {
        [time, identity, "체인", previousFile ?? "-", "key:\(signer.kind):\(signer.publicKeyText)", previousHash]
            .joined(separator: "\t")
    }

    /// 한 줄에 붙일 "무결성\t서명"
    public static func seal(prev: String, line: String, signer: Signer) -> (hash: String, suffix: String) {
        let h = hash(prev: prev, line: line)
        return (h, h + "\t" + (signer.sign(Data(h.utf8)) ?? "-"))
    }

    /// 시스템 로그(os_log)에 봉인 기록
    public static func sealToSystemLog(file: String, lastHash: String) {
        Logger(subsystem: "local.goddb.app", category: "audit")
            .notice("GodDB audit seal file=\(file, privacy: .public) last=\(lastHash, privacy: .public)")
    }

    // MARK: 검사 (파일만으로)

    public struct FileReport: Sendable, Equatable, Identifiable {
        public enum Status: Sendable, Equatable {
            case ok
            /// 몇 번째 줄(파일 기준, 머리글 = 1)부터 깨졌는지
            case broken(line: Int, reason: String)
            /// 이전 파일과 연결이 안 됨 (이전 파일이 지워졌거나 바뀜)
            case unlinked(reason: String)
            /// 무결성 칸이 없는 예전 형식
            case legacy
        }
        public var file: String
        public var lines: Int
        public var status: Status
        public var lastHash: String?
        /// 이 파일을 서명한 기기 공개 키
        public var publicKey: String?
        public var id: String { file }
    }

    /// 한 파일 검사. expectedPrevious 를 주면 첫 "체인" 줄이 그 값과 같은지도 본다.
    public static func verify(fileName: String, text: String, expectedPrevious: String?) -> FileReport {
        var rows = text.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        guard let header = rows.first else { return FileReport(file: fileName, lines: 0, status: .ok) }
        guard header.hasSuffix("\t" + columns.joined(separator: "\t")) else {
            return FileReport(file: fileName, lines: max(0, rows.count - 1), status: .legacy)
        }
        var prev = seed(fileName: fileName)
        var key: P256.Signing.PublicKey?
        var keyText: String?
        var status = FileReport.Status.ok
        let width = AuditRecord.header.count + columns.count
        // 앞 줄들의 무결성 값 (동시 쓰기 판단용)
        var seen: [String] = []
        var forks: [Int] = []
        func fail(_ line: Int, _ reason: String) -> FileReport {
            FileReport(file: fileName, lines: rows.count - 1, status: .broken(line: line, reason: reason), publicKey: keyText)
        }
        for (i, row) in rows.enumerated().dropFirst() {
            var cols = row.components(separatedBy: "\t")
            guard cols.count == width else { return fail(i + 1, "칸 수가 달라요 (\(cols.count)칸)") }
            let sig = cols.removeLast()
            let h = cols.removeLast()
            let line = cols.joined(separator: "\t")
            if i == 1 {
                // 첫 줄: 체인 시작 + 공개 키
                guard cols[2] == "체인", cols[4].hasPrefix("key:") else { return fail(2, "체인 시작 줄이 없어요") }
                let parts = cols[4].split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count == 3, let raw = Data(base64Encoded: parts[2]),
                      let k = try? P256.Signing.PublicKey(rawRepresentation: raw) else { return fail(2, "공개 키가 손상됐어요") }
                key = k
                keyText = parts[2]
            }
            var forked = false
            if h != hash(prev: prev, line: line) {
                // 앱이 동시에 두 개 켜져 각자 기억한 마지막 값에 이어 쓴 경우: 이 줄은 앞의 다른 줄 값에 이어져 있다.
                // 줄을 고치거나 지우거나 끼워 넣어서는 이렇게 되지 않으므로 "변조" 가 아니라 "의심" 으로 알린다.
                guard i > 1, seen.contains(where: { hash(prev: $0, line: line) == h }) else {
                    return fail(i + 1, i == 1 ? "첫 줄이 바뀌었어요" : "이 줄이 바뀌었거나, 앞 줄이 지워졌거나 끼워 넣어졌어요")
                }
                forked = true
            }
            guard let key, let sigData = Data(base64Encoded: sig),
                  let s = try? P256.Signing.ECDSASignature(rawRepresentation: sigData),
                  key.isValidSignature(s, for: Data(h.utf8)) else {
                return fail(i + 1, "서명이 맞지 않아요 (이 PC 의 기기 키로 쓴 줄이 아니에요)")
            }
            if forked { forks.append(i + 1) }
            seen.append(prev)
            if i == 1, let expectedPrevious, cols[5] != expectedPrevious {
                status = .unlinked(reason: "이전 파일(\(cols[3]))의 마지막 무결성 값과 달라요 — 이전 파일이 지워졌거나 바뀌었어요")
            }
            prev = h
        }
        if !forks.isEmpty {
            let lines = forks.map { "\($0)" }.joined(separator: ", ")
            let reason = "\(lines)번째 줄: 앱이 동시에 두 개 켜져 같은 파일에 썼어요 (줄 내용 · 서명은 맞아요)"
            if case .unlinked(let r) = status {
                status = .unlinked(reason: r + " / " + reason)
            } else {
                status = .unlinked(reason: reason)
            }
        }
        return FileReport(file: fileName, lines: rows.count - 1, status: status, lastHash: prev, publicKey: keyText)
    }

    /// 폴더의 감사 로그를 날짜 순으로 검사 (파일 사이 연결, 기기 키가 바뀐 곳 포함)
    public static func verify(directory: URL) -> [FileReport] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("goddb-audit-") && $0.pathExtension == "tsv" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [FileReport] = []
        var previous: FileReport?
        for f in files {
            let text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            var r = verify(fileName: f.lastPathComponent, text: text, expectedPrevious: previous?.lastHash)
            if case .ok = r.status, let p = previous?.publicKey, let k = r.publicKey, p != k {
                r.status = .unlinked(reason: "기기 키가 바뀌었어요 (다른 PC·재설치 또는 다시 만든 파일)")
            }
            out.append(r)
            previous = r
        }
        return out
    }

    /// 사람이 읽을 결과 한 줄
    public static func describe(_ r: FileReport) -> String {
        switch r.status {
        case .ok: return "정상    \(r.file) · \(r.lines)줄"
        case .broken(let line, let reason): return "변조    \(r.file) · \(line)번째 줄부터 · \(reason)"
        case .unlinked(let reason): return "의심    \(r.file) · \(reason)"
        case .legacy: return "검사불가 \(r.file) · \(r.lines)줄 · 예전 형식(무결성 칸 없음)"
        }
    }
}
