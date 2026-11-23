import Foundation

/// 저장 쿼리 (⌥⌘S 저장 · ⇧⌘K 목록): 자주 쓰는 쿼리를 이름 · 폴더로 저장하고, `:이름` 빈칸을 채워 실행한다.
/// (명세 docs/specs/1.4.0.md · F2)
public struct SavedQuery: Codable, Identifiable, Equatable, Sendable {
    /// 어느 접속에서 보이는지
    public enum Scope: String, Codable, Sendable, CaseIterable {
        /// 모든 접속
        case all
        /// 저장한 접속(profileID)에서만
        case profile
    }

    public var id: UUID
    public var name: String
    /// 폴더 (없으면 빈 문자열)
    public var folder: String
    public var sql: String
    public var scope: Scope
    /// scope == .profile 일 때 그 접속
    public var profileID: UUID?
    /// 빈칸별 마지막 입력값 (이름 → 값)
    public var lastValues: [String: String]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), name: String, folder: String = "", sql: String, scope: Scope = .all,
                profileID: UUID? = nil, lastValues: [String: String] = [:],
                createdAt: Date = Date(), updatedAt: Date? = nil, lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.folder = folder
        self.sql = sql
        self.scope = scope
        self.profileID = scope == .profile ? profileID : nil
        self.lastValues = lastValues
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, folder, sql, scope, profileID, lastValues, createdAt, updatedAt, lastUsedAt
    }

    // Windows 판도 읽으므로 빠진 칸은 기본값으로 읽고, 쓸 때는 모든 키를 쓴다 (없는 값은 null).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        sql = try c.decode(String.self, forKey: .sql)
        scope = (try? c.decodeIfPresent(Scope.self, forKey: .scope)) ?? .all
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        lastValues = (try? c.decodeIfPresent([String: String].self, forKey: .lastValues)) ?? [:]
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(folder, forKey: .folder)
        try c.encode(sql, forKey: .sql)
        try c.encode(scope, forKey: .scope)
        try c.encode(profileID, forKey: .profileID)
        try c.encode(lastValues, forKey: .lastValues)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(lastUsedAt, forKey: .lastUsedAt)
    }

    /// 이 접속을 보고 있을 때 보이는지 (`이 접속만` 은 그 접속에서만)
    public func isVisible(for profileID: UUID?) -> Bool {
        scope == .all || (profileID != nil && self.profileID == profileID)
    }

    /// 최근 사용 순 정렬 기준 (쓴 적 없으면 만든 시각)
    public var recency: Date { lastUsedAt ?? createdAt }

    /// 기본 이름: 첫 줄(공백 아닌) 앞 40자
    public static func defaultName(for sql: String) -> String {
        let first = sql.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(first.prefix(40))
    }
}

// MARK: - 빈칸 (파라미터)

/// `:이름` 빈칸 찾기 · 값 변환 · 채워 넣기
public enum SQLParameters {
    /// 빈칸 하나가 나온 자리 (원문 UTF-16 범위, `:` 포함)
    public struct Occurrence: Equatable, Sendable {
        public var name: String
        public var range: NSRange
    }

    /// 입력 창 한 줄의 값
    public struct Input: Equatable, Sendable {
        public var value: String
        /// NULL 체크
        public var isNull: Bool
        /// "그대로 넣기" 체크 (SQL 조각으로 그대로)
        public var raw: Bool

        public init(value: String = "", isNull: Bool = false, raw: Bool = false) {
            self.value = value
            self.isNull = isNull
            self.raw = raw
        }
    }

    /// 빈칸 이름 (처음 나온 순서, 중복 제거)
    public static func names(in sql: String, kind: DatabaseKind) -> [String] {
        var seen = Set<String>()
        return occurrences(in: sql, kind: kind).map(\.name).filter { seen.insert($0).inserted }
    }

    /// 빈칸이 나온 모든 자리. 문자열 리터럴(' " `) · 주석(-- /* */ 와 MySQL 의 #) · PostgreSQL `$$` 인용 ·
    /// `::type` 캐스트 · `:=` 안/뒤의 `:` 는 빈칸이 아니다.
    public static func occurrences(in sql: String, kind: DatabaseKind) -> [Occurrence] {
        let chars = Array(sql.utf16)
        let n = chars.count
        func at(_ i: Int) -> UInt16? { i < n ? chars[i] : nil }
        func ascii(_ s: Unicode.Scalar) -> UInt16 { UInt16(s.value) }
        func isNameStart(_ c: UInt16?) -> Bool {
            guard let c else { return false }
            return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        func isNameChar(_ c: UInt16?) -> Bool {
            guard let c else { return false }
            return isNameStart(c) || (c >= 48 && c <= 57)
        }
        let quoteChars: Set<UInt16> = [ascii("'"), ascii("\""), ascii("`")]
        let newline = ascii("\n")
        var result: [Occurrence] = []
        var i = 0
        while i < n {
            let c = chars[i]
            // 문자열 · 따옴표 이름: 같은 따옴표가 나올 때까지 ('' 처럼 겹친 따옴표는 닫고 다시 여는 것과 같다)
            if quoteChars.contains(c) {
                var j = i + 1
                while j < n, chars[j] != c {
                    if kind == .mysql, chars[j] == ascii("\\"), c != ascii("`") { j += 1 }
                    j += 1
                }
                i = j + 1
                continue
            }
            // 줄 주석: -- 와 MySQL 의 #
            if (c == ascii("-") && at(i + 1) == ascii("-")) || (kind == .mysql && c == ascii("#")) {
                while i < n, chars[i] != newline { i += 1 }
                continue
            }
            // 블록 주석
            if c == ascii("/") && at(i + 1) == ascii("*") {
                i += 2
                while i < n, !(chars[i] == ascii("*") && at(i + 1) == ascii("/")) { i += 1 }
                i += 2
                continue
            }
            // PostgreSQL 달러 인용 ($$ … $$, $tag$ … $tag$)
            if kind == .postgres, c == ascii("$"), let tagEnd = SQLText.dollarTagEnd(chars, from: i) {
                let tag = Array(chars[i...tagEnd])
                var j = tagEnd + 1
                var closed = false
                while j + tag.count <= n {
                    if Array(chars[j..<(j + tag.count)]) == tag { j += tag.count; closed = true; break }
                    j += 1
                }
                i = closed ? j : n
                continue
            }
            if c == ascii(":") {
                // ::type 캐스트, := 대입
                if at(i + 1) == ascii(":") {
                    i += 2
                    while i < n, chars[i] == ascii(":") { i += 1 }
                    continue
                }
                if at(i + 1) == ascii("=") { i += 2; continue }
                if isNameStart(at(i + 1)) {
                    var j = i + 1
                    while isNameChar(at(j)) { j += 1 }
                    let name = String(utf16CodeUnits: Array(chars[(i + 1)..<j]), count: j - i - 1)
                    result.append(Occurrence(name: name, range: NSRange(location: i, length: j - i)))
                    i = j
                    continue
                }
            }
            i += 1
        }
        return result
    }

    private static let numberPattern = #"^-?\d+(\.\d+)?$"#

    /// 숫자 꼴(`^-?\d+(\.\d+)?$`)인지
    public static func isNumber(_ s: String) -> Bool {
        s.range(of: numberPattern, options: .regularExpression) != nil
    }

    /// 값 하나 변환: 숫자 꼴은 그대로, 그 밖은 다이얼렉트 문자열 인용
    public static func literal(_ value: String, dialect: any SQLDialect) -> String {
        let t = value.trimmingCharacters(in: .whitespaces)
        return isNumber(t) ? t : dialect.quoteString(value)
    }

    /// 입력 한 줄을 SQL 조각으로: NULL → `NULL`, 그대로 넣기 → 입력 그대로,
    /// 쉼표가 있으면 목록으로 펼쳐 각각 변환 (`1,2,3` → `1, 2, 3`, `a,b` → `'a', 'b'`)
    public static func render(_ input: Input, dialect: any SQLDialect) -> String {
        if input.isNull { return "NULL" }
        if input.raw { return input.value }
        if input.value.contains(",") {
            return input.value.split(separator: ",", omittingEmptySubsequences: false)
                .map { literal($0.trimmingCharacters(in: .whitespaces), dialect: dialect) }
                .joined(separator: ", ")
        }
        return literal(input.value, dialect: dialect)
    }

    /// 빈칸을 SQL 조각으로 바꾼다. fragments 에 없는 빈칸은 그대로 둔다.
    public static func substitute(_ sql: String, fragments: [String: String], kind: DatabaseKind) -> String {
        let ns = NSMutableString(string: sql)
        for occ in occurrences(in: sql, kind: kind).reversed() {
            guard let f = fragments[occ.name] else { continue }
            ns.replaceCharacters(in: occ.range, with: f)
        }
        return ns as String
    }

    /// 입력값으로 채운 SQL
    public static func fill(_ sql: String, inputs: [String: Input], dialect: any SQLDialect) -> String {
        substitute(sql, fragments: inputs.mapValues { render($0, dialect: dialect) }, kind: dialect.kind)
    }
}

// MARK: - 목록 (saved-queries.json)

/// 저장 쿼리 목록. 형식: `{"version":1,"queries":[…]}`
public struct SavedQueryLibrary: Codable, Equatable, Sendable {
    public var version = 1
    public var queries: [SavedQuery] = []

    public init(queries: [SavedQuery] = []) { self.queries = queries }

    /// 폴더 묶음 하나 (folder 가 빈 문자열이면 폴더 없음)
    public struct Group: Equatable, Sendable, Identifiable {
        public var folder: String
        public var queries: [SavedQuery]
        public var id: String { folder }
    }

    public subscript(id: UUID) -> SavedQuery? {
        queries.first { $0.id == id }
    }

    /// 쓰인 폴더 이름 (자동완성용, 가나다순)
    public var folders: [String] {
        Array(Set(queries.map(\.folder).filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 이 접속에서 보이는 것 중 검색어(이름 · SQL · 폴더, 대소문자 무시)에 맞는 것
    public func search(_ query: String, profileID: UUID?) -> [SavedQuery] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return queries.filter { q in
            guard q.isVisible(for: profileID) else { return false }
            let hay = (q.name + "\n" + q.sql + "\n" + q.folder).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// 폴더별로 묶고 최근 사용 순으로 정렬한다. 묶음도 그 안에서 가장 최근에 쓴 것 순.
    public static func grouped(_ list: [SavedQuery]) -> [Group] {
        let sorted = list.sorted { a, b in
            a.recency != b.recency ? a.recency > b.recency : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        var order: [String] = []
        var byFolder: [String: [SavedQuery]] = [:]
        for q in sorted {
            if byFolder[q.folder] == nil { order.append(q.folder) }
            byFolder[q.folder, default: []].append(q)
        }
        return order.map { Group(folder: $0, queries: byFolder[$0] ?? []) }
    }

    public mutating func add(_ query: SavedQuery) {
        queries.append(query)
    }

    public mutating func update(_ id: UUID, now: Date = Date(), _ change: (inout SavedQuery) -> Void) {
        guard let i = queries.firstIndex(where: { $0.id == id }) else { return }
        change(&queries[i])
        queries[i].updatedAt = now
    }

    public mutating func rename(_ id: UUID, to name: String, now: Date = Date()) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        update(id, now: now) { $0.name = n }
    }

    public mutating func setFolder(_ id: UUID, to folder: String, now: Date = Date()) {
        update(id, now: now) { $0.folder = folder.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 복제: 이름 뒤에 " 사본", 입력값 · 범위는 그대로, 사용 기록은 없이
    @discardableResult
    public mutating func duplicate(_ id: UUID, suffix: String, now: Date = Date()) -> SavedQuery? {
        guard let q = self[id] else { return nil }
        let copy = SavedQuery(name: q.name + suffix, folder: q.folder, sql: q.sql, scope: q.scope, profileID: q.profileID,
                              lastValues: q.lastValues, createdAt: now)
        queries.append(copy)
        return copy
    }

    public mutating func delete(_ id: UUID) {
        queries.removeAll { $0.id == id }
    }

    /// 실행 · 넣기 기록: 마지막 사용 시각과 입력값 (값은 이 쿼리의 빈칸만 남긴다)
    public mutating func markUsed(_ id: UUID, values: [String: String]? = nil, now: Date = Date()) {
        guard let i = queries.firstIndex(where: { $0.id == id }) else { return }
        queries[i].lastUsedAt = now
        if let values { queries[i].lastValues = values }
    }
}

public struct SavedQueryStore: Sendable {
    public static let shared = SavedQueryStore(file: AppPaths.dataDirectory.appendingPathComponent("saved-queries.json"))

    public let file: URL
    private let crypto: LocalDataCrypto

    /// 파일은 `GDBENC1` 통째 암호화 (SQL · 마지막 입력값이 들어 있으므로). 예전 평문은 처음 읽을 때 옮긴다.
    public init(file: URL, crypto: LocalDataCrypto = .shared) {
        self.file = file
        self.crypto = crypto
    }

    public static func decode(_ data: Data) throws -> SavedQueryLibrary {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(SavedQueryLibrary.self, from: data)
    }

    public static func encode(_ library: SavedQueryLibrary) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(library)
    }

    public func load() -> SavedQueryLibrary {
        guard let data = crypto.readDocumentData(at: file), let lib = try? Self.decode(data) else { return SavedQueryLibrary() }
        return lib
    }

    /// 암호화해서 저장. 키가 없으면 쓰지 않는다 (평문으로 쓰지 않음).
    public func save(_ library: SavedQueryLibrary) {
        guard let data = try? Self.encode(library) else { return }
        do { try crypto.writeDocument(data, to: file) } catch {
            LocalDataCrypto.log.warning("GodDB: saved queries not saved (\(error.localizedDescription, privacy: .public))")
        }
    }
}
