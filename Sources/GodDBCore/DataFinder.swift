import Foundation

/// AI 데이터 찾기: "학년 정보는 어디 있어?" → 그 데이터가 든 테이블 · 컬럼을 찾는다. (명세 docs/specs/1.4.0.md · F7)
/// 1) 테이블 메모 먼저 → 2) 로컬 AI 가 후보를 고르고 → 3) 앱이 후보 컬럼 값 몇 개를 조회 → 4) 로컬 AI 가 판단.
/// AI 는 모두 로컬 Ollama(OllamaClient, localhost 만)로만 보낸다. 샘플 값은 이 기능에서만 보낸다.
public enum DataFinder {
    /// 후보 최대 개수
    public static let maxCandidates = 5
    /// 후보 고르기에 보낼 구조 글의 글자 예산 (넘으면 핵심어와 겹치는 테이블 먼저)
    public static let defaultBudget = 20_000
    /// 샘플 조회: 가져올 행 수 · 남길 값 수 · 값 길이 · 제한 시간
    public static let sampleRows = 200
    public static let maxSamples = 20
    public static let maxSampleLength = 50
    public static let sampleTimeout: Double = 5

    // MARK: - 질문 판단

    /// "…어디 있어" "…어딨어" "where is …" "which table …" 꼴인지. 애매하면 false (일반 질문으로).
    public static func isFindQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 80, !t.contains("\n") else { return false }
        let lower = t.lowercased()
        // SQL 이 들어 있거나 성능 · 오류 · 크기를 묻는 질문은 일반 질문
        if lower.range(of: #"\b(select|insert|update|delete)\b"#, options: .regularExpression) != nil {
            return false
        }
        let unrelated = ["느려", "느린", "오류", "에러", "문제", "원인", "잘못", "인덱스", "가장", "제일", "크기",
                         "error", "slow", "wrong", "bug", "index", "most", "largest", "biggest", "fail"]
        if unrelated.contains(where: { lower.contains($0) }) { return false }
        let patterns = [
            #"(은|는|이|가)?\s*어디\s*(에서|에|서)?\s*(있|저장|들어)"#,
            #"(어디야|어딨어|어딨나|어딨지|어딨니|어딨어요|어디예요|어디에요)"#,
            #"^\s*where\s+(is|are)\b"#,
            #"\bwhich\s+tables?\b"#,
        ]
        guard patterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) else { return false }
        return !keyTerms(t).isEmpty
    }

    // MARK: - 핵심어

    /// 조사 (긴 것부터)
    static let particles = ["에서는", "에서", "으로", "에는", "이랑", "까지", "부터", "은", "는", "이", "가", "을", "를",
                            "의", "에", "도", "만", "로", "와", "과", "랑"]
    /// 핵심어가 아닌 말
    static let fillers: Set<String> = [
        "정보", "데이터", "자료", "값", "내용", "위치", "어디", "어느", "무슨", "어떤", "테이블", "컬럼", "칼럼", "필드", "관련",
        "있어", "있나", "있니", "있지", "있는지", "있어요", "있나요", "저장", "좀", "찾아", "찾아줘", "알려", "알려줘", "혹시",
        "where", "is", "are", "the", "a", "an", "which", "table", "tables", "column", "columns", "stored", "store", "kept",
        "data", "info", "information", "of", "in", "for", "find", "does", "do", "what", "live", "lives", "located", "i",
        "can", "me", "my", "it", "has", "have", "holds", "hold", "contains", "contain", "field", "fields", "value", "values",
    ]

    /// 질문의 핵심어 (조사 · 군말 · "어디/있어" 같은 물음말을 뺀 명사). "학년 정보는 어딨어?" → ["학년"]
    public static func keyTerms(_ text: String) -> [String] {
        let tokens = text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
        var seen = Set<String>()
        var out: [String] = []
        for raw in tokens {
            if raw.hasPrefix("어디") || raw.hasPrefix("어딨") { continue }
            if ["있", "저장", "들어", "보관", "찾"].contains(where: { raw.hasPrefix($0) }) { continue }
            var word = raw
            if isHangul(word) {
                for p in particles where word.hasSuffix(p) && word.count - p.count >= 2 {
                    word = String(word.dropLast(p.count))
                    break
                }
            }
            if fillers.contains(word) || fillers.contains(raw) { continue }
            if !isHangul(word) && word.count < 2 { continue }
            if seen.insert(word).inserted { out.append(word) }
        }
        return out
    }

    static func isHangul(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }

    /// 비교용 정규화: 공백 제거 · 소문자 (한글은 그대로)
    public static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { !$0.isWhitespace })
    }

    /// 메모 제목 · 저장용 찾는 말: 핵심어를 한 말로 ("회원 주소")
    public static func phrase(_ terms: [String]) -> String {
        terms.joined(separator: " ")
    }

    // MARK: - 메모 먼저

    /// 이 접속 · DB 의 메모 중 질문 핵심어와 맞는 것 (확인된 것 먼저, 최근 순).
    /// 맞음: 메모의 찾는 말 하나가 핵심어 전체(공백 없이)와 같거나, 핵심어가 모두 메모의 찾는 말에 있음.
    public static func matchNotes(terms: [String], in notes: [TableNote]) -> [TableNote] {
        let q = terms.map(normalize).filter { !$0.isEmpty }
        guard !q.isEmpty else { return [] }
        let joined = q.joined()
        return notes.filter { n in
            let nt = Set(n.terms.map(normalize))
            return nt.contains(joined) || q.allSatisfy(nt.contains)
        }
        .sorted { a, b in a.confirmed != b.confirmed ? a.confirmed : a.updatedAt > b.updatedAt }
    }

    // MARK: - 후보 고르기 (로컬 AI 1차)

    public struct Candidate: Equatable, Sendable {
        public var table: String
        public var columns: [String]
        public var reason: String

        public init(table: String, columns: [String], reason: String = "") {
            self.table = table
            self.columns = columns
            self.reason = reason
        }

        public var location: String { "\(table).\(columns.joined(separator: ", "))" }
    }

    /// 테이블이 핵심어와 얼마나 겹치는지 (이름 · 코멘트 3, 컬럼 이름 · 코멘트 2)
    static func relevance(_ t: TableMeta, terms: [String]) -> Int {
        let name = normalize(t.name)
        let comment = normalize(t.comment)
        var score = 0
        for term in terms.map(normalize) where !term.isEmpty {
            if name.contains(term) || comment.contains(term) { score += 3 }
            if t.columns.contains(where: { normalize($0.name).contains(term) || normalize($0.comment).contains(term) }) { score += 2 }
        }
        return score
    }

    static func firstLine(_ s: String, max: Int) -> String {
        String((s.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").prefix(max))
    }

    static func tableBlock(_ t: TableMeta) -> String {
        var s = t.name
        let c = firstLine(t.comment, max: 80)
        if !c.isEmpty { s += " — \(c)" }
        s += "\n"
        for col in t.columns {
            var line = "  \(col.name) \(col.columnType)"
            let cc = firstLine(col.comment, max: 60)
            if !cc.isEmpty { line += " — \(cc)" }
            s += line + "\n"
        }
        return s
    }

    /// 보낼 구조 글. 예산을 넘으면 핵심어와 겹치는 테이블 먼저, 자리가 모자라면 이름 줄만.
    /// - Returns: 글, 보낸 테이블 수
    public static func schemaText(tables: [TableMeta], terms: [String], budget: Int = defaultBudget) -> (text: String, count: Int) {
        let ranked = tables.enumerated()
            .map { (i: $0.offset, t: $0.element, score: relevance($0.element, terms: terms)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.i < $1.i }
        var text = ""
        var count = 0
        for r in ranked {
            let block = tableBlock(r.t)
            if text.count + block.count <= budget {
                text += block
            } else {
                var line = r.t.name
                let c = firstLine(r.t.comment, max: 40)
                if !c.isEmpty { line += " — \(c)" }
                line += "\n"
                guard text.count + line.count <= budget else { break }
                text += line
            }
            count += 1
        }
        if count < tables.count { text += "… (\(tables.count - count) more tables not shown)\n" }
        return (text, count)
    }

    static func candidateSystemPrompt(_ kind: DatabaseKind, english: Bool) -> String {
        """
        You help a developer find where data lives in a \(kind.title) database.
        You receive a question, the tables (name — comment) with their columns (name type — comment), and locations the team saved before.
        Pick at most \(maxCandidates) candidate tables/columns that most likely hold the data in the question, best first.
        Use only tables and columns from the list. Comments are business names (often Korean) — rely on them.
        Reply with JSON only, no other text, in exactly this form:
        {"candidates":[{"table":"…","columns":["…"],"reason":"…"}]}
        "reason" is one short sentence in \(english ? "English" : "Korean (한국어)").
        """
    }

    public static let retryPrompt = """
    That reply was not in the required form. Reply again with JSON only, no other text:
    {"candidates":[{"table":"…","columns":["…"],"reason":"…"}]}
    """

    /// 1차 요청 메시지와 보낸 테이블 수
    public static func candidateMessages(question: String, terms: [String], kind: DatabaseKind, tables: [TableMeta],
                                         notes: [TableNote], english: Bool,
                                         budget: Int = defaultBudget) -> (messages: [OllamaClient.Message], tablesSent: Int) {
        let schema = schemaText(tables: tables, terms: terms, budget: budget)
        var user = "Question: \(question)\nKey terms: \(terms.joined(separator: ", "))\n\nTables (\(tables.count)):\n\(schema.text)"
        if !notes.isEmpty {
            user += "\nLocations saved by the team:\n"
            for n in notes.prefix(50) {
                user += "  - \(n.terms.joined(separator: ", ")) → \(n.location)\(n.confirmed ? "" : " (unconfirmed)")\n"
            }
        }
        return ([.init(role: "system", content: candidateSystemPrompt(kind, english: english)), .init(role: "user", content: user)],
                schema.count)
    }

    /// 대소문자 · 스키마 접두어를 무시하고 실제 테이블 찾기
    static func resolveTable(_ name: String, in tables: [TableMeta]) -> TableMeta? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "`\"[]"))
            .lowercased()
        guard !n.isEmpty else { return nil }
        if let t = tables.first(where: { $0.name.lowercased() == n }) { return t }
        let bare = n.split(separator: ".").last.map(String.init) ?? n
        let hits = tables.filter { ($0.name.lowercased().split(separator: ".").last.map(String.init) ?? "") == bare }
        return hits.count == 1 ? hits[0] : nil
    }

    static func resolveColumns(_ names: [String], in t: TableMeta) -> [String] {
        var out: [String] = []
        for raw in names {
            let n = (raw.split(separator: ".").last.map(String.init) ?? raw)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`\"[] ")).lowercased()
            if let c = t.columns.first(where: { $0.name.lowercased() == n }), !out.contains(c.name) { out.append(c.name) }
        }
        return out
    }

    /// 답에서 JSON 객체 꺼내기 (```json 블록 또는 첫 { ~ 마지막 })
    static func jsonObject(_ reply: String) -> [String: Any]? {
        guard let block = ModelAI.jsonBlock(reply), let data = block.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static func stringList(_ v: Any?) -> [String] {
        if let a = v as? [Any] { return a.compactMap { $0 as? String } }
        if let s = v as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return []
    }

    /// 1차 답 읽기. 형식이 틀리면 nil (다시 요청), 맞으면 없는 테이블 · 컬럼을 버린 후보 (최대 5개, 비어 있을 수 있음).
    public static func parseCandidates(_ reply: String, tables: [TableMeta]) -> [Candidate]? {
        guard let obj = jsonObject(reply), let list = obj["candidates"] as? [Any] else { return nil }
        var out: [Candidate] = []
        for case let item as [String: Any] in list {
            guard let name = item["table"] as? String, let t = resolveTable(name, in: tables) else { continue }
            var cols = stringList(item["columns"])
            if let one = item["column"] as? String { cols.append(one) }
            let resolved = resolveColumns(cols, in: t)
            guard !resolved.isEmpty else { continue }
            let c = Candidate(table: t.name, columns: resolved, reason: (item["reason"] as? String) ?? "")
            if !out.contains(where: { $0.table == c.table && $0.columns == c.columns }) { out.append(c) }
            if out.count == maxCandidates { break }
        }
        return out
    }

    /// AI 없이: 이름 · 코멘트 키워드 일치 순 (컬럼 코멘트 3 · 컬럼 이름 2, 테이블 이름 · 코멘트 1)
    public static func fallbackCandidates(terms: [String], tables: [TableMeta], limit: Int = maxCandidates) -> [Candidate] {
        let q = terms.map(normalize).filter { !$0.isEmpty }
        guard !q.isEmpty else { return [] }
        var scored: [(c: Candidate, score: Int, i: Int)] = []
        for (i, t) in tables.enumerated() {
            let tableText = normalize(t.name) + " " + normalize(t.comment)
            let tableScore = q.filter { tableText.contains($0) }.count
            var cols: [(name: String, score: Int)] = []
            for col in t.columns {
                var s = 0
                for term in q {
                    if normalize(col.comment).contains(term) { s += 3 }
                    if normalize(col.name).contains(term) { s += 2 }
                }
                if s > 0 { cols.append((col.name, s)) }
            }
            guard let best = cols.map(\.score).max() else { continue }
            let picked = cols.sorted { $0.score > $1.score }.prefix(3).map(\.name)
            scored.append((Candidate(table: t.name, columns: picked, reason: tr("이름 · 코멘트 키워드 일치")),
                           best * 10 + tableScore, i))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.i < $1.i }.prefix(limit).map(\.c)
    }

    // MARK: - 샘플 조회 (앱이 직접)

    /// 후보 컬럼 하나의 값 조회 SQL (MySQL · PostgreSQL LIMIT, SQL Server TOP)
    public static func sampleSQL(table: String, column: String, dialect: any SQLDialect) -> String {
        let c = dialect.quoteIdent(column)
        let t = dialect.quoteTable(table)
        if dialect.kind == .mssql {
            return "SELECT TOP \(sampleRows) \(c) FROM \(t) WHERE \(c) IS NOT NULL"
        }
        return "SELECT \(c) FROM \(t) WHERE \(c) IS NOT NULL LIMIT \(sampleRows)"
    }

    /// 조회한 값 정리: NULL · 빈 값 빼고, 50자로 자르고, 중복 빼고, 최대 20개
    public static func cleanSamples(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for v in values {
            guard let v else { continue }
            let one = v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            guard !one.isEmpty else { continue }
            let cut = String(one.prefix(maxSampleLength))
            if seen.insert(cut).inserted { out.append(cut) }
            if out.count == maxSamples { break }
        }
        return out
    }

    /// 제한 시간 안에 끝나면 결과, 넘으면 nil (onTimeout 을 부르고 기다리지 않는다). 실패도 nil.
    public static func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T,
                                                onTimeout: @escaping @Sendable () async -> Void = {}) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            Task {
                let value = try? await operation()
                if once.claim() { cont.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() {
                    cont.resume(returning: nil)
                    await onTimeout()
                }
            }
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: - 판단 (로컬 AI 2차)

    /// 후보 + 컬럼별 샘플 (nil = 샘플 없음: 시간 초과 · 실패 · 조회 안 함)
    public struct SampledCandidate: Equatable, Sendable {
        public var candidate: Candidate
        public var samples: [String: [String]?]

        public init(candidate: Candidate, samples: [String: [String]?] = [:]) {
            self.candidate = candidate
            self.samples = samples
        }

        /// 카드에 보여줄 값: 값이 있는 첫 컬럼의 값. 조회한 컬럼이 하나도 없으면 nil.
        public var displaySamples: [String]? {
            let lists = candidate.columns.compactMap { samples[$0] ?? nil }
            guard !lists.isEmpty else { return samples.isEmpty ? nil : [] }
            return lists.first { !$0.isEmpty } ?? []
        }
    }

    public enum Confidence: String, Sendable, CaseIterable {
        case high, medium, low

        public var label: String {
            switch self {
            case .high: return tr("높음")
            case .medium: return tr("중간")
            case .low: return tr("낮음")
            }
        }
    }

    public struct Verdict: Equatable, Sendable {
        public var table: String
        public var columns: [String]
        public var confidence: Confidence
        public var explain: String
        public var sql: String
    }

    static func judgeSystemPrompt(_ kind: DatabaseKind, english: Bool) -> String {
        """
        You decide where the data a developer asks about lives in a \(kind.title) database.
        You receive the question and candidate tables/columns with their comments. In this data-finding mode you also see
        small samples of the candidate columns (at most \(maxSamples) distinct values each, read by the app and sent only to this local model).
        Choose the single best table and its columns. Judge by comments, names and what the sample values look like.
        Reply with JSON only, no other text, in exactly this form:
        {"table":"…","columns":["…"],"confidence":"high|medium|low","explain":"…","sql":"SELECT …"}
        - "explain": one or two sentences in \(english ? "English" : "Korean (한국어)") — what the column holds, citing the comment and the values.
        - "sql": one simple \(kind.title) SELECT that shows this data. Never write anything but SELECT.
        """
    }

    public static func judgeMessages(question: String, sampled: [SampledCandidate], tables: [TableMeta], kind: DatabaseKind,
                                     english: Bool) -> [OllamaClient.Message] {
        var user = "Question: \(question)\n\nCandidates:\n"
        for (i, s) in sampled.enumerated() {
            let t = tables.first { $0.name == s.candidate.table }
            user += "\(i + 1). \(s.candidate.table)"
            if let c = t.map({ firstLine($0.comment, max: 80) }), !c.isEmpty { user += " — \(c)" }
            user += "\n"
            for name in s.candidate.columns {
                let col = t?.columns.first { $0.name == name }
                var line = "   \(name) \(col?.columnType ?? "")"
                if let cc = col.map({ firstLine($0.comment, max: 60) }), !cc.isEmpty { line += " — \(cc)" }
                user += line + "\n"
                if let values = s.samples[name] ?? nil {
                    user += values.isEmpty ? "     samples: (no non-null values)\n"
                                           : "     samples: " + values.joined(separator: " | ") + "\n"
                } else {
                    user += "     samples: (not available)\n"
                }
            }
            if !s.candidate.reason.isEmpty { user += "   why picked: \(s.candidate.reason)\n" }
        }
        return [.init(role: "system", content: judgeSystemPrompt(kind, english: english)), .init(role: "user", content: user)]
    }

    /// 조회(SELECT) 하나만인지: 여러 문장 · SELECT INTO · 잠금(FOR UPDATE) · 쓰기 WITH 는 안 된다
    public static func isSelectOnly(_ sql: String) -> Bool {
        let body = SQLText.stripComments(sql).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ";")))
        guard !body.isEmpty, !body.contains(";") else { return false }
        let kw = SQLText.firstKeyword(body)
        guard kw == "SELECT" || kw == "WITH", SQLText.isReadOnly(body) else { return false }
        let upper = body.uppercased()
        for p in [#"\bINTO\b"#, #"\bFOR\s+(UPDATE|SHARE|NO\s+KEY\s+UPDATE|KEY\s+SHARE)\b"#, #"\bLOCK\s+IN\s+SHARE\s+MODE\b"#]
        where upper.range(of: p, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    /// 기본 SQL: `SELECT * FROM <table>` (실행할 때 평소처럼 LIMIT 이 붙는다)
    public static func defaultSQL(table: String, dialect: any SQLDialect) -> String {
        "SELECT * FROM \(dialect.quoteTable(table))"
    }

    /// 2차 답 읽기. 형식이 틀리거나 없는 테이블이면 nil. 컬럼이 없거나 틀리면 그 테이블의 후보 컬럼, sql 은 SELECT 만.
    public static func parseVerdict(_ reply: String, tables: [TableMeta], candidates: [Candidate],
                                    dialect: any SQLDialect) -> Verdict? {
        guard let obj = jsonObject(reply), let name = obj["table"] as? String, let t = resolveTable(name, in: tables) else { return nil }
        var cols = resolveColumns(stringList(obj["columns"]) + stringList(obj["column"]), in: t)
        if cols.isEmpty { cols = candidates.first { $0.table == t.name }?.columns ?? [] }
        guard !cols.isEmpty else { return nil }
        let confidence = (obj["confidence"] as? String).flatMap { Confidence(rawValue: $0.lowercased()) } ?? .low
        let explain = ((obj["explain"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var sql = ((obj["sql"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !isSelectOnly(sql) { sql = defaultSQL(table: t.name, dialect: dialect) }
        sql = sql.trimmingCharacters(in: CharacterSet(charactersIn: "; \n"))
        return Verdict(table: t.name, columns: cols, confidence: confidence, explain: explain, sql: sql)
    }

    // MARK: - 감사 로그

    /// `데이터 찾기 · 후보 N · 샘플 조회 M` (질문 · 값은 남기지 않는다)
    public static func auditResult(candidates: Int, sampleQueries: Int) -> String {
        "데이터 찾기 · 후보 \(candidates) · 샘플 조회 \(sampleQueries)"
    }
}

// MARK: - 로컬 AI 호출 (가짜 전송으로 바꿔 시험할 수 있게)

/// 후보 고르기 · 판단 두 번의 로컬 AI 호출. `complete` 는 메시지를 보내고 답 글을 받는다 (실제로는 OllamaClient).
public struct DataFinderAI: Sendable {
    public var kind: DatabaseKind
    public var english: Bool
    public var complete: @Sendable ([OllamaClient.Message]) async throws -> String

    public init(kind: DatabaseKind, english: Bool, complete: @escaping @Sendable ([OllamaClient.Message]) async throws -> String) {
        self.kind = kind
        self.english = english
        self.complete = complete
    }

    /// 로컬 Ollama 로 (OllamaClient 가 localhost 만 허용)
    public static func ollama(_ client: OllamaClient, model: String, kind: DatabaseKind, english: Bool) -> DataFinderAI {
        DataFinderAI(kind: kind, english: english) { messages in
            var text = ""
            for try await chunk in client.chat(model: model, messages: messages, temperature: 0.1) {
                try Task.checkCancellation()
                if case .content(let c) = chunk { text += c }
            }
            return text
        }
    }

    /// 한 번 묻기. 모델이 답을 만들다 실패한 경우(Ollama 오류 응답)는 형식이 틀린 답처럼 nil — 다시 묻거나 대신 정한다.
    /// Ollama 가 꺼짐 · 원격 주소 차단 · 취소는 그대로 던진다.
    func ask(_ messages: [OllamaClient.Message]) async throws -> String? {
        do {
            return try await complete(messages)
        } catch OllamaError.http {
            return nil
        }
    }

    public struct Picked: Equatable, Sendable {
        public var candidates: [DataFinder.Candidate]
        /// 보낸 테이블 수 (칩 `테이블 목록 N개`)
        public var tablesSent: Int
        /// AI 답이 형식에 안 맞아 키워드 일치로 만든 후보인지
        public var fallback: Bool
    }

    /// 1차: 후보 고르기. 형식이 틀리면 한 번 더 묻고, 그래도 안 되거나 남는 후보가 없으면 키워드 일치.
    public func pickCandidates(question: String, terms: [String], tables: [TableMeta], notes: [TableNote],
                               budget: Int = DataFinder.defaultBudget) async throws -> Picked {
        let prompt = DataFinder.candidateMessages(question: question, terms: terms, kind: kind, tables: tables,
                                                  notes: notes, english: english, budget: budget)
        var messages = prompt.messages
        let reply = try await ask(messages)
        var parsed = reply.flatMap { DataFinder.parseCandidates($0, tables: tables) }
        if parsed == nil {
            if let reply { messages.append(.init(role: "assistant", content: reply)) }
            messages.append(.init(role: "user", content: DataFinder.retryPrompt))
            parsed = try await ask(messages).flatMap { DataFinder.parseCandidates($0, tables: tables) }
        }
        if let parsed, !parsed.isEmpty { return Picked(candidates: parsed, tablesSent: prompt.tablesSent, fallback: false) }
        return Picked(candidates: DataFinder.fallbackCandidates(terms: terms, tables: tables),
                      tablesSent: prompt.tablesSent, fallback: true)
    }

    /// 2차: 판단. 답이 형식에 안 맞으면 첫 후보 (신뢰도 낮음).
    public func judge(question: String, sampled: [DataFinder.SampledCandidate], tables: [TableMeta]) async throws -> DataFinder.Verdict? {
        guard let first = sampled.first?.candidate else { return nil }
        let dialect = Dialects.of(kind)
        let reply = try await ask(DataFinder.judgeMessages(question: question, sampled: sampled, tables: tables,
                                                           kind: kind, english: english))
        if let reply, let v = DataFinder.parseVerdict(reply, tables: tables, candidates: sampled.map(\.candidate), dialect: dialect) {
            return v
        }
        return DataFinder.Verdict(table: first.table, columns: first.columns, confidence: .low, explain: first.reason,
                                  sql: DataFinder.defaultSQL(table: first.table, dialect: dialect))
    }
}
