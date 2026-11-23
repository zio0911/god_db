import Foundation

/// 테이블 · 컬럼 · 데이터(코드 값) 설명 JSON (#178).
/// 소스 코드를 본 Claude 등에게 분석을 받아 만들고, 접속 · DB 마다 가져와 두면 AI 어시스턴트 · 데이터 찾기가 참고한다.
/// 데이터 행은 담지 않는다 — 코드 값의 뜻(`values`)만.
public struct TableDescriptionDoc: Codable, Equatable, Sendable {
    public static let formatName = "goddb-table-descriptions"
    public static let currentVersion = 1

    public struct Column: Codable, Equatable, Sendable {
        public var name: String
        /// 업무 이름 (논리명)
        public var title: String?
        public var description: String?
        /// 이 컬럼을 찾을 때 쓰는 말 (예: "학년", "grade")
        public var terms: [String]?
        /// 코드 값의 뜻: {"P": "결제 대기", "C": "완료"}
        public var values: [String: String]?
        /// DB 에 FK 가 없어도 코드에서 가리키는 곳: "members.id"
        public var references: String?

        public init(name: String, title: String? = nil, description: String? = nil, terms: [String]? = nil,
                    values: [String: String]? = nil, references: String? = nil) {
            self.name = name
            self.title = title
            self.description = description
            self.terms = terms
            self.values = values
            self.references = references
        }
    }

    public struct Table: Codable, Equatable, Sendable {
        public var name: String
        public var title: String?
        public var description: String?
        public var terms: [String]?
        public var columns: [Column]?
        /// 조회 · 사용 규칙 (예: "deleted_at IS NULL 조건을 붙인다")
        public var notes: [String]?

        public init(name: String, title: String? = nil, description: String? = nil, terms: [String]? = nil,
                    columns: [Column]? = nil, notes: [String]? = nil) {
            self.name = name
            self.title = title
            self.description = description
            self.terms = terms
            self.columns = columns
            self.notes = notes
        }

        public func column(_ name: String) -> Column? {
            columns?.first { $0.name.lowercased() == name.lowercased() }
        }
    }

    public var format: String?
    public var version: Int?
    /// DB(스키마) 이름. 가져올 때 비어 있으면 지금 DB
    public var database: String?
    public var generatedBy: String?
    public var generatedAt: String?
    /// DB 전체 요약 (업무 도메인)
    public var overview: String?
    public var tables: [Table]

    public init(database: String? = nil, generatedBy: String? = nil, generatedAt: String? = nil, overview: String? = nil,
                tables: [Table] = []) {
        format = Self.formatName
        version = Self.currentVersion
        self.database = database
        self.generatedBy = generatedBy
        self.generatedAt = generatedAt
        self.overview = overview
        self.tables = tables
    }

    public func table(_ name: String) -> Table? {
        let key = Self.bare(name)
        return tables.first { Self.bare($0.name) == key }
    }

    /// `public.orders` · `orders` 를 같게 본다
    static func bare(_ name: String) -> String {
        (name.split(separator: ".").last.map(String.init) ?? name).lowercased()
    }

    public var columnCount: Int { tables.reduce(0) { $0 + ($1.columns?.count ?? 0) } }
    public var valueCount: Int { tables.reduce(0) { $0 + ($1.columns ?? []).reduce(0) { $0 + ($1.values?.count ?? 0) } } }

    // MARK: 읽기 · 쓰기

    public enum ParseError: Error, Equatable, LocalizedError {
        /// JSON 이 아님 (어디서 깨졌는지)
        case notJSON(String)
        /// 양식이 어긋남 (경로 + 이유)
        case invalid(path: String, reason: String)
        case wrongFormat(String)
        case newerVersion(Int)
        case empty

        public var errorDescription: String? {
            switch self {
            case .notJSON(let m): return tr("JSON 으로 읽지 못했어요: %@", m)
            case .invalid(let path, let reason): return tr("양식이 맞지 않아요: %@ — %@", path, reason)
            case .wrongFormat(let f): return tr("테이블 설명 파일이 아니에요 (format: %@)", f)
            case .newerVersion(let v): return tr("더 새 버전(%@)의 양식이에요. GodDB 를 업데이트해 주세요.", "\(v)")
            case .empty: return tr("tables 가 비어 있어요.")
            }
        }
    }

    public static func parse(_ data: Data) throws -> TableDescriptionDoc {
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            let ns = error as NSError
            throw ParseError.notJSON((ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription)
        }
        let doc: TableDescriptionDoc
        do {
            doc = try JSONDecoder().decode(TableDescriptionDoc.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw ParseError.invalid(path: path(ctx.codingPath + [key]), reason: tr("꼭 있어야 하는 칸이 없어요"))
        } catch let DecodingError.typeMismatch(type, ctx) {
            throw ParseError.invalid(path: path(ctx.codingPath), reason: tr("%@ 이어야 해요", typeName(type)))
        } catch let DecodingError.valueNotFound(type, ctx) {
            throw ParseError.invalid(path: path(ctx.codingPath), reason: tr("%@ 이어야 해요", typeName(type)))
        } catch let DecodingError.dataCorrupted(ctx) {
            throw ParseError.invalid(path: path(ctx.codingPath), reason: ctx.debugDescription)
        }
        if let f = doc.format, f != formatName { throw ParseError.wrongFormat(f) }
        if let v = doc.version, v > currentVersion { throw ParseError.newerVersion(v) }
        if doc.tables.isEmpty { throw ParseError.empty }
        for (i, t) in doc.tables.enumerated() where t.name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ParseError.invalid(path: "tables[\(i)].name", reason: tr("비어 있어요"))
        }
        return doc
    }

    static func path(_ keys: [any CodingKey]) -> String {
        var s = ""
        for k in keys {
            if let i = k.intValue { s += "[\(i)]" } else { s += (s.isEmpty ? "" : ".") + k.stringValue }
        }
        return s.isEmpty ? tr("(맨 위)") : s
    }

    static func typeName(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: return tr("글자")
        case is Int.Type: return tr("숫자")
        case is [String].Type: return tr("글자 목록 [\"…\"]")
        case is [String: String].Type: return tr("{\"값\": \"뜻\"} 묶음")
        default: return tr("목록 또는 묶음")
        }
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    // MARK: 빈 양식 · 분석 요청문

    /// 지금 테이블 구조로 빈 양식 (이름 · 코멘트 · FK 만, 데이터 값은 넣지 않는다)
    public static func skeleton(tables: [TableMeta], database: String) -> TableDescriptionDoc {
        func firstLine(_ s: String) -> String? {
            let l = s.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return l.isEmpty ? nil : l
        }
        let out = tables.map { t -> Table in
            let fks = t.foreignKeys
            let cols = t.columns.sorted { $0.position < $1.position }.map { c -> Column in
                let fk = fks.first { $0.columns.count == 1 && $0.columns[0].lowercased() == c.name.lowercased() }
                return Column(name: c.name, title: firstLine(c.comment), description: nil, terms: nil, values: nil,
                              references: fk.map { "\($0.referencedTable).\($0.referencedColumns.first ?? "")" })
            }
            return Table(name: t.name, title: firstLine(t.comment), description: nil, terms: nil, columns: cols, notes: nil)
        }
        return TableDescriptionDoc(database: database, generatedBy: nil, generatedAt: nil, overview: nil, tables: out)
    }

    /// Claude 에 소스와 함께 붙여넣을 분석 요청문
    public static func requestPrompt(database: String, kind: DatabaseKind, english: Bool) -> String {
        if english {
            return """
            Analyze the source code in this repository and describe every table of the \(kind.title) database `\(database)`.
            I attached a skeleton JSON with the current table and column names. Fill it in and return only the JSON, keeping this format:

            - format "\(formatName)", version \(currentVersion), database "\(database)", generatedBy, generatedAt (YYYY-MM-DD)
            - overview: the business domain of this database in 2–3 sentences
            - tables[].title: business name, description: what one row means, terms: words people use to look for it
            - tables[].columns[]: title, description (only when not obvious), terms, references ("table.column" for relations the code uses even without a foreign key)
            - columns[].values: meaning of code values, e.g. {"P": "pending", "C": "completed"} — from enums/constants in the code
            - tables[].notes: rules for querying (soft delete, status filters, which column joins which)

            Rules: use only names that exist in the skeleton, base everything on the code, leave a field out when unsure, never include real row data or personal information.
            """
        }
        return """
        이 저장소의 소스 코드를 보고 \(kind.title) DB `\(database)` 의 모든 테이블을 설명해 줘.
        지금 테이블 · 컬럼 이름이 들어 있는 빈 양식 JSON 을 붙였어. 같은 양식을 지켜 채운 JSON 만 돌려줘.

        - format "\(formatName)", version \(currentVersion), database "\(database)", generatedBy, generatedAt (YYYY-MM-DD)
        - overview: 이 DB 의 업무 도메인을 2~3문장으로
        - tables[].title: 업무 이름, description: 행 하나가 무엇인지, terms: 사람들이 이 데이터를 찾을 때 쓰는 말
        - tables[].columns[]: title, description (뻔하지 않을 때만), terms, references (FK 가 없어도 코드에서 잇는 곳 "테이블.컬럼")
        - columns[].values: 코드 값의 뜻, 예 {"P": "결제 대기", "C": "완료"} — 코드의 enum · 상수에서
        - tables[].notes: 조회할 때 규칙 (소프트 삭제, 상태 조건, 어떤 컬럼으로 잇는지)

        규칙: 빈 양식에 있는 이름만 쓰고, 코드에 근거해서 쓰고, 확실하지 않으면 그 칸은 빼고, 실제 데이터 행이나 개인 정보는 넣지 마.
        """
    }

    // MARK: DB 와 맞춰 보기

    public struct Check: Equatable, Sendable {
        /// JSON 에 있는데 DB 에 없는 테이블
        public var missingTables: [String] = []
        /// DB 에 있는데 JSON 에 없는 테이블
        public var undescribedTables: [String] = []
        /// JSON 에 있는데 DB 에 없는 컬럼 (`table.column`)
        public var unknownColumns: [String] = []

        public var isClean: Bool { missingTables.isEmpty && unknownColumns.isEmpty }
    }

    public func check(against meta: [TableMeta]) -> Check {
        var c = Check()
        let byName = Dictionary(meta.map { (Self.bare($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        for t in tables {
            guard let m = byName[Self.bare(t.name)] else { c.missingTables.append(t.name); continue }
            let cols = Set(m.columns.map { $0.name.lowercased() })
            for col in t.columns ?? [] where !cols.contains(col.name.lowercased()) {
                c.unknownColumns.append("\(t.name).\(col.name)")
            }
        }
        let described = Set(tables.map { Self.bare($0.name) })
        c.undescribedTables = meta.map(\.name).filter { !described.contains(Self.bare($0)) }
        return c
    }

    // MARK: AI 에 보낼 것

    /// 코멘트가 빈 테이블 · 컬럼에 title 을 논리명으로 채운 구조 (테이블 목록 · 질문 속 이름 찾기 · 구조 글에 그대로 쓰인다)
    public func applyTitles(to meta: [TableMeta]) -> [TableMeta] {
        meta.map { t in
            guard let d = table(t.name) else { return t }
            var t = t
            if t.comment.trimmingCharacters(in: .whitespaces).isEmpty, let title = d.title, !title.isEmpty { t.comment = title }
            t.columns = t.columns.map { c in
                guard c.comment.trimmingCharacters(in: .whitespaces).isEmpty, let title = d.column(c.name)?.title, !title.isEmpty
                else { return c }
                var c = c
                c.comment = title
                return c
            }
            return t
        }
    }

    /// 질문에서 테이블을 찾을 때 쓸 다른 이름 (소문자 테이블 이름 → title · terms)
    public var aliases: [String: [String]] {
        var out: [String: [String]] = [:]
        for t in tables {
            let names = ([t.title].compactMap { $0 } + (t.terms ?? [])).filter { !$0.isEmpty }
            if !names.isEmpty { out[Self.bare(t.name), default: []] += names }
        }
        return out
    }

    /// 자세히 볼 테이블의 설명 (+ DB 요약). 길이 제한 안에서.
    public func contextText(focus: [String], limit: Int = 8_000) -> String? {
        var s = ""
        if let o = overview, !o.isEmpty { s += "Database overview (from the team's table descriptions): \(o.prefix(600))\n" }
        var body = ""
        for name in focus {
            guard let t = table(name) else { continue }
            var block = "  \(t.name)"
            if let title = t.title, !title.isEmpty { block += " — \(title)" }
            if let d = t.description, !d.isEmpty { block += ": \(d.prefix(300))" }
            block += "\n"
            if let terms = t.terms, !terms.isEmpty { block += "    also called: \(terms.joined(separator: ", "))\n" }
            for c in t.columns ?? [] {
                var line = ""
                if let d = c.description, !d.isEmpty { line += " \(d.prefix(200))" }
                if let v = c.values, !v.isEmpty {
                    line += " values: " + v.sorted { $0.key < $1.key }.prefix(30).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                }
                if let r = c.references, !r.isEmpty { line += " → \(r)" }
                if let terms = c.terms, !terms.isEmpty { line += " (also called \(terms.joined(separator: ", ")))" }
                guard !line.isEmpty else { continue }
                block += "    .\(c.name)\(c.title.map { " [\($0)]" } ?? ""):\(line)\n"
            }
            for n in t.notes ?? [] { block += "    rule: \(n.prefix(200))\n" }
            if body.count + block.count > limit { body += "  … (more descriptions truncated)\n"; break }
            body += block
        }
        if !body.isEmpty { s += "Table descriptions written by the team (business meaning, code values, rules):\n" + body }
        return s.isEmpty ? nil : s
    }

    // MARK: 데이터 찾기

    /// 데이터 찾기가 쓰는 "찾는 말 → 위치" 목록 (title · terms). id 는 위치마다 늘 같다.
    public func finderNotes(profileID: UUID, database: String) -> [TableNote] {
        var out: [TableNote] = []
        let epoch = Date(timeIntervalSince1970: 0)
        for t in tables {
            let tTerms = ([t.title].compactMap { $0 } + (t.terms ?? [])).filter { !$0.isEmpty }
            if !tTerms.isEmpty {
                out.append(TableNote(id: Self.stableID(profileID, database, t.name, []), profileID: profileID, database: database,
                                     table: t.name, columns: [], terms: tTerms, memo: t.description ?? "",
                                     source: .user, confirmed: true, createdAt: epoch))
            }
            for c in t.columns ?? [] {
                let cTerms = ([c.title].compactMap { $0 } + (c.terms ?? [])).filter { !$0.isEmpty }
                guard !cTerms.isEmpty else { continue }
                out.append(TableNote(id: Self.stableID(profileID, database, t.name, [c.name]), profileID: profileID, database: database,
                                     table: t.name, columns: [c.name], terms: cTerms, memo: c.description ?? "",
                                     source: .user, confirmed: true, createdAt: epoch))
            }
        }
        return out
    }

    static func stableID(_ profileID: UUID, _ database: String, _ table: String, _ columns: [String]) -> UUID {
        let key = "\(profileID.uuidString)|\(database)|\(table.lowercased())|\(columns.map { $0.lowercased() }.joined(separator: ","))"
        var bytes = [UInt8](repeating: 0, count: 16)
        // FNV-1a 두 번 (앞 · 뒤 8바이트)
        for (half, seed) in [(0, UInt64(0xcbf29ce484222325)), (8, UInt64(0x84222325cbf29ce4))] {
            var h = seed
            for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            for i in 0..<8 { bytes[half + i] = UInt8(truncatingIfNeeded: h >> (8 * i)) }
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// [맞아요]: 찾는 말을 그 위치(컬럼이 있으면 컬럼마다, 없으면 테이블)에 더한다. 없는 테이블 · 컬럼이면 만든다.
    public mutating func addTerms(_ terms: [String], table: String, columns: [String]) {
        let i: Int
        if let found = tables.firstIndex(where: { Self.bare($0.name) == Self.bare(table) }) {
            i = found
        } else {
            tables.append(Table(name: table))
            i = tables.count - 1
        }
        if columns.isEmpty {
            tables[i].terms = TableNoteLibrary.mergeTerms(tables[i].terms ?? [], terms)
            return
        }
        for col in columns {
            var cols = tables[i].columns ?? []
            if let j = cols.firstIndex(where: { $0.name.lowercased() == col.lowercased() }) {
                cols[j].terms = TableNoteLibrary.mergeTerms(cols[j].terms ?? [], terms)
            } else {
                cols.append(Column(name: col, terms: TableNoteLibrary.mergeTerms([], terms)))
            }
            tables[i].columns = cols
        }
    }

    /// [아니에요]: 그 위치에서 찾는 말을 뺀다 (title 은 그대로)
    public mutating func removeTerms(_ terms: [String], table: String, columns: [String]) {
        let drop = Set(terms.map(DataFinder.normalize))
        func keep(_ list: [String]?) -> [String]? {
            let kept = (list ?? []).filter { !drop.contains(DataFinder.normalize($0)) }
            return kept.isEmpty ? nil : kept
        }
        guard let i = tables.firstIndex(where: { Self.bare($0.name) == Self.bare(table) }) else { return }
        if columns.isEmpty {
            tables[i].terms = keep(tables[i].terms)
            return
        }
        let names = Set(columns.map { $0.lowercased() })
        tables[i].columns = tables[i].columns?.map { c in
            guard names.contains(c.name.lowercased()) else { return c }
            var c = c
            c.terms = keep(c.terms)
            return c
        }
    }

    // MARK: 예전 테이블 메모 옮기기

    /// 확인된 테이블 메모를 설명으로 합친다: 찾는 말 → terms, 메모 → 컬럼 하나면 description(비었을 때), 아니면 notes
    public mutating func merge(notes: [TableNote]) {
        for n in notes where n.confirmed {
            addTerms(n.terms, table: n.table, columns: n.columns)
            let memo = n.memo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !memo.isEmpty, let i = tables.firstIndex(where: { Self.bare($0.name) == Self.bare(n.table) }) else { continue }
            if n.columns.count == 1, let j = tables[i].columns?.firstIndex(where: { $0.name.lowercased() == n.columns[0].lowercased() }),
               (tables[i].columns?[j].description ?? "").isEmpty {
                tables[i].columns?[j].description = memo
            } else if n.columns.isEmpty, (tables[i].description ?? "").isEmpty {
                tables[i].description = memo
            } else {
                let line = n.columns.isEmpty ? memo : "\(n.columns.joined(separator: ", ")): \(memo)"
                if !(tables[i].notes ?? []).contains(line) { tables[i].notes = (tables[i].notes ?? []) + [line] }
            }
        }
    }
}

/// 접속 · DB 하나의 테이블 설명
public struct TableDescriptionEntry: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var database: String
    public var updatedAt: Date
    /// 가져온 파일 이름 (직접 고치거나 옮겨 온 것이면 빈칸)
    public var fileName: String
    public var doc: TableDescriptionDoc

    public init(profileID: UUID, database: String, updatedAt: Date = Date(), fileName: String = "", doc: TableDescriptionDoc) {
        self.profileID = profileID
        self.database = database
        self.updatedAt = updatedAt
        self.fileName = fileName
        self.doc = doc
    }
}

public struct TableDescriptionLibrary: Codable, Equatable, Sendable {
    public var version = 1
    public var entries: [TableDescriptionEntry] = []
    /// 예전 테이블 메모(table-notes.json)를 옮겼는지
    public var migratedNotes = false

    public init(entries: [TableDescriptionEntry] = [], migratedNotes: Bool = false) {
        self.entries = entries
        self.migratedNotes = migratedNotes
    }

    public func entry(profileID: UUID, database: String) -> TableDescriptionEntry? {
        entries.first { $0.profileID == profileID && $0.database == database }
    }

    public func doc(profileID: UUID, database: String) -> TableDescriptionDoc? {
        entry(profileID: profileID, database: database)?.doc
    }

    public mutating func set(_ entry: TableDescriptionEntry) {
        if let i = entries.firstIndex(where: { $0.profileID == entry.profileID && $0.database == entry.database }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
    }

    public mutating func remove(profileID: UUID, database: String) {
        entries.removeAll { $0.profileID == profileID && $0.database == database }
    }

    /// 설명을 고친다 (없으면 빈 설명에서 시작)
    public mutating func edit(profileID: UUID, database: String, now: Date = Date(), _ change: (inout TableDescriptionDoc) -> Void) {
        var e = entry(profileID: profileID, database: database)
            ?? TableDescriptionEntry(profileID: profileID, database: database, updatedAt: now, doc: TableDescriptionDoc(database: database))
        change(&e.doc)
        e.updatedAt = now
        set(e)
    }

    /// 예전 테이블 메모 옮기기 (확인된 것만. 한 번만)
    public mutating func migrate(_ notes: TableNoteLibrary, now: Date = Date()) {
        guard !migratedNotes else { return }
        migratedNotes = true
        let groups = Dictionary(grouping: notes.notes.filter(\.confirmed)) { "\($0.profileID.uuidString)|\($0.database)" }
        for (_, list) in groups {
            guard let first = list.first else { continue }
            edit(profileID: first.profileID, database: first.database, now: now) {
                $0.merge(notes: list.sorted { $0.createdAt < $1.createdAt })
            }
        }
    }
}

/// `table-descriptions.json` (앱 데이터 폴더, 권한 본인만)
public struct TableDescriptionStore: Sendable {
    public static let shared = TableDescriptionStore(file: AppPaths.dataDirectory.appendingPathComponent("table-descriptions.json"))

    public let file: URL

    public init(file: URL) { self.file = file }

    public static func decode(_ data: Data) throws -> TableDescriptionLibrary {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(TableDescriptionLibrary.self, from: data)
    }

    public static func encode(_ library: TableDescriptionLibrary) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(library)
    }

    public func load() -> TableDescriptionLibrary? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? Self.decode(data)
    }

    public func save(_ library: TableDescriptionLibrary) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? Self.encode(library) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// 읽고, 처음이면 예전 테이블 메모를 옮긴다 (메모 파일은 그대로 남긴다)
    public func loadMigrating(notes: TableNoteStore = .shared) -> TableDescriptionLibrary {
        var lib = load() ?? TableDescriptionLibrary()
        if !lib.migratedNotes {
            lib.migrate(notes.load())
            save(lib)
        }
        return lib
    }
}
