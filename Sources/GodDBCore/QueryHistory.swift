import Foundation

/// 실행한 SQL 한 건
public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var date: Date
    public var profileID: UUID
    public var profileName: String
    public var database: String
    public var sql: String
    public var elapsedMs: Int
    public var ok: Bool
    /// 결과 행 수 또는 영향 받은 행 요약 (없으면 nil)
    public var summary: String?

    public init(date: Date = Date(), profileID: UUID, profileName: String, database: String,
                sql: String, elapsedMs: Int, ok: Bool, summary: String? = nil) {
        self.date = date
        self.profileID = profileID
        self.profileName = profileName
        self.database = database
        self.sql = sql
        self.elapsedMs = elapsedMs
        self.ok = ok
        self.summary = summary
    }
}

/// 쿼리 히스토리: ~/Library/Application Support/GodDB/history.jsonl (한 줄에 한 건, 최근 maxEntries 건만 유지)
public final class QueryHistory: @unchecked Sendable {
    public static let shared = QueryHistory(file: AppPaths.dataDirectory
        .appendingPathComponent("history.jsonl"))

    public let file: URL
    public let maxEntries: Int
    private let lock = NSLock()
    private var cache: [HistoryEntry]?

    public init(file: URL, maxEntries: Int = 5000) {
        self.file = file
        self.maxEntries = maxEntries
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// 최신이 먼저
    public func all() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> [HistoryEntry] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
            cache = []
            return []
        }
        let list = text.split(separator: "\n").compactMap { line in
            try? Self.decoder.decode(HistoryEntry.self, from: Data(line.utf8))
        }
        cache = Array(list.reversed().prefix(maxEntries))
        return cache!
    }

    public func append(_ entry: HistoryEntry) {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked()
        list.insert(entry, at: 0)
        guard let line = try? Self.encoder.encode(entry) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if list.count > maxEntries {
            // 오래된 것을 잘라 파일을 다시 쓴다 (넘칠 때만, 한 번에 10% 여유)
            list = Array(list.prefix(maxEntries * 9 / 10))
            let body = list.reversed().compactMap { try? Self.encoder.encode($0) }
                .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
            try? Data(body.utf8).write(to: file, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (line + Data("\n".utf8)).write(to: file, options: .atomic)
        }
        cache = list
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file)
        cache = []
    }

    /// 검색어(공백으로 나눈 모든 단어 포함, 대소문자 무시)와 접속으로 거른다
    public static func filter(_ list: [HistoryEntry], query: String, profileID: UUID?) -> [HistoryEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return list.filter { e in
            (profileID == nil || e.profileID == profileID)
                && words.allSatisfy { e.sql.lowercased().contains($0) || e.database.lowercased().contains($0) }
        }
    }
}

/// 쿼리 탭 자동 저장: ~/Library/Application Support/GodDB/tabs.json
public struct SavedTab: Codable, Sendable, Equatable {
    public var profileID: UUID
    public var database: String
    public var number: Int
    public var title: String?
    public var text: String
    public var selected: Bool

    public init(profileID: UUID, database: String, number: Int, title: String?, text: String, selected: Bool) {
        self.profileID = profileID
        self.database = database
        self.number = number
        self.title = title
        self.text = text
        self.selected = selected
    }
}

public struct TabStore: Sendable {
    public static let shared = TabStore(file: AppPaths.dataDirectory
        .appendingPathComponent("tabs.json"))

    public let file: URL

    public init(file: URL) { self.file = file }

    public func load() -> [SavedTab] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([SavedTab].self, from: data)) ?? []
    }

    public func save(_ tabs: [SavedTab]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(tabs) { try? data.write(to: file, options: .atomic) }
    }
}
