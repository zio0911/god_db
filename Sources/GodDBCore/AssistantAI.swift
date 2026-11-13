import Foundation

/// 테이블 크기 통계 (메타데이터만, 데이터 행 아님)
public struct TableStats: Hashable, Sendable {
    public let table: String
    /// 추정 행 수 (MySQL TABLE_ROWS / PG reltuples 는 근사값)
    public let rows: Int64?
    public let dataBytes: Int64?
    public let indexBytes: Int64?
    public let engine: String?
    public let updated: String?

    public init(table: String, rows: Int64?, dataBytes: Int64?, indexBytes: Int64?, engine: String? = nil, updated: String? = nil) {
        self.table = table
        self.rows = rows
        self.dataBytes = dataBytes
        self.indexBytes = indexBytes
        self.engine = engine
        self.updated = updated
    }
}

/// 메인 창 오른쪽 AI 어시스턴트 (로컬 Ollama)
/// 보내는 것: 테이블 구조·코멘트·인덱스·관계, 테이블 크기 통계, 자동 점검 결과, 편집기의 SQL. 데이터 행은 보내지 않는다.
public enum AssistantAI {
    public static let maxContextChars = 48_000

    // MARK: 통계

    /// [테이블, 행 수, 데이터 바이트, 인덱스 바이트, 엔진, 마지막 수정] — 실패해도 괜찮은 보조 정보
    public static func statsSQL(_ kind: DatabaseKind, schema: String) -> String? {
        let s = SQLText.quoteString(schema)
        switch kind {
        case .mysql:
            return """
            SELECT TABLE_NAME, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, ENGINE, UPDATE_TIME
              FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = \(s) AND TABLE_TYPE = 'BASE TABLE'
            """
        case .postgres:
            return """
            SELECT c.relname, c.reltuples::bigint, pg_table_size(c.oid), pg_indexes_size(c.oid), NULL, NULL
              FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = \(s) AND c.relkind IN ('r', 'p')
            """
        case .mssql:
            return """
            SELECT CASE WHEN s.name = 'dbo' THEN t.name ELSE s.name + '.' + t.name END,
                   SUM(CASE WHEN p.index_id IN (0, 1) THEN p.row_count ELSE 0 END),
                   SUM(CASE WHEN p.index_id IN (0, 1) THEN p.used_page_count ELSE 0 END) * 8192,
                   SUM(CASE WHEN p.index_id > 1 THEN p.used_page_count ELSE 0 END) * 8192, NULL, NULL
              FROM sys.dm_db_partition_stats p
              JOIN sys.tables t ON t.object_id = p.object_id
              JOIN sys.schemas s ON s.schema_id = t.schema_id
             GROUP BY s.name, t.name
            """
        case .redis:
            return nil
        }
    }

    public static func parseStats(_ rows: [[String?]]) -> [String: TableStats] {
        var out: [String: TableStats] = [:]
        for r in rows where r.count >= 4 {
            guard let name = r[0] else { continue }
            func n(_ v: String?) -> Int64? { v.flatMap { Int64($0) ?? Double($0).map { Int64($0) } } }
            out[name.lowercased()] = TableStats(table: name, rows: n(r[1]).map { max(0, $0) }, dataBytes: n(r[2]), indexBytes: n(r[3]),
                                                engine: r.count > 4 ? r[4] : nil, updated: r.count > 5 ? r[5] : nil)
        }
        return out
    }

    static func size(_ b: Int64?) -> String {
        guard let b else { return "?" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
    }

    // MARK: 자동 점검 (특이사항)

    /// 규칙으로 찾은 특이사항 (AI 없이도 보여줄 수 있는 것)
    public static func notes(_ t: TableMeta, stats: TableStats?) -> [String] {
        var out: [String] = []
        let pk = t.indexes.first(where: \.isPrimary)
        if pk == nil && !t.columns.contains(where: \.isPrimaryKey) { out.append("no primary key") }
        if t.comment.trimmingCharacters(in: .whitespaces).isEmpty { out.append("no table comment") }
        let noComment = t.columns.filter { $0.comment.trimmingCharacters(in: .whitespaces).isEmpty }
        if !noComment.isEmpty, t.columns.count > 0 {
            out.append("\(noComment.count)/\(t.columns.count) columns without comment")
        }
        // FK 컬럼이 인덱스 맨 앞에 없음
        for fk in t.foreignKeys {
            let first = fk.columns.first?.lowercased() ?? ""
            if !t.indexes.contains(where: { $0.columns.first?.lowercased() == first }) {
                out.append("FK \(fk.name)(\(fk.columns.joined(separator: ","))) has no index starting with it")
            }
            let nullable = fk.columns.filter { c in t.columns.first { $0.name.lowercased() == c.lowercased() }?.nullable == true }
            if !nullable.isEmpty { out.append("nullable FK column \(nullable.joined(separator: ","))") }
        }
        // 다른 인덱스의 앞부분과 같은 인덱스 (중복 가능성)
        for a in t.indexes where !a.isPrimary {
            for b in t.indexes where b.name != a.name && b.columns.count > a.columns.count {
                if Array(b.columns.prefix(a.columns.count)).map({ $0.lowercased() }) == a.columns.map({ $0.lowercased() }), !a.unique {
                    out.append("index \(a.name) is a prefix of \(b.name) (possibly redundant)")
                    break
                }
            }
        }
        if t.indexes.filter({ !$0.isPrimary }).count >= 8 { out.append("many indexes (\(t.indexes.count)) — write cost") }
        if let rows = stats?.rows, rows >= 1_000_000 { out.append("large table (~\(rows) rows)") }
        let lob = t.columns.filter { ["text", "longtext", "mediumtext", "blob", "longblob", "json", "jsonb", "bytea"]
            .contains($0.columnType.lowercased()) || $0.columnType.lowercased().hasSuffix("(max)") }
        if lob.count >= 3 { out.append("\(lob.count) large-object columns (\(lob.map(\.name).joined(separator: ",")))") }
        return out
    }

    // MARK: 문맥

    /// 질문·선택에서 자세히 볼 테이블 고르기: 이름(물리명) 또는 코멘트 첫 줄(논리명)이 질문에 나오면
    public static func mentionedTables(_ text: String, in tables: [TableMeta], limit: Int = 12) -> [TableMeta] {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return [] }
        var hits: [(TableMeta, Int)] = []
        for t in tables {
            let name = t.name.lowercased()
            let bare = name.split(separator: ".").last.map(String.init) ?? name
            if let r = lower.range(of: bare), isBoundary(lower, r) {
                hits.append((t, lower.distance(from: lower.startIndex, to: r.lowerBound)))
                continue
            }
            let logical = t.comment.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if logical.count >= 2, logical.count <= 30, let r = lower.range(of: logical.lowercased()) {
                hits.append((t, lower.distance(from: lower.startIndex, to: r.lowerBound)))
            }
        }
        return hits.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    static func isBoundary(_ s: String, _ r: Range<String.Index>) -> Bool {
        func word(_ c: Character) -> Bool { c.isLetter && c.isASCII || c.isNumber || c == "_" }
        let before = r.lowerBound == s.startIndex ? nil : s[s.index(before: r.lowerBound)]
        let after = r.upperBound == s.endIndex ? nil : s[r.upperBound]
        return !(before.map(word) ?? false) && !(after.map(word) ?? false)
    }

    public struct Context: Sendable {
        public var kind: DatabaseKind
        public var connection: String
        public var database: String
        public var tables: [TableMeta]
        public var focus: [TableMeta]
        public var stats: [String: TableStats]
        public var sql: String?
        public var lastError: String?

        public init(kind: DatabaseKind, connection: String, database: String, tables: [TableMeta], focus: [TableMeta],
                    stats: [String: TableStats] = [:], sql: String? = nil, lastError: String? = nil) {
            self.kind = kind
            self.connection = connection
            self.database = database
            self.tables = tables
            self.focus = focus
            self.stats = stats
            self.sql = sql
            self.lastError = lastError
        }
    }

    /// 모델이 읽을 문맥 글
    public static func contextText(_ c: Context) -> String {
        var s = "Connection: \(c.connection) (\(c.kind.title))\nDatabase/schema: \(c.database)\n"
        s += "Tables in this database: \(c.tables.count)\n"
        // 전체 목록 (이름 + 논리명 + 대략 크기)
        var list = ""
        for t in c.tables {
            var line = "  \(t.name)"
            if let l = t.comment.split(whereSeparator: \.isNewline).first, !l.isEmpty { line += " — \(l.prefix(40))" }
            if let st = c.stats[t.name.lowercased()], let r = st.rows { line += "  (~\(r) rows)" }
            list += line + "\n"
            if list.count > 12_000 { list += "  … (\(c.tables.count) tables total, list truncated)\n"; break }
        }
        s += list
        if !c.focus.isEmpty {
            s += "\nDetailed structure of the relevant tables:\n"
            let inferred = DiagramLayout.inferredRelations(c.tables)
            s += DiagramAI.schemaText(c.focus, inferred: inferred)
            s += "\nSize and automatic checks:\n"
            for t in c.focus {
                let st = c.stats[t.name.lowercased()]
                var line = "  \(t.name):"
                if let st {
                    line += " rows≈\(st.rows.map(String.init) ?? "?"), data \(size(st.dataBytes)), index \(size(st.indexBytes))"
                    if let e = st.engine, !e.isEmpty { line += ", engine \(e)" }
                    if let u = st.updated, !u.isEmpty { line += ", updated \(u)" }
                }
                let n = notes(t, stats: st)
                line += n.isEmpty ? " no issues found" : "\n    - " + n.joined(separator: "\n    - ")
                s += line + "\n"
            }
            // 참조하는 쪽 (다른 테이블이 이 테이블을 가리킴)
            let names = Set(c.focus.map { $0.name.lowercased() })
            let incoming = c.tables.flatMap(\.foreignKeys).filter { names.contains($0.referencedTable.lowercased()) && !names.contains($0.table.lowercased()) }
            if !incoming.isEmpty {
                s += "Tables referencing them (FK): " + incoming.map { "\($0.table)(\($0.columns.joined(separator: ",")))→\($0.referencedTable)" }
                    .joined(separator: ", ") + "\n"
            }
        }
        if let sql = c.sql?.trimmingCharacters(in: .whitespacesAndNewlines), !sql.isEmpty {
            s += "\nSQL currently in the editor:\n```sql\n\(sql.prefix(8_000))\n```\n"
        }
        if let e = c.lastError, !e.isEmpty {
            s += "\nLast error in the editor:\n\(e.prefix(2_000))\n"
        }
        if s.count > maxContextChars { s = String(s.prefix(maxContextChars)) + "\n… (truncated)\n" }
        return s
    }

    public static func systemPrompt(_ kind: DatabaseKind, english: Bool) -> String {
        """
        You are GodDB's database assistant, helping a developer working with a \(kind.title) database.
        You receive metadata only: table structures, comments (business names), keys, indexes, relations, approximate sizes,
        automatic checks and the SQL in the editor. You never see row data — if the answer needs data, give a SELECT the user can run.
        Rules:
        - Base statements on the given metadata. Do not invent tables or columns; say when something is not in the context.
        - Use comments to explain business meaning. Mention notable points (missing keys/indexes, nullable FKs, large tables).
        - SQL in \(kind.title) syntax inside ```sql blocks. Never run or recommend DROP/TRUNCATE/DELETE without a WHERE and a warning.
        - You also get a short GodDB manual and the current app state. For questions about GodDB itself (who made it,
          how to use a feature, shortcuts, where settings are) answer from that manual; do not invent menus or features.
        - Answer in \(english ? "English" : "Korean (한국어)"), concise, using Markdown headings and bullet points.
        """
    }

    public static func messages(kind: DatabaseKind, context: String, history: [(role: String, content: String)],
                                english: Bool) -> [OllamaClient.Message] {
        var out: [OllamaClient.Message] = [.init(role: "system", content: systemPrompt(kind, english: english))]
        // 대화 기록 앞부분은 그대로, 마지막 질문 바로 앞에 최신 문맥을 넣는다 (테이블을 바꿔 물어도 맞는 정보)
        let earlier = history.dropLast()
        out += earlier.map { .init(role: $0.role, content: $0.content) }
        out.append(.init(role: "user", content: "Context (current state, metadata only):\n" + context))
        out.append(.init(role: "assistant", content: english ? "Got the context." : "문맥을 확인했어요."))
        if let last = history.last { out.append(.init(role: last.role, content: last.content)) }
        return out
    }
}

// MARK: - 모델링 AI

public enum ModelAI {
    /// 모델을 글로 (짧은 키 T1, T1.C2 로 물리명 추천 결과를 다시 맞춘다)
    public static func modelText(_ m: DataModel) -> String {
        var s = "Data model \"\(m.name)\" for \(m.kind.title): \(m.tables.count) tables, \(m.relations.count) relations\n"
        for (ti, t) in m.tables.enumerated() {
            s += "T\(ti + 1) \(t.logicalName.isEmpty ? "(no logical name)" : t.logicalName) [physical: \(t.physicalName.isEmpty ? "-" : t.physicalName)]"
            if !t.comment.isEmpty { s += " — \(t.comment.prefix(80))" }
            s += "\n"
            for (ci, c) in t.columns.enumerated() {
                var line = "  T\(ti + 1).C\(ci + 1) \(c.logicalName.isEmpty ? "-" : c.logicalName) [physical: \(c.physicalName.isEmpty ? "-" : c.physicalName)] \(c.dataType)"
                if c.primaryKey { line += " PK" }
                if c.notNull { line += " NOT NULL" }
                if c.unique { line += " UNIQUE" }
                if c.autoIncrement { line += " AUTO_INCREMENT" }
                if !c.defaultValue.isEmpty { line += " DEFAULT \(c.defaultValue)" }
                if !c.comment.isEmpty { line += " — \(c.comment.prefix(60))" }
                s += line + "\n"
            }
        }
        s += "Relations:\n"
        for r in m.relations {
            s += "  \(m.table(r.parent)?.displayName ?? "?") 1 — \(r.cardinality == .oneToOne ? "1" : "N") \(m.table(r.child)?.displayName ?? "?")"
            s += r.identifying ? " (identifying)" : " (non-identifying)"
            s += r.createConstraint ? "" : " (logical only, no FK constraint)"
            s += "\n"
        }
        if s.count > AssistantAI.maxContextChars { s = String(s.prefix(AssistantAI.maxContextChars)) + "\n… (truncated)\n" }
        return s
    }

    public static func physicalNameQuestion(english: Bool, kind: DatabaseKind) -> String {
        let rules = """
        Suggest physical (database) names for tables and columns whose physical name is "-".
        Use English snake_case, lowercase, \(kind == .mssql ? "" : "")common abbreviations (e.g. 회원→member, 일시→_at or _dt, 여부→is_/yn, 코드→_cd).
        Table names start with "tb_". Keep existing physical names unchanged and keep naming consistent across tables.
        Reply with a short explanation, then exactly one ```json block in this form:
        {"tables":[{"key":"T1","physical":"tb_member","columns":[{"key":"T1.C2","physical":"email"}]}]}
        Include only items that had no physical name.
        """
        return english ? rules : "논리명을 보고 물리명이 비어 있는(-) 테이블·컬럼의 물리명을 추천해 주세요.\n" + rules
    }

    /// AI 답의 JSON 을 모델에 적용. overwrite 가 false 면 비어 있는 물리명만. 바뀐 개수를 돌려준다.
    @discardableResult
    public static func applyPhysicalNames(_ answer: String, to m: inout DataModel, overwrite: Bool = false) -> Int {
        guard let json = jsonBlock(answer), let data = json.data(using: .utf8) else { return 0 }
        struct Col: Decodable { let key: String; let physical: String }
        struct Tab: Decodable { let key: String; let physical: String?; let columns: [Col]? }
        struct Root: Decodable { let tables: [Tab] }
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else { return 0 }
        let ident = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")
        func ok(_ s: String) -> Bool { ident.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        var changed = 0
        for t in root.tables {
            guard t.key.hasPrefix("T"), let ti = Int(t.key.dropFirst()).map({ $0 - 1 }), m.tables.indices.contains(ti) else { continue }
            if let p = t.physical?.trimmingCharacters(in: .whitespaces), ok(p), overwrite || m.tables[ti].physicalName.isEmpty,
               m.tables[ti].physicalName != p {
                m.tables[ti].physicalName = p
                changed += 1
            }
            for c in t.columns ?? [] {
                let parts = c.key.split(separator: ".")
                guard parts.count == 2, parts[1].hasPrefix("C"), let ci = Int(parts[1].dropFirst()).map({ $0 - 1 }),
                      m.tables[ti].columns.indices.contains(ci) else { continue }
                let p = c.physical.trimmingCharacters(in: .whitespaces)
                if ok(p), overwrite || m.tables[ti].columns[ci].physicalName.isEmpty, m.tables[ti].columns[ci].physicalName != p {
                    m.tables[ti].columns[ci].physicalName = p
                    changed += 1
                }
            }
        }
        if changed > 0 { m.touch() }
        return changed
    }

    static func jsonBlock(_ text: String) -> String? {
        if let r = text.range(of: "```json\\s*\\n([\\s\\S]*?)```", options: .regularExpression) {
            return String(text[r]).replacingOccurrences(of: "^```json\\s*\\n", with: "", options: .regularExpression)
                .replacingOccurrences(of: "```$", with: "", options: .regularExpression)
        }
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b { return String(text[a...b]) }
        return nil
    }

    public static func systemPrompt(_ kind: DatabaseKind, english: Bool) -> String {
        """
        You are a senior data modeler reviewing a logical/physical data model that will be generated as \(kind.title) DDL.
        Tables are referenced as T1, T2…, columns as T1.C1… Logical names are business names (often Korean).
        - Review normalization, keys, relationships (identifying vs non-identifying, cardinality), naming and data types.
        - Be concrete: name the table/column and what to change. Do not invent requirements the model does not imply.
        - SQL in \(kind.title) syntax inside ```sql blocks.
        - A short GodDB manual is included; answer questions about the app itself (author, how to use modeling) from it.
        - Answer in \(english ? "English" : "Korean (한국어)"), concise, Markdown headings and bullets.
        """
    }
}
