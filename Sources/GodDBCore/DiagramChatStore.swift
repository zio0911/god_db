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
    public static let shared = DiagramChatStore(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GodDB/diagram-chats", isDirectory: true))

    public let directory: URL
    public let keepDays: Int
    private let lock = NSLock()

    public init(directory: URL, keepDays: Int = 90) {
        self.directory = directory
        self.keepDays = keepDays
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
        let all = read(scope)
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
        let kept = all.filter { $0.updated >= cutoff && !$0.messages.isEmpty }
        if kept.count != all.count { write(scope, kept) }
        return kept.sorted { $0.updated > $1.updated }
    }

    public func save(_ conversation: DiagramConversation, scope: String) {
        guard !conversation.messages.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var all = read(scope)
        if let i = all.firstIndex(where: { $0.id == conversation.id }) { all[i] = conversation } else { all.append(conversation) }
        write(scope, all)
    }

    public func delete(_ id: UUID, scope: String) {
        lock.lock(); defer { lock.unlock() }
        write(scope, read(scope).filter { $0.id != id })
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
            guard let data = try? Data(contentsOf: f), let list = try? Self.decoder.decode([DiagramConversation].self, from: data) else { continue }
            let kept = list.filter { $0.updated >= cutoff }
            if kept.isEmpty { try? FileManager.default.removeItem(at: f) }
            else if kept.count != list.count, let d = try? Self.encoder.encode(kept) { try? d.write(to: f, options: .atomic) }
        }
    }

    private func read(_ scope: String) -> [DiagramConversation] {
        guard let data = try? Data(contentsOf: url(scope)) else { return [] }
        return (try? Self.decoder.decode([DiagramConversation].self, from: data)) ?? []
    }

    private func write(_ scope: String, _ list: [DiagramConversation]) {
        let fm = FileManager.default
        if list.isEmpty { try? fm.removeItem(at: url(scope)); return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(list) else { return }
        try? data.write(to: url(scope), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(scope).path)
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
