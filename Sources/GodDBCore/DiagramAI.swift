import Foundation

/// ER 다이어그램 AI 분석 (로컬 Ollama). 테이블 구조와 관계만 보내고 데이터 행은 보내지 않는다.
public enum DiagramAI {
    /// 보낼 스키마 글자 수 상한 (넘으면 컬럼 목록을 줄인다)
    public static let maxSchemaChars = 40_000

    /// 다이어그램에 있는 테이블 구조와 관계를 모델이 읽기 좋은 글로 만든다.
    public static func schemaText(_ tables: [TableMeta], inferred: [ForeignKeyMeta]) -> String {
        let names = Set(tables.map(\.name))
        func clip(_ s: String, _ n: Int = 80) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        func render(columnsLimit: Int?) -> String {
            var s = ""
            for t in tables {
                s += "TABLE \(t.name)" + (t.comment.isEmpty ? "" : "  -- \(clip(t.comment))") + "\n"
                let pk = Set(t.indexes.first(where: \.isPrimary)?.columns.map { $0.lowercased() } ?? [])
                let cols = columnsLimit.map { Array(t.columns.prefix($0)) } ?? t.columns
                for c in cols {
                    var line = "  \(c.name) \(c.columnType)"
                    if pk.contains(c.name.lowercased()) { line += " PK" }
                    if !c.nullable { line += " NOT NULL" }
                    if !c.comment.isEmpty { line += "  -- \(clip(c.comment, 60))" }
                    s += line + "\n"
                }
                if cols.count < t.columns.count { s += "  … (\(t.columns.count - cols.count) more columns)\n" }
                for idx in t.indexes where !idx.isPrimary {
                    s += "  INDEX \(idx.name)(\(idx.columns.joined(separator: ", ")))\(idx.unique ? " UNIQUE" : "")\n"
                }
            }
            return s
        }
        var body = render(columnsLimit: nil)
        if body.count > maxSchemaChars { body = render(columnsLimit: 12) }
        if body.count > maxSchemaChars { body = render(columnsLimit: 4) }
        if body.count > maxSchemaChars { body = String(body.prefix(maxSchemaChars)) + "\n… (truncated)\n" }

        var s = "Tables (\(tables.count)):\n" + body + "\n"
        let fks = tables.flatMap(\.foreignKeys).filter { names.contains($0.referencedTable) }
        s += "Foreign keys (declared):\n"
        s += fks.isEmpty ? "  (none)\n" : fks.map {
            "  \($0.table)(\($0.columns.joined(separator: ", "))) -> \($0.referencedTable)(\($0.referencedColumns.joined(separator: ", ")))"
        }.joined(separator: "\n") + "\n"
        let guessed = inferred.filter { names.contains($0.table) && names.contains($0.referencedTable) }
        if !guessed.isEmpty {
            s += "Relations guessed from column names (no FK constraint, may be wrong):\n"
            s += guessed.map {
                "  \($0.table)(\($0.columns.joined(separator: ", "))) -> \($0.referencedTable)(\($0.referencedColumns.joined(separator: ", ")))"
            }.joined(separator: "\n") + "\n"
        }
        return s
    }

    public static func systemPrompt(_ kind: DatabaseKind, english: Bool) -> String {
        """
        You are a senior \(kind.title) data modeler helping a developer understand a database schema shown as an ER diagram.
        You only know the table structures and relations given below — there is no row data.
        Rules:
        - Base every statement on the given tables, columns, comments, keys and relations. Do not invent tables or columns.
        - Clearly separate declared foreign keys from relations you infer; say how confident you are when inferring.
        - Use table and column comments to explain business meaning when present.
        - When showing SQL, use \(kind.title) syntax in ```sql blocks. Never suggest running DROP or DELETE.
        - Answer in \(english ? "English" : "Korean (한국어)"), concise, using Markdown headings and bullet points.
        """
    }

    /// 처음 "관계 분석" 요청 문장
    public static func analysisQuestion(english: Bool) -> String {
        if english {
            return """
            Analyze the relationships in this ER diagram:
            1. What the schema is for (domain) and the core tables
            2. Each relationship: parent → child, cardinality (1:1, 1:N, N:M via join tables)
            3. Relations that probably exist but have no FK (missing constraints) and FKs without a supporting index
            4. Modeling issues or risks (naming, nullable keys, duplicated data)
            5. A typical JOIN query that follows the main relationships
            """
        }
        return """
        이 ER 다이어그램의 관계를 분석해 주세요:
        1. 스키마의 용도(업무 도메인)와 핵심 테이블
        2. 관계별 부모 → 자식, 카디널리티 (1:1, 1:N, 연결 테이블을 통한 N:M)
        3. FK 제약은 없지만 관계로 보이는 것(빠진 제약), 인덱스가 없는 FK 컬럼
        4. 모델링상 문제나 위험 (이름 규칙, NULL 허용 키, 중복 데이터)
        5. 주요 관계를 따라가는 대표 JOIN 쿼리 예시
        """
    }

    /// 대화 전체를 Ollama 메시지로. 첫 user 메시지 앞에 스키마를 붙인다.
    public static func messages(kind: DatabaseKind, schema: String, history: [(role: String, content: String)],
                                english: Bool) -> [OllamaClient.Message] {
        var out: [OllamaClient.Message] = [.init(role: "system", content: systemPrompt(kind, english: english)),
                                           .init(role: "user", content: "Schema:\n" + schema),
                                           .init(role: "assistant", content: english ? "I have read the schema. What would you like to know?" : "스키마를 읽었어요. 무엇이 궁금하세요?")]
        out += history.map { .init(role: $0.role, content: $0.content) }
        return out
    }

    /// 모델 답에 섞여 온 <think> … </think> 를 뺀다.
    public static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<think>[\\s\\S]*?(</think>|$)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
