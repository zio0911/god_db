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

/// 쿼리 히스토리: ~/Library/Application Support/GodDB/history.jsonl
///
/// 암호화된 줄 단위 파일 (`LocalDataCrypto` 의 `GDBENC1` 형식): 첫 줄 `GDBENC1`, 그다음 한 줄에 한 건
/// (HistoryEntry JSON 하나를 봉투 하나로). 새 기록은 줄 하나만 덧붙인다. 최근 maxEntries 건과 보관 기간(keepDays)만 유지.
///
/// - 예전 평문 파일은 처음 읽을 때 암호화해 원자적으로 바꿔 쓴다 (평문 파일은 남지 않음).
/// - 키를 못 얻으면(키체인 오류) 메모리에서만 기록하고 디스크에는 아무것도 쓰지 않는다 (평문도, 덮어쓰기도 없음).
///   나중에 키가 되면 디스크 내용과 합쳐 저장한다.
public final class QueryHistory: @unchecked Sendable {
    public static let shared = QueryHistory(file: AppPaths.dataDirectory
        .appendingPathComponent("history.jsonl"))

    /// 설정 키: 보관 일수 (0 = 영구)
    public static let keepDaysKey = "GodDB.history.keepDays"
    /// 설정 화면의 선택지 (0 = 영구)
    public static let keepDaysChoices = [7, 30, 90, 0]
    public static let defaultKeepDays = 30

    /// 설정 > 일반 > 히스토리 보관 기간 (기본 30일, 0 = 영구)
    public static var keepDays: Int {
        get { UserDefaults.standard.object(forKey: keepDaysKey) as? Int ?? defaultKeepDays }
        set { UserDefaults.standard.set(max(0, newValue), forKey: keepDaysKey) }
    }

    public let file: URL
    public let maxEntries: Int
    private let crypto: LocalDataCrypto
    private let keepDaysProvider: @Sendable () -> Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// 최신이 먼저
    private var cache: [HistoryEntry]?
    /// 키가 없어 디스크에 쓰지 못한 기록 (최신이 먼저). 키가 되면 디스크 내용과 합친다.
    private var pending: [HistoryEntry] = []
    /// 디스크를 읽거나 쓰지 못한 상태 (키 없음) — 메모리에서만 기록
    private var degraded = false
    /// 보관 기간 정리를 마지막으로 한 때 (하루 한 번)
    private var lastPrune: Date?

    public init(file: URL, maxEntries: Int = 5000, crypto: LocalDataCrypto = .shared,
                keepDays: @escaping @Sendable () -> Int = { QueryHistory.keepDays },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.maxEntries = maxEntries
        self.crypto = crypto
        self.keepDaysProvider = keepDays
        self.now = now
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
        var list = loadLocked()
        if pruneIfDueLocked(&list) {
            cache = list
            rewriteLocked(list)
        }
        return list
    }

    /// 키가 없어 메모리에서만 기록 중인지
    public var isMemoryOnly: Bool {
        lock.lock(); defer { lock.unlock() }
        return degraded
    }

    // MARK: 읽기

    private struct DiskRead {
        /// 최신이 먼저
        var entries: [HistoryEntry] = []
        var legacyPlaintext = false
        var keyUnavailable = false
        var damagedLines = 0
    }

    private func readDisk() -> DiskRead {
        var r = DiskRead()
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return r }
        if LocalDataCrypto.isEncrypted(data) {
            var list: [HistoryEntry] = []
            for line in LocalDataCrypto.bodyLines(data) {
                do {
                    let plain = try crypto.openLine(line)
                    if let e = try? Self.decoder.decode(HistoryEntry.self, from: plain) { list.append(e) } else { r.damagedLines += 1 }
                } catch LocalDataCryptoError.keyUnavailable {
                    r.keyUnavailable = true
                    return r
                } catch {
                    r.damagedLines += 1
                }
            }
            r.entries = list.reversed()
        } else {
            r.legacyPlaintext = true
            let text = String(decoding: data, as: UTF8.self)
            r.entries = text.split(whereSeparator: \.isNewline).compactMap { line in
                try? Self.decoder.decode(HistoryEntry.self, from: Data(line.utf8))
            }.reversed()
        }
        return r
    }

    private func loadLocked() -> [HistoryEntry] {
        if let cache, !degraded { return cache }
        // 메모리 상태인데 키가 아직 없으면 그대로
        if let cache, degraded, !crypto.isKeyAvailable { return cache }

        let disk = readDisk()
        if disk.keyUnavailable {
            LocalDataCrypto.log.warning("GodDB: history key unavailable, keeping history in memory only")
            degraded = true
            cache = pending
            return pending
        }
        if disk.damagedLines > 0 {
            LocalDataCrypto.log.warning("GodDB: skipped \(disk.damagedLines) unreadable history lines")
            // 한 줄도 못 읽었으면(키가 바뀜 등) 다시 쓰기 전에 옆으로 치워 둔다
            if disk.entries.isEmpty { LocalDataCrypto.moveAside(file) }
        }
        var list = pending + disk.entries
        let overflow = list.count > maxEntries
        if overflow { list = Array(list.prefix(maxEntries)) }
        let pruned = pruneIfDueLocked(&list)
        let mustRewrite = disk.legacyPlaintext || !pending.isEmpty || pruned || overflow || disk.damagedLines > 0
        cache = list
        degraded = false
        if mustRewrite {
            rewriteLocked(list)
            if disk.legacyPlaintext && degraded {
                LocalDataCrypto.log.warning("GodDB: history key unavailable, plaintext history left as is (not migrated)")
            }
        }
        return list
    }

    // MARK: 보관 기간

    /// 보관 기간이 지난 것을 뺀다 (하루에 한 번). 뺀 게 있으면 true.
    private func pruneIfDueLocked(_ list: inout [HistoryEntry], force: Bool = false) -> Bool {
        let t = now()
        if !force, let lastPrune, abs(t.timeIntervalSince(lastPrune)) < 86_400 { return false }
        lastPrune = t
        let trimmed = Self.retained(list, keepDays: keepDaysProvider(), now: t)
        guard trimmed.count != list.count else { return false }
        list = trimmed
        return true
    }

    /// keepDays 일보다 오래된 기록을 뺀다 (0 이하 = 영구)
    public static func retained(_ list: [HistoryEntry], keepDays: Int, now: Date) -> [HistoryEntry] {
        guard keepDays > 0 else { return list }
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return list.filter { $0.date >= cutoff }
    }

    /// 설정에서 보관 기간을 바꿨을 때 바로 정리
    public func applyRetentionNow() {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked()
        if pruneIfDueLocked(&list, force: true) {
            cache = list
            rewriteLocked(list)
        }
    }

    // MARK: 쓰기

    /// 파일 전체를 다시 쓴다 (원자적). 키가 없으면 쓰지 않고 메모리 상태로.
    private func rewriteLocked(_ list: [HistoryEntry]) {
        do {
            if list.isEmpty {
                try? FileManager.default.removeItem(at: file)
            } else {
                var body = LocalDataCrypto.header
                for e in list.reversed() {
                    body.append(Data(try crypto.sealLine(Self.encoder.encode(e)).utf8))
                    body.append(0x0A)
                }
                try LocalDataCrypto.writeAtomically(body, to: file)
            }
            pending = []
            degraded = false
        } catch {
            LocalDataCrypto.log.warning("GodDB: history not saved (\(error.localizedDescription, privacy: .public)), keeping it in memory")
            // pending(아직 디스크에 없는 새 기록)은 그대로 두고, 키가 되면 디스크 내용과 다시 합친다
            degraded = true
            lastPrune = nil
        }
    }

    public func append(_ entry: HistoryEntry) {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked()
        list.insert(entry, at: 0)
        var rewrite = false
        if pruneIfDueLocked(&list) { rewrite = true }
        if list.count > maxEntries {
            // 오래된 것을 잘라 파일을 다시 쓴다 (넘칠 때만, 한 번에 10% 여유)
            list = Array(list.prefix(maxEntries * 9 / 10))
            rewrite = true
        }
        cache = list
        // 디스크에 들어가기 전까지는 pending 에 둔다 (쓰기에 성공하면 비운다)
        pending.insert(entry, at: 0)
        if pending.count > maxEntries { pending.removeLast(pending.count - maxEntries) }
        if degraded { return }  // 키가 없어 디스크를 못 읽은 상태: 덮어쓰지 않고 메모리에만
        if rewrite || !FileManager.default.fileExists(atPath: file.path) {
            rewriteLocked(list)
            return
        }
        do {
            let line = try crypto.sealLine(Self.encoder.encode(entry))
            guard let handle = try? FileHandle(forWritingTo: file) else {
                rewriteLocked(list)
                return
            }
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            pending = []
        } catch {
            LocalDataCrypto.log.warning("GodDB: history entry not saved (\(error.localizedDescription, privacy: .public)), keeping it in memory")
            degraded = true
        }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file)
        cache = []
        pending = []
        degraded = false
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
/// (`GDBENC1` 통째 암호화 — 봉투 하나에 JSON 전체. 예전 평문은 처음 읽을 때 옮긴다. 나이로 지우지는 않는다)
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
    private let crypto: LocalDataCrypto

    public init(file: URL, crypto: LocalDataCrypto = .shared) {
        self.file = file
        self.crypto = crypto
    }

    public func load() -> [SavedTab] {
        guard let data = crypto.readDocumentData(at: file) else { return [] }
        return (try? JSONDecoder().decode([SavedTab].self, from: data)) ?? []
    }

    /// 암호화해서 저장. 키가 없으면 쓰지 않는다 (평문으로 쓰지 않음).
    public func save(_ tabs: [SavedTab]) {
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        do { try crypto.writeDocument(data, to: file) } catch {
            LocalDataCrypto.log.warning("GodDB: tabs not saved (\(error.localizedDescription, privacy: .public))")
        }
    }
}
