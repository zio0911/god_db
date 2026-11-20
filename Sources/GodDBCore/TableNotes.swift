import Foundation

/// 테이블 메모: "이 데이터는 이 테이블 · 컬럼에 있다" 는 기억 (AI 데이터 찾기가 자동 저장, 사용자가 고치거나 추가).
/// (명세 docs/specs/1.4.0.md · F7) 샘플 값은 저장하지 않는다.
public struct TableNote: Codable, Identifiable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// AI 데이터 찾기가 저장
        case ai
        /// 사용자가 직접 추가
        case user
    }

    public var id: UUID
    public var profileID: UUID
    public var database: String
    public var table: String
    public var columns: [String]
    /// 찾는 말 (질문 핵심어)
    public var terms: [String]
    public var memo: String
    public var source: Source
    public var confirmed: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), profileID: UUID, database: String, table: String, columns: [String] = [],
                terms: [String] = [], memo: String = "", source: Source = .user, confirmed: Bool? = nil,
                createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.profileID = profileID
        self.database = database
        self.table = table
        self.columns = columns
        self.terms = terms
        self.memo = memo
        self.source = source
        // 직접 추가한 메모는 확인된 것으로 본다
        self.confirmed = confirmed ?? (source == .user)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, profileID, database, table, columns, terms, memo, source, confirmed, createdAt, updatedAt
    }

    // Windows 판도 읽으므로 빠진 칸은 기본값으로 읽는다
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        profileID = try c.decode(UUID.self, forKey: .profileID)
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        table = try c.decode(String.self, forKey: .table)
        columns = (try? c.decodeIfPresent([String].self, forKey: .columns)) ?? []
        terms = (try? c.decodeIfPresent([String].self, forKey: .terms)) ?? []
        memo = try c.decodeIfPresent(String.self, forKey: .memo) ?? ""
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .user
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// 같은 위치(테이블 + 컬럼 묶음)인지 — 대소문자 · 컬럼 순서 무시
    public func sameLocation(table: String, columns: [String]) -> Bool {
        self.table.lowercased() == table.lowercased()
            && Set(self.columns.map { $0.lowercased() }) == Set(columns.map { $0.lowercased() })
    }

    /// `table.col1, col2`
    public var location: String {
        columns.isEmpty ? table : "\(table).\(columns.joined(separator: ", "))"
    }

    /// 쉼표로 나눈 글 → 목록 (앞뒤 공백 제거, 빈 칸 · 중복 제외)
    public static func split(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

public struct TableNoteLibrary: Codable, Equatable, Sendable {
    public var version = 1
    public var notes: [TableNote] = []

    public init(notes: [TableNote] = []) { self.notes = notes }

    public subscript(id: UUID) -> TableNote? { notes.first { $0.id == id } }

    /// 이 접속 · DB 의 메모 (확인된 것 먼저, 최근 고친 순)
    public func notes(profileID: UUID, database: String) -> [TableNote] {
        notes.filter { $0.profileID == profileID && $0.database == database }
            .sorted { a, b in a.confirmed != b.confirmed ? a.confirmed : a.updatedAt > b.updatedAt }
    }

    /// 이 테이블의 메모 (만든 순)
    public func notes(profileID: UUID, database: String, table: String) -> [TableNote] {
        notes.filter { $0.profileID == profileID && $0.database == database && $0.table.lowercased() == table.lowercased() }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 사이드바 📝 표시용: 메모가 있는 테이블 이름 (소문자)
    public func tablesWithNotes(profileID: UUID, database: String) -> Set<String> {
        Set(notes.filter { $0.profileID == profileID && $0.database == database }.map { $0.table.lowercased() })
    }

    public mutating func add(_ note: TableNote) {
        notes.append(note)
    }

    public mutating func update(_ id: UUID, now: Date = Date(), _ change: (inout TableNote) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
        notes[i].updatedAt = now
    }

    public mutating func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
    }

    /// AI 답 카드의 자동 저장: 같은 table+columns 메모가 있으면 terms 만 합치고, 없으면 새로 (source ai, 미확인).
    /// 저장된(또는 합친) 메모의 id 를 돌려준다.
    @discardableResult
    public mutating func saveFound(profileID: UUID, database: String, table: String, columns: [String],
                                   terms: [String], memo: String, now: Date = Date()) -> UUID {
        if let i = notes.firstIndex(where: { $0.profileID == profileID && $0.database == database
                                                && $0.sameLocation(table: table, columns: columns) }) {
            let merged = Self.mergeTerms(notes[i].terms, terms)
            if merged != notes[i].terms {
                notes[i].terms = merged
                notes[i].updatedAt = now
            }
            if notes[i].memo.trimmingCharacters(in: .whitespaces).isEmpty, !memo.isEmpty {
                notes[i].memo = memo
                notes[i].updatedAt = now
            }
            return notes[i].id
        }
        let note = TableNote(profileID: profileID, database: database, table: table, columns: columns,
                             terms: Self.mergeTerms([], terms), memo: memo, source: .ai, confirmed: false, createdAt: now)
        notes.append(note)
        return note.id
    }

    /// 찾는 말 합치기: 순서 유지, 정규화(공백 제거 · 소문자)해서 같은 말은 한 번만
    public static func mergeTerms(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in a + b {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = DataFinder.normalize(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// 일반 어시스턴트 질문에 함께 보낼 "팀이 확인한 위치" (이 DB, 최대 50개)
    public func contextText(profileID: UUID, database: String, limit: Int = 50) -> String? {
        let list = notes(profileID: profileID, database: database).prefix(limit)
        guard !list.isEmpty else { return nil }
        var s = "Data locations confirmed by the team (table notes; \"unconfirmed\" = found by AI, not checked yet):\n"
        for n in list {
            var line = "  - \(n.terms.joined(separator: ", ")) → \(n.location)"
            if !n.memo.isEmpty { line += " — \(n.memo.prefix(120))" }
            if !n.confirmed { line += " (unconfirmed)" }
            s += line + "\n"
        }
        return s
    }
}

/// `table-notes.json` (앱 데이터 폴더, 권한 본인만)
public struct TableNoteStore: Sendable {
    public static let shared = TableNoteStore(file: AppPaths.dataDirectory.appendingPathComponent("table-notes.json"))

    public let file: URL

    public init(file: URL) { self.file = file }

    public static func decode(_ data: Data) throws -> TableNoteLibrary {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(TableNoteLibrary.self, from: data)
    }

    public static func encode(_ library: TableNoteLibrary) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(library)
    }

    public func load() -> TableNoteLibrary {
        guard let data = try? Data(contentsOf: file), let lib = try? Self.decode(data) else { return TableNoteLibrary() }
        return lib
    }

    public func save(_ library: TableNoteLibrary) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? Self.encode(library) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
