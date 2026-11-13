import GodDBCore
import Observation
import SwiftUI

/// Redis 접속 하나의 화면 상태 (키 목록, 선택한 키, 콘솔, Pub/Sub, Streams, 서버 정보)
@MainActor
@Observable
final class RedisWorkspace {
    enum Tab: String, CaseIterable, Identifiable {
        case keys, console, pubsub, streams, info
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keys: return tr("키")
            case .console: return "Workbench"
            case .pubsub: return "Pub/Sub"
            case .streams: return "Streams"
            case .info: return tr("서버 정보")
            }
        }
        var icon: String {
            switch self {
            case .keys: return "key"
            case .console: return "terminal"
            case .pubsub: return "dot.radiowaves.left.and.right"
            case .streams: return "list.bullet.rectangle"
            case .info: return "info.circle"
            }
        }
    }

    enum Value {
        case string(String)
        case hash([(String, String)])
        case list([String], total: Int)
        case set([String])
        case zset([(String, String)], total: Int)
        case stream([RedisStreamEntry])
        case other(String)
    }

    struct DB: Identifiable, Hashable { var id: Int { index }; let index: Int; let keys: Int }

    struct ConsoleEntry: Identifiable {
        let id = UUID()
        let command: String
        let output: String
        let isError: Bool
        let millis: Int
        let db: Int
    }

    let profileID: UUID
    let session: RedisSession
    weak var app: AppState?
    var tab: Tab = .keys
    /// 새 키 창
    var showNewKey = false

    // DB
    var databases: [DB] = []
    var db = 0

    // 키 목록
    var pattern = "*"
    var typeFilter = ""
    var keys: [String] = [] { didSet { rebuildTree() } }
    var nextCursor: String?

    // 키 트리 (구분자로 폴더처럼)
    static let treeModeKey = "GodDB.redis.treeMode"
    static let delimiterKey = "GodDB.redis.delimiter"
    var treeMode: Bool = UserDefaults.standard.object(forKey: RedisWorkspace.treeModeKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(treeMode, forKey: Self.treeModeKey) }
    }
    var delimiter: String = UserDefaults.standard.string(forKey: RedisWorkspace.delimiterKey) ?? ":" {
        didSet { UserDefaults.standard.set(delimiter, forKey: Self.delimiterKey); rebuildTree() }
    }
    private(set) var tree: [RedisKeyNode] = []
    /// 펼친 폴더 id
    var expanded: Set<String> = []

    /// 목록에 보일 키의 타입·TTL (보일 때 묶어서 가져온다)
    struct KeyMeta { let type: String; let ttlMillis: Int; let fetched: Date }
    var meta: [String: KeyMeta] = [:]
    private var metaWanted: Set<String> = []
    private var metaTask: Task<Void, Never>?

    /// 행이 화면에 나타날 때 호출. 잠깐 모았다가 한 번에 조회한다.
    func wantMeta(_ key: String) {
        guard meta[key] == nil else { return }
        metaWanted.insert(key)
        guard metaTask == nil else { return }
        metaTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            while !self.metaWanted.isEmpty {
                let batch = Array(self.metaWanted.prefix(300))
                self.metaWanted.subtract(batch)
                guard let r = try? await self.session.keyMeta(batch) else { break }
                let now = Date()
                for (k, v) in r { self.meta[k] = KeyMeta(type: v.type, ttlMillis: v.ttlMillis, fetched: now) }
            }
            self.metaTask = nil
        }
    }

    /// 지금 시점의 남은 TTL (밀리초, -1 만료 없음, -2 없음)
    func remainingTTL(_ key: String) -> Int? {
        guard let m = meta[key] else { return nil }
        guard m.ttlMillis >= 0 else { return m.ttlMillis }
        return max(0, m.ttlMillis - Int(Date().timeIntervalSince(m.fetched) * 1000))
    }

    // 자동 새로고침
    static let autoRefreshSecondsKey = "GodDB.redis.autoRefreshSeconds"
    private(set) var autoRefresh = false
    private(set) var autoRefreshSeconds: Int = max(1, UserDefaults.standard.object(forKey: RedisWorkspace.autoRefreshSecondsKey) as? Int ?? 5)
    private var autoTask: Task<Void, Never>?
    private var refreshing = false

    func setAutoRefresh(_ on: Bool) {
        autoRefresh = on
        autoTask?.cancel()
        autoTask = nil
        guard on else { return }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = self?.autoRefreshSeconds ?? 5
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                await self.refreshAll(quiet: true)
            }
        }
    }

    func setAutoRefreshSeconds(_ s: Int) {
        autoRefreshSeconds = min(3600, max(1, s))
        UserDefaults.standard.set(autoRefreshSeconds, forKey: Self.autoRefreshSecondsKey)
        if autoRefresh { setAutoRefresh(true) }   // 새 간격으로 다시 시작
    }

    /// 키 목록·TTL·열린 값을 다시 읽는다 (펼친 폴더와 선택은 유지)
    func refreshAll(quiet: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if !quiet { await loadDatabases() }
        let loaded = max(keys.count, 1000)
        do {
            let r = try await session.scanKeys(pattern: pattern, type: typeFilter.isEmpty ? nil : typeFilter, limit: loaded)
            meta = [:]
            keys = r.keys.sorted()
            nextCursor = r.next
        } catch {
            if !quiet { app?.logError(error, .schema, context: tr("[%@] 키 조회 실패", name)) }
            if quiet { setAutoRefresh(false) }   // 연결이 끊겼으면 자동 새로고침을 멈춘다
            return
        }
        if selectedKey != nil, tab == .keys { await reloadValue() }
    }

    private func rebuildTree() {
        tree = RedisKeyTree.build(keys, delimiter: delimiter)
    }

    /// 폴더 아래 키만 다시 검색
    func searchFolder(_ path: String) async {
        pattern = RedisKeyTree.pattern(forFolder: path, delimiter: delimiter)
        await reloadKeys()
        // 검색한 폴더까지 펼쳐 둔다
        var prefix = ""
        for part in path.components(separatedBy: delimiter) {
            prefix = prefix.isEmpty ? part : prefix + delimiter + part
            expanded.insert("f:" + prefix)
        }
    }
    var loadingKeys = false

    // 선택한 키
    var selectedKey: String?
    var keyInfo: RedisKeyInfo?
    var value: Value?
    var loadingValue = false
    var valueError: String?
    var listPageSize = 500

    // 콘솔
    var console: [ConsoleEntry] = []
    var history: [String] = []
    var consoleRunning = false
    /// 위험한 명령 확인 대기
    var pendingDangerous: [String]?
    /// Workbench 편집기 글 (접속마다 기억)
    var workbench: String = "" {
        didSet { UserDefaults.standard.set(workbench, forKey: "GodDB.redis.workbench." + profileID.uuidString) }
    }
    /// 위험한 명령이 섞인 실행 확인 대기
    var pendingScript: [String]?

    // Pub/Sub
    var subscriber: RedisSubscriber?
    private var subscriberTask: Task<Void, Never>?
    var channels: [String] = []
    var patterns: [String] = []
    var messages: [RedisPubSubMessage] = []
    var pubsubPaused = false
    var activeChannels: [(String, Int)] = []

    // Streams
    var streamKeys: [String] = []
    var stream: String?
    var streamEntries: [RedisStreamEntry] = []
    var streamHasMore = false
    var streamInfo: [(String, String)] = []
    var groups: [RedisStreamGroup] = []
    var group: String?
    var consumers: [RedisStreamConsumer] = []
    var pending: [RedisPendingEntry] = []
    var tailing = false
    private var tailTask: Task<Void, Never>?
    var streamError: String?

    // 서버 정보
    var info: [(String, [(String, String)])] = []
    /// Cluster / Sentinel 표시 ("Cluster · 마스터 3개")
    var topologyText = ""
    /// Cluster 마스터 노드들 (서버 정보에서 노드 고르기)
    var nodes: [String] = []
    var infoNode: String?

    init(profileID: UUID, session: RedisSession, app: AppState) {
        self.profileID = profileID
        self.session = session
        self.app = app
        workbench = UserDefaults.standard.string(forKey: "GodDB.redis.workbench." + profileID.uuidString)
            ?? "// 한 줄에 명령 하나. ⌘↩ 실행 (선택 영역이 있으면 그 줄만)\n// 예: RPUSH queue:mail m1 m2\nPING\n"
    }

    /// Workbench: 여러 줄을 차례로 실행. 위험한 명령이 있으면 먼저 확인한다.
    func runScript(_ text: String, confirmed: Bool = false) async {
        let lines = RedisText.scriptLines(text)
        guard !lines.isEmpty else { return }
        if !confirmed, lines.contains(where: { RedisText.splitArgs($0).map(RedisCommands.isDangerous) ?? false }) {
            pendingScript = lines
            return
        }
        for line in lines {
            await runConsole(line, confirmed: true)
        }
    }

    var name: String { session.profile.name }
    var readOnly: Bool { session.profile.readOnly }

    func close() async {
        autoTask?.cancel()
        tailTask?.cancel()
        subscriberTask?.cancel()
        await subscriber?.close()
        subscriber = nil
    }

    // MARK: - 공통

    static func display(_ args: [String]) -> String {
        args.map { a in
            a.isEmpty || a.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
                ? "\"" + a.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n") + "\""
                : a
        }.joined(separator: " ")
    }

    /// 쓰기 명령: 실행하고 상태창(로그 파일)에 남긴다. 실패하면 메시지를 돌려준다.
    @discardableResult
    func write(_ args: [String], label: String) async -> String? {
        do {
            let start = Date()
            try await session.command(args)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            app?.log(.success, .query, "[\(name) db\(db)] \(label) · \(ms)ms", detail: Self.display(args),
                     audit: AuditRecord(AuditRecord.classify(redis: args), target: auditTarget, result: "\(label) · \(ms)ms",
                                        statement: Self.display(args)))
            return nil
        } catch {
            return app?.logError(error, .query, context: "[\(name)] \(label)", sql: Self.display(args),
                                 audit: AuditRecord(AuditRecord.classify(redis: args), target: auditTarget,
                                                    statement: Self.display(args))) ?? error.localizedDescription
        }
    }

    // MARK: - DB

    func loadDatabases() async {
        do {
            let list = try await session.databases()
            databases = list.map { DB(index: $0.index, keys: $0.keys) }
            db = await session.db
        } catch {
            app?.logError(error, .schema, context: tr("%@ DB 목록 조회 실패", name))
        }
    }

    func selectDB(_ index: Int) async {
        guard index != db else { return }
        do {
            try await session.select(index)
            db = index
            selectedKey = nil
            keyInfo = nil
            value = nil
            stream = nil
            stopTail()
            await reloadKeys()
            if tab == .streams { await loadStreamKeys() }
        } catch {
            app?.logError(error, .schema, context: tr("%@ DB 전환 실패", name))
        }
    }

    // MARK: - 키 목록

    func reloadKeys() async {
        meta = [:]
        keys = []
        nextCursor = nil
        await loadMoreKeys(from: "0")
    }

    func loadMoreKeys(from cursor: String? = nil) async {
        guard let cur = cursor ?? nextCursor, !loadingKeys else { return }
        loadingKeys = true
        defer { loadingKeys = false }
        do {
            let start = Date()
            let r = try await session.scanKeys(pattern: pattern, type: typeFilter.isEmpty ? nil : typeFilter, from: cur, limit: 1000)
            var seen = Set(keys)
            keys += r.keys.filter { seen.insert($0).inserted }
            keys.sort()
            nextCursor = r.next
            app?.log(.info, .schema, tr("[%@ db%@] 키 %@개 · 패턴 %@ · %@ms", name, "\(db)", "\(keys.count)", pattern,
                                        "\(Int(Date().timeIntervalSince(start) * 1000))") + (r.next != nil ? tr(" · 더 있음") : ""))
        } catch {
            app?.logError(error, .schema, context: tr("[%@] 키 조회 실패", name))
        }
    }

    // MARK: - 선택한 키

    func open(_ key: String) async {
        selectedKey = key
        tab = .keys
        await reloadValue()
        // 감사 로그: 키 값을 열어 본 것 (자동 새로고침으로 다시 읽는 건 남기지 않음)
        if valueError == nil {
            LogFile.shared.append(LogEntry(level: .info, source: .query, message: "",
                audit: AuditRecord(.read, target: auditTarget, result: "키 열기 · \(keyInfo?.type ?? "?")", statement: "GET " + key)))
        }
    }

    /// 감사 로그 대상 칸
    var auditTarget: String { "\(name) db\(db)" }

    func reloadValue() async {
        guard let key = selectedKey else { return }
        loadingValue = true
        valueError = nil
        defer { loadingValue = false }
        do {
            let info = try await session.keyInfo(key)
            keyInfo = info
            meta[key] = KeyMeta(type: info.type, ttlMillis: info.ttlMillis, fetched: Date())
            switch info.type {
            case "string": value = .string(try await session.string(key) ?? "")
            case "hash": value = .hash(try await session.hash(key).sorted { $0.0 < $1.0 })
            case "list": value = .list(try await session.list(key, start: 0, count: listPageSize), total: info.length ?? 0)
            case "set": value = .set(try await session.set(key).sorted())
            case "zset": value = .zset(try await session.zset(key, start: 0, count: listPageSize, reverse: true), total: info.length ?? 0)
            case "stream": value = .stream(try await session.streamLatest(key, count: 200))
            case "none":
                value = nil
                valueError = tr("키가 없어요. (지워졌거나 만료됨)")
            default: value = .other(info.type)
            }
        } catch {
            value = nil
            valueError = app?.logError(error, .query, context: tr("[%@] 값 조회 실패", name)) ?? error.localizedDescription
        }
    }

    /// 쓰기 후 값 다시 읽기
    func apply(_ args: [String], label: String) async -> String? {
        let e = await write(args, label: label)
        await reloadValue()
        return e
    }

    func deleteKey(_ key: String) async {
        if await write(["DEL", key], label: tr("키 삭제 %@", key)) == nil {
            keys.removeAll { $0 == key }
            if selectedKey == key { selectedKey = nil; keyInfo = nil; value = nil }
        }
    }

    func renameKey(_ key: String, to newName: String) async -> String? {
        if let e = await write(["RENAME", key, newName], label: tr("키 이름 변경 %@ → %@", key, newName)) { return e }
        if let i = keys.firstIndex(of: key) { keys[i] = newName; keys.sort() }
        selectedKey = newName
        await reloadValue()
        return nil
    }

    /// seconds 가 nil 이면 만료 없앰
    func setTTL(_ key: String, seconds: Int?) async -> String? {
        if let s = seconds {
            return await apply(["EXPIRE", key, String(s)], label: tr("만료 설정 %@ · %@초", key, "\(s)"))
        }
        return await apply(["PERSIST", key], label: tr("만료 없앰 %@", key))
    }

    /// 새 키 만들기
    func create(type: String, key: String, field: String, value: String, ttl: Int?) async -> String? {
        let args: [String]
        switch type {
        case "hash": args = ["HSET", key, field, value]
        case "list": args = ["RPUSH", key, value]
        case "set": args = ["SADD", key, value]
        case "zset": args = ["ZADD", key, field.isEmpty ? "0" : field, value]
        case "stream": args = ["XADD", key, "*", field.isEmpty ? "value" : field, value]
        default: args = ["SET", key, value]
        }
        if let e = await write(args, label: tr("새 키 %@ (%@)", key, type)) { return e }
        if let ttl, ttl > 0 { await write(["EXPIRE", key, String(ttl)], label: tr("만료 설정 %@ · %@초", key, "\(ttl)")) }
        if !keys.contains(key) { keys.append(key); keys.sort() }
        await open(key)
        return nil
    }

    func loadMoreList() async {
        guard let key = selectedKey, case .list(let items, let total) = value, items.count < total else { return }
        do {
            let more = try await session.list(key, start: items.count, count: listPageSize)
            value = .list(items + more, total: total)
        } catch {
            valueError = app?.logError(error, .query, context: tr("[%@] 값 조회 실패", name))
        }
    }

    func loadMoreZset() async {
        guard let key = selectedKey, case .zset(let items, let total) = value, items.count < total else { return }
        do {
            let more = try await session.zset(key, start: items.count, count: listPageSize, reverse: true)
            value = .zset(items + more, total: total)
        } catch {
            valueError = app?.logError(error, .query, context: tr("[%@] 값 조회 실패", name))
        }
    }

    // MARK: - 콘솔

    func runConsole(_ line: String, confirmed: Bool = false) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let args = RedisText.splitArgs(trimmed), !args.isEmpty else {
            console.append(.init(command: trimmed, output: tr("따옴표가 닫히지 않았어요."), isError: true, millis: 0, db: db))
            return
        }
        if history.last != trimmed { history.append(trimmed) }
        if history.count > 500 { history.removeFirst(history.count - 500) }
        if !confirmed && RedisCommands.isDangerous(args) {
            pendingDangerous = args
            return
        }
        consoleRunning = true
        defer { consoleRunning = false }
        let start = Date()
        let usedDB = db
        do {
            let v = try await session.console(args)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            var isError = false
            if case .error = v { isError = true }
            console.append(.init(command: trimmed, output: v.formatted(), isError: isError, millis: ms, db: usedDB))
            db = await session.db
            let record = AuditRecord(AuditRecord.classify(redis: args), target: "\(name) db\(usedDB)",
                                     result: isError ? "실패: " + v.formatted().prefix(200) : "Workbench · \(ms)ms", statement: trimmed)
            if isError {
                app?.log(.warning, .query, "[\(name) db\(usedDB)] \(trimmed.prefix(120))", detail: v.formatted(), audit: record)
            } else {
                app?.log(.success, .query, "[\(name) db\(usedDB)] \(trimmed.prefix(120)) · \(ms)ms", detail: trimmed, audit: record)
            }
            if !RedisCommands.isReadOnly(args), let key = selectedKey, args.contains(key) { await reloadValue() }
        } catch {
            let msg = app?.logError(error, .query, context: "[\(name)] \(args[0].uppercased())", sql: trimmed,
                                    audit: AuditRecord(AuditRecord.classify(redis: args), target: "\(name) db\(usedDB)",
                                                       statement: trimmed)) ?? error.localizedDescription
            console.append(.init(command: trimmed, output: msg, isError: true, millis: 0, db: usedDB))
        }
        if console.count > 1000 { console.removeFirst(console.count - 1000) }
    }

    // MARK: - Pub/Sub

    private func ensureSubscriber() async throws -> RedisSubscriber {
        if let subscriber { return subscriber }
        let s = try await session.subscriber()
        subscriber = s
        subscriberTask = Task { [weak self] in
            for await m in s.messages {
                guard let self else { return }
                if self.pubsubPaused && (m.kind == "message" || m.kind == "pmessage") { continue }
                self.messages.append(m)
                if self.messages.count > 5000 { self.messages.removeFirst(self.messages.count - 5000) }
            }
            // 연결이 끊김
            guard let self else { return }
            if self.subscriber === s {
                self.subscriber = nil
                self.channels = []
                self.patterns = []
            }
        }
        return s
    }

    /// "news, evt:*" → 채널과 패턴으로 나눠 구독
    func subscribe(_ text: String) async {
        let items = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !items.isEmpty else { return }
        do {
            let s = try await ensureSubscriber()
            let pats = items.filter { $0.contains("*") || $0.contains("?") || $0.contains("[") }
            let chans = items.filter { !pats.contains($0) }
            s.subscribe(chans.filter { !channels.contains($0) })
            s.psubscribe(pats.filter { !patterns.contains($0) })
            channels += chans.filter { !channels.contains($0) }
            patterns += pats.filter { !patterns.contains($0) }
            app?.log(.info, .query, tr("[%@] 구독 · %@", name, items.joined(separator: ", ")),
                     audit: AuditRecord(.read, target: auditTarget, result: "구독", statement: "SUBSCRIBE " + items.joined(separator: " ")))
        } catch {
            app?.logError(error, .query, context: tr("[%@] 구독 실패", name))
        }
    }

    func unsubscribe(_ item: String) {
        if channels.contains(item) {
            subscriber?.unsubscribe([item])
            channels.removeAll { $0 == item }
        } else {
            subscriber?.punsubscribe([item])
            patterns.removeAll { $0 == item }
        }
    }

    func unsubscribeAll() async {
        subscriberTask?.cancel()
        await subscriber?.close()
        subscriber = nil
        channels = []
        patterns = []
    }

    func publish(channel: String, message: String) async -> String? {
        do {
            let n = try await session.publish(channel, message)
            app?.log(.success, .query, tr("[%@] PUBLISH %@ · 받은 구독자 %@명", name, channel, "\(n)"),
                     detail: Self.display(["PUBLISH", channel, message]),
                     audit: AuditRecord(.execute, target: auditTarget, result: "구독자 \(n)명",
                                        statement: Self.display(["PUBLISH", channel, message])))
            return nil
        } catch {
            return app?.logError(error, .query, context: tr("[%@] PUBLISH 실패", name), sql: Self.display(["PUBLISH", channel, message]))
        }
    }

    func loadActiveChannels() async {
        do { activeChannels = try await session.activeChannels() } catch {
            app?.logError(error, .query, context: tr("[%@] 활성 채널 조회 실패", name))
        }
    }

    // MARK: - Streams

    func loadStreamKeys() async {
        do {
            streamKeys = try await session.scanKeys(pattern: "*", type: "stream", limit: 2000).keys.sorted()
            if stream == nil, let first = streamKeys.first { await openStream(first) }
        } catch {
            streamError = app?.logError(error, .query, context: tr("[%@] 스트림 목록 조회 실패", name))
        }
    }

    func openStream(_ key: String) async {
        if stream != key { stopTail() }
        stream = key
        tab = .streams
        await reloadStream()
    }

    func reloadStream() async {
        guard let key = stream else { return }
        streamError = nil
        do {
            streamEntries = try await session.streamLatest(key, count: 200)
            streamHasMore = streamEntries.count == 200
            streamInfo = try await session.streamInfo(key)
            groups = try await session.streamGroups(key)
            if let g = group, !groups.contains(where: { $0.name == g }) { group = nil }
            if group == nil { group = groups.first?.name }
            await reloadGroup()
        } catch {
            streamError = app?.logError(error, .query, context: tr("[%@] 스트림 조회 실패", name))
        }
    }

    func loadOlderStream() async {
        guard let key = stream, let last = streamEntries.last else { return }
        do {
            let more = try await session.streamLatest(key, count: 200, before: last.id)
            streamEntries += more
            streamHasMore = more.count == 200
        } catch {
            streamError = app?.logError(error, .query, context: tr("[%@] 스트림 조회 실패", name))
        }
    }

    func reloadGroup() async {
        guard let key = stream, let g = group else { consumers = []; pending = []; return }
        do {
            consumers = try await session.streamConsumers(key, group: g)
            pending = try await session.streamPending(key, group: g)
        } catch {
            streamError = app?.logError(error, .query, context: tr("[%@] 소비자 그룹 조회 실패", name))
        }
    }

    func streamWrite(_ args: [String], label: String) async -> String? {
        let e = await write(args, label: label)
        await reloadStream()
        return e
    }

    func toggleTail() {
        if tailing { stopTail(); return }
        guard let key = stream else { return }
        tailing = true
        tailTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await e in try await self.session.streamTail(key) {
                    if self.streamEntries.contains(where: { $0.id == e.id }) { continue }
                    self.streamEntries.insert(e, at: 0)
                    if self.streamEntries.count > 5000 { self.streamEntries.removeLast(self.streamEntries.count - 5000) }
                }
            } catch {
                self.streamError = self.app?.logError(error, .query, context: tr("[%@] 실시간 보기 실패", self.name))
            }
            self.tailing = false
        }
    }

    func stopTail() {
        tailTask?.cancel()
        tailTask = nil
        tailing = false
    }

    // MARK: - 서버 정보

    func loadTopology() async {
        topologyText = await session.topologyText
        nodes = await session.masterNodes
    }

    func loadInfo() async {
        do { info = try await session.info(node: nodes.count > 1 ? (infoNode ?? nodes.first) : nil) } catch {
            app?.logError(error, .schema, context: tr("[%@] INFO 조회 실패", name))
        }
    }
}

extension AppState {
    var selectedRedis: RedisWorkspace? {
        selectedProfileID.flatMap { redisWorkspaces[$0] }
    }

    func connectRedis(_ profile: ConnectionProfile, password: String?, route: String = "") async {
        let id = profile.id
        do {
            let s = try await RedisSession.connect(profile: profile, password: password)
            let ws = RedisWorkspace(profileID: id, session: s, app: self)
            await ws.loadTopology()
            redisWorkspaces[id] = ws
            updateConnection(id) { $0.state = .connected }
            let version = (try? await s.info("server").first?.1.first { $0.0 == "redis_version" }?.1) ?? ""
            log(.success, .connection, tr("%@ 연결됨", "\(profile.name)") + " · Redis \(version) · db\(await s.db)"
                + (ws.topologyText.isEmpty ? "" : " · " + ws.topologyText)
                + (profile.readOnly ? tr(" (읽기전용)") : ""),
                detail: ws.nodes.count > 1 ? "nodes: " + ws.nodes.joined(separator: ", ") : nil,
                audit: AuditRecord(.connect, target: profile.name,
                                   result: "성공 · Redis \(version)" + (ws.topologyText.isEmpty ? "" : " · " + ws.topologyText)
                                       + (profile.readOnly ? " (읽기전용)" : ""),
                                   statement: route))
            await ws.loadDatabases()
            await ws.reloadKeys()
        } catch {
            let message = logError(error, .connection, context: tr("%@ 연결 실패", "\(profile.name)"),
                                   audit: AuditRecord(.connect, target: profile.name, statement: route))
            updateConnection(id) { $0.state = .failed(message) }
            if ErrorText.isAuthFailure(error) {
                sessionPasswords[id] = nil
                passwordPrompt = PasswordPrompt(profile: profile, message: tr("비밀번호가 틀렸어요. 다시 입력해 주세요."))
            }
        }
    }

    func disconnectRedis(_ id: UUID) async {
        guard let ws = redisWorkspaces[id] else { return }
        await ws.close()
        await ws.session.close()
        redisWorkspaces[id] = nil
        log(.info, .connection, tr("%@ 연결 끊음", ws.name), audit: AuditRecord(.disconnect, target: ws.name))
    }
}
