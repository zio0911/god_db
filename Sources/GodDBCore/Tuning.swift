import Foundation

/// 쿼리 튜닝에 필요한 정보. 실제 데이터 행은 담지 않는다.
public struct TuningContext: Sendable {
    public struct Table: Sendable {
        public let meta: TableMeta
        public let ddl: String
        public let estimatedRows: Int?
    }

    public let kind: DatabaseKind
    public let version: String
    public let sql: String
    public let tables: [Table]
    public let plan: QueryResult?
    public let planTree: String?
    public let warnings: [PlanAnalyzer.Warning]
    /// 실행 계획을 못 얻은 이유 (있으면)
    public let planError: String?
}

extension SQLDialect {
    /// 통계상 예상 행 수 (정확한 COUNT 가 아님 — 빠름)
    public func rowEstimateSQL(_ table: String, schema: String) -> String {
        switch kind {
        case .mysql, .redis:
            return "SELECT TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(quoteString(schema)) AND TABLE_NAME = \(quoteString(table))"
        case .postgres:
            return """
            SELECT c.reltuples::bigint FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = \(quoteString(schema)) AND c.relname = \(quoteString(table))
            """
        case .mssql:
            return "SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = OBJECT_ID(\(quoteString(quoteTable(table)))) AND p.index_id IN (0, 1)"
        }
    }
}

extension DBSession {
    /// 쿼리에 나온 테이블의 구조·인덱스·예상 행 수와 실행 계획을 모은다.
    public func tuningContext(sql: String, knownTables: [TableMeta]) async -> TuningContext {
        let version = (try? await serverVersion()) ?? profile.kind.title
        let byName = Dictionary(knownTables.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var tables: [TuningContext.Table] = []
        for name in SQLCompleter.aliases(in: sql).values {
            guard let meta = byName[name.lowercased()], seen.insert(meta.name).inserted else { continue }
            let rows = try? await raw(dialect.rowEstimateSQL(meta.name, schema: current)).rows.first?.first
            tables.append(.init(meta: meta, ddl: dialect.createTableSQL(meta),
                                estimatedRows: rows.flatMap { $0.flatMap { Int(Double($0) ?? -1) } }.flatMap { $0 >= 0 ? $0 : nil }))
        }
        var plan: QueryResult? = nil
        var tree: String? = nil
        var planError: String? = nil
        do {
            (plan, tree) = try await explain(sql)
        } catch {
            planError = ErrorText.describe(error).message
        }
        return TuningContext(kind: profile.kind, version: version, sql: sql, tables: tables,
                             plan: plan, planTree: tree, warnings: plan.map(PlanAnalyzer.warnings) ?? [],
                             planError: planError)
    }
}

/// Ollama 에 보낼 프롬프트
public enum TuningPrompt {
    public static func messages(_ c: TuningContext, english: Bool) -> [OllamaClient.Message] {
        [.init(role: "system", content: system(c.kind, english: english)),
         .init(role: "user", content: user(c, english: english))]
    }

    static func system(_ kind: DatabaseKind, english: Bool) -> String {
        let lang = english ? "English" : "Korean (한국어)"
        return """
        You are a senior \(kind.title) performance tuning expert.
        Analyze the query, table structures, indexes, row estimates and execution plan given by the user.
        Rules:
        - The improved query MUST return exactly the same result as the original (same rows, columns and order semantics).
        - Use only tables and columns that appear in the given structures. Do not invent names.
        - Write SQL in \(kind.title) syntax.
        - If the query is already fine, say so and repeat the original query.
        - Only suggest indexes that clearly help this query. Do not suggest dropping anything.
        - Answer in \(lang). Use exactly these four sections and headings, in this order:

        ## \(english ? "Summary" : "요약")
        (1-3 sentences: the main problem and the expected effect)

        ## \(english ? "Improved SQL" : "개선 SQL")
        ```sql
        (the full improved query)
        ```

        ## \(english ? "Recommended indexes" : "추천 인덱스")
        ```sql
        (CREATE INDEX statements, or a SQL comment saying none are needed)
        ```

        ## \(english ? "Explanation" : "설명")
        (bullet points: what changed and why, referring to the execution plan)
        """
    }

    static func user(_ c: TuningContext, english: Bool) -> String {
        var s = "Database: \(c.version)\n\n"
        s += "Query to tune:\n```sql\n\(c.sql)\n```\n\n"
        if c.tables.isEmpty {
            s += "Table structures: (not found in the current schema)\n\n"
        } else {
            s += "Table structures (DDL, including indexes):\n"
            for t in c.tables {
                s += "```sql\n\(t.ddl)\n```\n"
                if let n = t.estimatedRows { s += "Estimated rows in \(t.meta.name): \(n)\n" }
                s += "\n"
            }
        }
        if let plan = c.plan {
            s += "Execution plan:\n" + table(plan, maxRows: 60) + "\n"
            if let tree = c.planTree, !tree.isEmpty, tree.count < 6000 {
                s += "Execution plan (tree):\n```\n\(tree)\n```\n"
            }
        } else if let e = c.planError {
            s += "Execution plan: unavailable (\(e))\n"
        }
        if !c.warnings.isEmpty {
            s += "\nAutomatic plan warnings:\n" + c.warnings.map { "- [\($0.table)] \($0.message)" }.joined(separator: "\n") + "\n"
        }
        return s
    }

    /// 결과를 사람이 읽는 표로 (값이 길면 자른다)
    static func table(_ r: QueryResult, maxRows: Int) -> String {
        var lines = [r.columns.map(\.name).joined(separator: " | ")]
        for row in r.rows.prefix(maxRows) {
            lines.append(row.values.map { v in
                let s = (v ?? "NULL").replacingOccurrences(of: "\n", with: " ")
                return s.count > 200 ? String(s.prefix(200)) + "…" : s
            }.joined(separator: " | "))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// 모델 답변을 화면용으로 나눈다.
public struct TuningResult: Sendable, Equatable {
    public var summary: String
    public var improvedSQL: String?
    public var indexSQL: String?
    public var explanation: String
    public var raw: String

    /// 추천 인덱스가 실제로 있는지 (주석만 있으면 없음)
    public var hasIndexes: Bool {
        guard let sql = indexSQL else { return false }
        return sql.range(of: "CREATE\\s+(UNIQUE\\s+)?(NONCLUSTERED\\s+|CLUSTERED\\s+)?INDEX", options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func parse(_ text: String) -> TuningResult {
        // 혹시 섞여 온 <think> … </think> 는 버린다.
        var body = text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // ```sql … ``` 블록
        let blockRegex = try! NSRegularExpression(pattern: "```(?:sql|SQL)?\\s*\\n([\\s\\S]*?)```")
        let ns = body as NSString
        let blocks = blockRegex.matches(in: body, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let isIndex: (String) -> Bool = {
            $0.range(of: "CREATE\\s+(UNIQUE\\s+)?(NONCLUSTERED\\s+|CLUSTERED\\s+)?INDEX", options: [.regularExpression, .caseInsensitive]) != nil
        }

        // ## 제목 단위로 나눈다
        var sections: [(title: String, text: String)] = []
        var currentTitle = ""
        var currentText = ""
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("#") {
                if !currentTitle.isEmpty || !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sections.append((currentTitle, currentText))
                }
                currentTitle = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                currentText = ""
            } else {
                currentText += line + "\n"
            }
        }
        sections.append((currentTitle, currentText))

        func section(_ keys: [String]) -> String? {
            sections.first { s in keys.contains { s.title.contains($0) } }?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func firstBlock(in text: String?) -> String? {
            guard let text else { return nil }
            let t = text as NSString
            return blockRegex.firstMatch(in: text, range: NSRange(location: 0, length: t.length))
                .map { t.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        let improved = firstBlock(in: section(["개선", "improved", "optimized"]))
            ?? blocks.first { !isIndex($0) }
        let index = firstBlock(in: section(["인덱스", "index"])) ?? blocks.first(where: isIndex)
        let summary = section(["요약", "summary"]) ?? body.components(separatedBy: "\n\n").first ?? ""
        let explanation = section(["설명", "explanation"]) ?? ""
        return TuningResult(summary: summary, improvedSQL: improved?.isEmpty == false ? improved : nil,
                            indexSQL: index?.isEmpty == false ? index : nil,
                            explanation: explanation, raw: body)
    }
}
