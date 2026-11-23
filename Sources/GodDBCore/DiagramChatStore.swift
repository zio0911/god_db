import CryptoKit
import Foundation

/// 다이어그램 AI 대화 하나
public struct DiagramConversation: Codable, Identifiable, Equatable, Sendable {
    public struct Message: Codable, Equatable, Sendable {
        public var role: String
        public var text: String
        public var failed: Bool
        public init(role: String, text: String, failed: Bool = false) {
            self.role = role
            self.text = text
            self.failed = failed
        }
    }

    public var id: UUID
    public var created: Date
    public var updated: Date
    public var messages: [Message]

    public init(id: UUID = UUID(), created: Date = Date(), messages: [Message] = []) {
        self.id = id
        self.created = created
        self.updated = created
        self.messages = messages
    }

    /// 목록에 보일 제목 (첫 질문 첫 줄)
    public var title: String {
        let q = messages.first { $0.role == "user" }?.text ?? ""
        let line = q.split(separator: "\n").first.map(String.init) ?? ""
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }
}

/// 다이어그램 AI 대화 기록. 다이어그램(접속 · DB · 테이블 묶음)마다 파일 하나.
///   ~/Library/Application Support/GodDB/diagram-chats/<scope 해시>.json
/// 오래 걸리는 분석을 다시 하지 않도록 남겨 두고, keepDays 가 지난 대화는 지운다.
public final class DiagramChatStore: @unchecked Sendable {
    public static let shared = DiagramChatStore(directory: AppPaths.dataDirectory
        .appendingPathComponent("diagram-chats", isDirectory: true))

    public let directory: URL
    public let keepDays: Int
    private let lock = NSLock()
    private let crypto: LocalDataCrypto

    /// 파일마다 `GDBENC1` 통째 암호화 (질문 · 답에 SQL 이 들어 있으므로). 예전 평문은 처음 읽을 때 옮긴다.
    public init(directory: URL, keepDays: Int = 90, crypto: LocalDataCrypto = .shared) {
        self.directory = directory
        self.keepDays = keepDays
        self.crypto = crypto
    }

    /// 다이어그램을 구분하는 값 (접속 id, DB, 테이블 이름들)
    public static func scope(profileID: UUID?, database: String, tables: [String]) -> String {
        "\(profileID?.uuidString ?? "-")|\(database)|\(tables.map { $0.lowercased() }.sorted().joined(separator: ","))"
    }

    func url(_ scope: String) -> URL {
        let hash = SHA256.hash(data: Data(scope.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).json")
    }

    /// 최근에 쓴 것부터. 오래된 대화는 여기서 지운다.
    public func load(_ scope: String, now: Date = Date()) -> [DiagramConversation] {
        lock.lock(); defer { lock.unlock() }
        guard let all = read(scope) else { return [] }
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
        let kept = all.filter { $0.updated >= cutoff && !$0.messages.isEmpty }
        if kept.count != all.count { write(scope, kept) }
        return kept.sorted { $0.updated > $1.updated }
    }

    public func save(_ conversation: DiagramConversation, scope: String) {
        guard !conversation.messages.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard var all = read(scope) else { return }
        if let i = all.firstIndex(where: { $0.id == conversation.id }) { all[i] = conversation } else { all.append(conversation) }
        write(scope, all)
    }

    public func delete(_ id: UUID, scope: String) {
        lock.lock(); defer { lock.unlock() }
        guard let all = read(scope) else { return }
        write(scope, all.filter { $0.id != id })
    }

    public func deleteAll(scope: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(scope))
    }

    /// 모든 다이어그램에서 오래된 대화 정리 (앱 시작 시)
    public func pruneAll(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            // 예전 평문 파일은 여기서 암호화된다 (readDocument 가 옮김)
            guard let data = crypto.readDocumentData(at: f),
                  let list = try? Self.decoder.decode([DiagramConversation].self, from: data) else { continue }
            let kept = list.filter { $0.updated >= cutoff }
            if kept.isEmpty { try? FileManager.default.removeItem(at: f) }
            else if kept.count != list.count, let d = try? Self.encoder.encode(kept) { try? crypto.writeDocument(d, to: f) }
        }
    }

    /// 대화 목록. 파일이 없으면 [], 키가 없어 못 읽으면 nil (그때는 파일을 건드리지 않는다).
    private func read(_ scope: String) -> [DiagramConversation]? {
        switch crypto.readDocument(at: url(scope)) {
        case .missing, .damaged: return []
        case .keyUnavailable: return nil
        case .decrypted(let data), .plaintext(let data):
            return (try? Self.decoder.decode([DiagramConversation].self, from: data)) ?? []
        }
    }

    private func write(_ scope: String, _ list: [DiagramConversation]) {
        if list.isEmpty { try? FileManager.default.removeItem(at: url(scope)); return }
        guard let data = try? Self.encoder.encode(list) else { return }
        do { try crypto.writeDocument(data, to: url(scope)) } catch {
            LocalDataCrypto.log.warning("GodDB: AI chat not saved (\(error.localizedDescription, privacy: .public))")
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
