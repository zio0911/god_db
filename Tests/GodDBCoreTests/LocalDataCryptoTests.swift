import CryptoKit
import Foundation
import Testing
@testable import GodDBCore

/// 로컬 데이터 암호화 (GDBENC1). 실제 키체인 · 앱 데이터 폴더는 건드리지 않는다 (메모리 키 + 임시 폴더).
@Suite("LocalDataCrypto")
struct LocalDataCryptoTests {
    let crypto = LocalDataCrypto(provider: StaticLocalDataKeyProvider())

    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-enc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func entry(_ sql: String, daysAgo: Double = 0, now: Date = Date()) -> HistoryEntry {
        HistoryEntry(date: now.addingTimeInterval(-daysAgo * 86_400), profileID: UUID(), profileName: "p", database: "shop",
                     sql: sql, elapsedMs: 1, ok: true)
    }

    func contains(_ data: Data, _ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }

    static let secretSQL = "SELECT * FROM member WHERE phone = '010-1234-5678'"

    // MARK: 봉투

    @Test func sharedUsesMemoryKeyInTests() {
        // 단위 테스트에서 .shared 가 실제 키체인을 쓰지 않는다
        #expect(LocalDataCrypto.isTestProcess)
    }

    @Test func roundTrip() throws {
        let plain = Data(Self.secretSQL.utf8)
        let sealed = try crypto.seal(plain)
        #expect(sealed.count == plain.count + 12 + 16)
        #expect(try crypto.open(sealed) == plain)
        // 같은 내용도 nonce 가 달라 매번 다르다
        #expect(try crypto.seal(plain) != sealed)

        let doc = try crypto.encryptDocument(plain)
        #expect(doc.starts(with: Data("GDBENC1\n".utf8)))
        #expect(doc.last == 0x0A)
        #expect(try crypto.decryptDocument(doc) == plain)

        let s = try crypto.sealString("RPUSH q 1")
        #expect(s.hasPrefix("GDBENC1:"))
        #expect(try crypto.openString(s) == "RPUSH q 1")
        #expect(try crypto.openString("평문 그대로") == "평문 그대로")
    }

    @Test func tamperingIsDetected() throws {
        var sealed = try crypto.seal(Data(Self.secretSQL.utf8))
        sealed[sealed.count / 2] ^= 0x01
        #expect(throws: LocalDataCryptoError.authenticationFailed) { try crypto.open(sealed) }
        // 다른 키
        let other = LocalDataCrypto(provider: StaticLocalDataKeyProvider())
        let good = try crypto.seal(Data("x".utf8))
        #expect(throws: LocalDataCryptoError.authenticationFailed) { try other.open(good) }
        // 모양이 틀림
        #expect(throws: LocalDataCryptoError.malformed) { try crypto.openLine("not base64 !!") }
        #expect(throws: LocalDataCryptoError.malformed) { try crypto.open(Data([1, 2, 3])) }
        // 키 없음
        let none = LocalDataCrypto(provider: UnavailableLocalDataKeyProvider())
        #expect(throws: LocalDataCryptoError.self) { try none.seal(Data("x".utf8)) }
    }

    @Test func tamperedDocumentIsMovedAsideNotDeleted() throws {
        let file = tempDir().appendingPathComponent("tabs.json")
        try crypto.writeDocument(Data("[]".utf8), to: file)
        var raw = try Data(contentsOf: file)
        raw[raw.count - 5] = raw[raw.count - 5] == 0x41 ? 0x42 : 0x41
        try raw.write(to: file)
        #expect(crypto.readDocument(at: file) == .damaged)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: file.path + ".undecryptable"))
    }

    // MARK: 평문 → 암호화

    @Test func migratesPlaintextDocument() throws {
        let file = tempDir().appendingPathComponent("tabs.json")
        let tabs = [SavedTab(profileID: UUID(), database: "shop", number: 1, title: nil, text: Self.secretSQL, selected: true)]
        try JSONEncoder().encode(tabs).write(to: file)

        let store = TabStore(file: file, crypto: crypto)
        #expect(store.load() == tabs)
        let raw = try Data(contentsOf: file)
        #expect(LocalDataCrypto.isEncrypted(raw))
        #expect(!contains(raw, "010-1234-5678"))
        #expect(store.load() == tabs)
    }

    @Test func plaintextKeptWhenKeyUnavailable() throws {
        let dir = tempDir()
        let tabsFile = dir.appendingPathComponent("tabs.json")
        let tabs = [SavedTab(profileID: UUID(), database: "shop", number: 1, title: nil, text: "SELECT 1", selected: true)]
        let plain = try JSONEncoder().encode(tabs)
        try plain.write(to: tabsFile)
        let none = LocalDataCrypto(provider: UnavailableLocalDataKeyProvider())
        let store = TabStore(file: tabsFile, crypto: none)
        #expect(store.load() == tabs)
        // 평문은 그대로 (잃지 않음), 새로 저장해도 평문으로 쓰지 않는다
        #expect(try Data(contentsOf: tabsFile) == plain)
        store.save([])
        #expect(try Data(contentsOf: tabsFile) == plain)

        // 히스토리: 메모리에서만, 디스크는 그대로
        let histFile = dir.appendingPathComponent("history.jsonl")
        let e = entry("SELECT old")
        let legacy = try JSONEncoder.iso.encode(e) + Data("\n".utf8)
        try legacy.write(to: histFile)
        let h = QueryHistory(file: histFile, crypto: none)
        #expect(h.all().map(\.sql) == ["SELECT old"])
        #expect(h.isMemoryOnly)
        h.append(entry("SELECT new"))
        #expect(h.all().map(\.sql) == ["SELECT new", "SELECT old"])
        #expect(try Data(contentsOf: histFile) == legacy)
    }

    @Test func migratesPlaintextHistory() throws {
        let file = tempDir().appendingPathComponent("history.jsonl")
        let lines = try [entry("SELECT 1", daysAgo: 2), entry(Self.secretSQL, daysAgo: 1)]
            .map { String(decoding: try JSONEncoder.iso.encode($0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let h = QueryHistory(file: file, crypto: crypto)
        #expect(h.all().map(\.sql) == [Self.secretSQL, "SELECT 1"])
        let raw = try Data(contentsOf: file)
        #expect(LocalDataCrypto.isEncrypted(raw))
        #expect(!contains(raw, "010-1234-5678"))
        #expect(!contains(raw, "SELECT"))
        #expect(QueryHistory(file: file, crypto: crypto).all().map(\.sql) == [Self.secretSQL, "SELECT 1"])
    }

    @Test func historyRecoversWhenKeyComesBack() throws {
        // 처음엔 키가 없다가 나중에 생기는 키 (키체인이 잠겨 있다가 풀림)
        final class Flaky: LocalDataKeyProvider, @unchecked Sendable {
            let k = SymmetricKey(size: .bits256)
            var available = false
            func key() throws -> SymmetricKey {
                guard available else { throw LocalDataCryptoError.keyUnavailable(-25308) }
                return k
            }
        }
        let flaky = Flaky()
        let c = LocalDataCrypto(provider: flaky)
        let file = tempDir().appendingPathComponent("history.jsonl")
        // 암호화된 기록이 이미 있다
        let seed = QueryHistory(file: file, crypto: LocalDataCrypto(provider: StaticLocalDataKeyProvider(flaky.k)))
        seed.append(entry("SELECT disk"))
        let before = try Data(contentsOf: file)

        let h = QueryHistory(file: file, crypto: c)
        #expect(h.all().isEmpty)
        h.append(entry("SELECT memory"))
        #expect(h.isMemoryOnly)
        #expect(try Data(contentsOf: file) == before)  // 덮어쓰지 않음

        flaky.available = true
        #expect(h.all().map(\.sql) == ["SELECT memory", "SELECT disk"])
        #expect(!h.isMemoryOnly)
        #expect(QueryHistory(file: file, crypto: c).all().map(\.sql) == ["SELECT memory", "SELECT disk"])
    }

    // MARK: 줄 단위 히스토리

    @Test func perLineAppendAndReload() throws {
        let file = tempDir().appendingPathComponent("history.jsonl")
        let h = QueryHistory(file: file, crypto: crypto)
        h.append(entry("SELECT 1"))
        let first = try Data(contentsOf: file)
        h.append(entry("SELECT 2"))
        h.append(entry("SELECT 3"))
        let raw = try Data(contentsOf: file)
        // 덧붙이기만 했다 (앞부분 그대로), 머리 줄 + 한 줄에 한 건
        #expect(raw.starts(with: first))
        let text = String(decoding: raw, as: UTF8.self)
        let lines = text.split(separator: "\n")
        #expect(lines.first == "GDBENC1")
        #expect(lines.count == 4)
        for line in lines.dropFirst() {
            #expect(Data(base64Encoded: String(line)) != nil)
            #expect(try JSONDecoder.iso.decode(HistoryEntry.self, from: crypto.openLine(line)).sql.hasPrefix("SELECT"))
        }
        #expect(QueryHistory(file: file, crypto: crypto).all().map(\.sql) == ["SELECT 3", "SELECT 2", "SELECT 1"])

        // 한 줄이 깨져도 나머지는 읽는다
        var broken = lines.map(String.init)
        broken[2] = String(broken[2].reversed())
        try Data((broken.joined(separator: "\n") + "\n").utf8).write(to: file)
        #expect(QueryHistory(file: file, crypto: crypto).all().map(\.sql) == ["SELECT 3", "SELECT 1"])
    }

    // MARK: 보관 기간

    @Test(arguments: [(7, 1), (30, 2), (90, 3), (0, 5)])
    func retention(keepDays: Int, expected: Int) throws {
        let now = Date()
        let ages: [Double] = [400, 100, 40, 10, 1]
        let file = tempDir().appendingPathComponent("history.jsonl")
        let lines = try ages.map { try crypto.sealLine(JSONEncoder.iso.encode(entry("SELECT \(Int($0))", daysAgo: $0, now: now))) }
        try Data(((["GDBENC1"] + lines).joined(separator: "\n") + "\n").utf8).write(to: file)

        let h = QueryHistory(file: file, crypto: crypto, keepDays: { keepDays }, now: { now })
        #expect(h.all().count == expected)
        // 파일도 정리됐다
        #expect(QueryHistory(file: file, crypto: crypto, keepDays: { 0 }, now: { now }).all().count == expected)
        #expect(QueryHistory.retained(h.all(), keepDays: keepDays, now: now).count == expected)
    }

    @Test func retentionRunsAtMostOncePerDayOnAppend() throws {
        let clock = Clock(Date())
        let file = tempDir().appendingPathComponent("history.jsonl")
        let h = QueryHistory(file: file, crypto: crypto, keepDays: { 7 }, now: { clock.now })
        h.append(entry("SELECT a", now: clock.now))
        // 8일 지남 → 다음 기록 때 정리
        clock.now = clock.now.addingTimeInterval(8 * 86_400)
        h.append(entry("SELECT b", now: clock.now))
        #expect(h.all().map(\.sql) == ["SELECT b"])
        // 하루 안에는 다시 정리하지 않는다
        clock.now = clock.now.addingTimeInterval(3600)
        h.append(entry("SELECT c", daysAgo: 30, now: clock.now))
        #expect(h.all().count == 2)
        h.applyRetentionNow()
        #expect(h.all().map(\.sql) == ["SELECT b"])
    }

    // MARK: 탭 · 저장 쿼리 · AI 대화

    @Test func tabStoreRoundTripIsEncrypted() throws {
        let file = tempDir().appendingPathComponent("tabs.json")
        let store = TabStore(file: file, crypto: crypto)
        let tabs = [
            SavedTab(profileID: UUID(), database: "shop", number: 1, title: "회원", text: Self.secretSQL, selected: true),
            SavedTab(profileID: UUID(), database: "crm", number: 2, title: nil, text: "", selected: false),
        ]
        store.save(tabs)
        #expect(store.load() == tabs)
        #expect(TabStore(file: file, crypto: crypto).load() == tabs)
        let raw = try Data(contentsOf: file)
        #expect(LocalDataCrypto.isEncrypted(raw))
        #expect(String(decoding: raw, as: UTF8.self).split(separator: "\n").count == 2)
        // 다른 키로는 못 연다 (빈 목록, 파일은 옆으로 치움)
        #expect(TabStore(file: file, crypto: LocalDataCrypto(provider: StaticLocalDataKeyProvider())).load().isEmpty)
    }

    @Test func noPlaintextSQLOnDisk() throws {
        let dir = tempDir()
        let marker = "SELECT secret_marker_7f3a FROM member WHERE email = 'kim@example.com'"
        let h = QueryHistory(file: dir.appendingPathComponent("history.jsonl"), crypto: crypto)
        h.append(entry(marker))
        TabStore(file: dir.appendingPathComponent("tabs.json"), crypto: crypto)
            .save([SavedTab(profileID: UUID(), database: "shop", number: 1, title: nil, text: marker, selected: true)])
        SavedQueryStore(file: dir.appendingPathComponent("saved-queries.json"), crypto: crypto)
            .save(SavedQueryLibrary(queries: [SavedQuery(name: "q", sql: marker, lastValues: ["email": "kim@example.com"])]))
        let chats = DiagramChatStore(directory: dir.appendingPathComponent("diagram-chats"), crypto: crypto)
        chats.save(DiagramConversation(messages: [.init(role: "user", text: marker)]), scope: "s")

        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        #expect(files.count == 4)
        for f in files {
            let raw = try Data(contentsOf: f)
            #expect(LocalDataCrypto.isEncrypted(raw), "\(f.lastPathComponent)")
            for needle in ["secret_marker_7f3a", "kim@example.com", "SELECT", "member"] {
                #expect(!contains(raw, needle), "\(f.lastPathComponent) contains \(needle)")
            }
        }
        // 다시 읽힌다
        #expect(h.all().first?.sql == marker)
        #expect(chats.load("s").first?.messages.first?.text == marker)
        #expect(SavedQueryStore(file: dir.appendingPathComponent("saved-queries.json"), crypto: crypto).load().queries.first?.sql == marker)
    }

    @Test func chatStoreMigratesAndKeepsFileWhenKeyUnavailable() throws {
        let dir = tempDir()
        let plainStore = DiagramChatStore(directory: dir, crypto: crypto)
        let conv = DiagramConversation(messages: [.init(role: "user", text: "SELECT 1")])
        // 예전 평문 파일
        let file = plainStore.url("s")
        try DiagramChatStore.encoder.encode([conv]).write(to: file)
        plainStore.pruneAll()
        #expect(LocalDataCrypto.isEncrypted(try Data(contentsOf: file)))
        #expect(plainStore.load("s").map(\.id) == [conv.id])

        // 키가 없으면 지우기 · 저장이 파일을 건드리지 않는다
        let before = try Data(contentsOf: file)
        let locked = DiagramChatStore(directory: dir, crypto: LocalDataCrypto(provider: UnavailableLocalDataKeyProvider()))
        #expect(locked.load("s").isEmpty)
        locked.delete(conv.id, scope: "s")
        locked.save(DiagramConversation(messages: [.init(role: "user", text: "x")]), scope: "s")
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func defaultsStringMigratesAndEncrypts() throws {
        let suite = "goddb-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("SET k secret", forKey: "w")
        #expect(crypto.defaultsString(forKey: "w", in: defaults) == "SET k secret")
        #expect(defaults.string(forKey: "w")?.hasPrefix("GDBENC1:") == true)
        crypto.setDefaultsString("GET k", forKey: "w", in: defaults)
        #expect(defaults.string(forKey: "w")?.contains("GET") == false)
        #expect(crypto.defaultsString(forKey: "w", in: defaults) == "GET k")
    }
}

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
