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
    public static let sampleTimeout: Double = 10
    /// 큰 스키마: 1단계(테이블 목록)에서 AI 가 고를 테이블 수, 사전 점수로 늘 함께 넣을 테이블 수
    public static let maxStage1Tables = 10
    public static let scorerExtraTables = 3

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

    // MARK: - 큰 스키마: 1단계 (테이블만)

    /// 모든 테이블의 컬럼까지 예산에 들어가지 않으면 두 단계로 (1단계: 테이블 목록, 2단계: 고른 테이블의 컬럼)
    public static func needsTwoStages(tables: [TableMeta], budget: Int = defaultBudget) -> Bool {
        var total = 0
        for t in tables {
            total += tableBlock(t).count
            if total > budget { return true }
        }
        return false
    }

    /// 1단계에 보낼 테이블 목록 (`이름 — 코멘트`, 한 줄씩). 사전 점수가 있는 테이블을 먼저 두고 맞은 컬럼 이름을 붙인다
    /// (`[matching columns: schyr]`) — 목록이 잘려도 이 테이블들은 늘 들어간다.
    /// - Returns: 글, 보낸 테이블 수
    public static func tableListText(tables: [TableMeta], terms: [String], budget: Int = defaultBudget) -> (text: String, count: Int) {
        let ranked = rankTables(terms: terms, tables: tables)
        let hits = Dictionary(ranked.map { ($0.table, $0.columns) }, uniquingKeysWith: { a, _ in a })
        let byName = Dictionary(tables.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let order = ranked.compactMap { byName[$0.table] } + tables.filter { hits[$0.name] == nil }
        var text = ""
        var count = 0
        for t in order {
            var line = t.name
            let c = firstLine(t.comment, max: 60)
            if !c.isEmpty { line += " — \(c)" }
            if let cols = hits[t.name] { line += "  [matching columns: \(cols.prefix(4).joined(separator: ", "))]" }
            line += "\n"
            guard text.count + line.count <= budget else { break }
            text += line
            count += 1
        }
        if count < tables.count { text += "… (\(tables.count - count) more tables not shown)\n" }
        return (text, count)
    }

    static func tableSystemPrompt(_ kind: DatabaseKind) -> String {
        """
        You help a developer find where data lives in a large \(kind.title) database.
        You receive a question, the key terms with the English names and abbreviations they are often stored under,
        and the list of tables (name — comment). Table and column names are often English abbreviations
        (for example stdnt = student, schl = school, schyr = school year/grade, mbr = member, nm = name, tel = phone).
        "[matching columns: …]" lists columns whose names match the key terms.
        Pick up to \(maxStage1Tables) tables that most likely hold the data in the question, best first. Use only tables from the list.
        Reply with JSON only, no other text, in exactly this form:
        {"tables":["…"]}
        """
    }

    public static let tableRetryPrompt = """
    That reply was not in the required form. Reply again with JSON only, no other text:
    {"tables":["…"]}
    """

    /// 1단계 요청 메시지와 보낸 테이블 수
    public static func tableMessages(question: String, terms: [String], kind: DatabaseKind, tables: [TableMeta],
                                     notes: [TableNote], budget: Int = defaultBudget) -> (messages: [OllamaClient.Message], tablesSent: Int) {
        let list = tableListText(tables: tables, terms: terms, budget: budget)
        var user = "Question: \(question)\nKey terms: \(terms.joined(separator: ", "))\n"
        let expansion = AbbreviationDictionary.expansionText(terms: terms)
        if !expansion.isEmpty { user += "Key terms as English DB names:\n\(expansion)\n" }
        user += "\nTables (\(tables.count)):\n\(list.text)"
        if !notes.isEmpty {
            user += "\nLocations saved by the team:\n"
            for n in notes.prefix(50) { user += "  - \(n.terms.joined(separator: ", ")) → \(n.location)\n" }
        }
        return ([.init(role: "system", content: tableSystemPrompt(kind)), .init(role: "user", content: user)], list.count)
    }

    /// 1단계 답 읽기. 형식이 틀리면 nil, 맞으면 실제 있는 테이블 이름 (최대 10개).
    public static func parseTables(_ reply: String, tables: [TableMeta]) -> [String]? {
        guard let obj = jsonObject(reply) else { return nil }
        let raw: [String]
        if let list = obj["tables"] as? [Any] {
            raw = list.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["table"] as? String) }
        } else if let list = obj["candidates"] as? [Any] {
            raw = list.compactMap { ($0 as? [String: Any])?["table"] as? String }
        } else {
            return nil
        }
        var out: [String] = []
        for name in raw {
            if let t = resolveTable(name, in: tables), !out.contains(t.name) { out.append(t.name) }
            if out.count == maxStage1Tables { break }
        }
        return out
    }

    /// 2단계로 보낼 테이블: AI 가 고른 것 + 사전 점수 상위 몇 개 (빠졌으면), 원래 TableMeta 로
    public static func stage2Tables(picked: [String], terms: [String], tables: [TableMeta]) -> [TableMeta] {
        var names = picked
        for r in rankTables(terms: terms, tables: tables).prefix(scorerExtraTables) where !names.contains(r.table) {
            names.append(r.table)
        }
        return names.compactMap { n in tables.first { $0.name == n } }
    }

    static func candidateSystemPrompt(_ kind: DatabaseKind, english: Bool) -> String {
        """
        You help a developer find where data lives in a \(kind.title) database.
        You receive a question, the tables (name — comment) with their columns (name type — comment), and locations the team saved before.
        Pick at most \(maxCandidates) candidate tables/columns that most likely hold the data in the question, best first.
        Use only tables and columns from the list. Comments are business names (often Korean) — rely on them.
        Names are often English abbreviations (stdnt = student, schl = school, schyr = school year/grade, mbr = member,
        nm = name, tel = phone, cd = code, no = number). Use the English names given for the key terms.
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
        var user = "Question: \(question)\nKey terms: \(terms.joined(separator: ", "))\n"
        let expansion = AbbreviationDictionary.expansionText(terms: terms)
        if !expansion.isEmpty { user += "Key terms as English DB names:\n\(expansion)\n" }
        user += "\nTables (\(tables.count)):\n\(schema.text)"
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

    /// AI 없이: 약어 사전 · 이름 · 코멘트 점수 순 (DataFinderDictionary.swift `scoreColumns`). 테이블마다 컬럼 3개까지.
    public static func fallbackCandidates(terms: [String], tables: [TableMeta], limit: Int = maxCandidates) -> [Candidate] {
        rankTables(terms: terms, tables: tables).prefix(limit).map {
            Candidate(table: $0.table, columns: Array($0.columns.prefix(3)), reason: tr("이름 · 코멘트 · 약어 사전 일치"))
        }
    }

    /// AI 없이 고른 후보를 샘플 값 모양으로 다시 줄 세우기 (예: 학년 → 값이 1~12 인 컬럼 먼저)
    public static func rankSampled(terms: [String], sampled: [SampledCandidate], tables: [TableMeta]) -> [SampledCandidate] {
        let scores = scoreColumns(terms: terms, tables: tables)
        func score(_ s: SampledCandidate) -> Double {
            var best = -Double.infinity
            for col in s.candidate.columns {
                let base = scores.first { $0.table == s.candidate.table && $0.column == col }?.score ?? 0
                let fit = (s.samples[col] ?? nil).map { AbbreviationDictionary.valueFit(terms: terms, samples: $0) } ?? 0
                best = max(best, base + fit * 3)
            }
            return best
        }
        return sampled.enumerated().map { (i: $0.offset, s: $0.element, score: score($0.element)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.i < $1.i }
            .map { r in
                // 후보 안에서도 값 모양이 맞는 컬럼을 앞으로
                var s = r.s
                let colScore: (String) -> Double = { col in
                    (scores.first { $0.table == s.candidate.table && $0.column == col }?.score ?? 0)
                        + ((s.samples[col] ?? nil).map { AbbreviationDictionary.valueFit(terms: terms, samples: $0) } ?? 0) * 3
                }
                s.candidate.columns = s.candidate.columns.enumerated()
                    .sorted { colScore($0.element) != colScore($1.element) ? colScore($0.element) > colScore($1.element) : $0.offset < $1.offset }
                    .map(\.element)
                return s
            }
    }

    // MARK: - 샘플 조회 (앱이 직접)

    /// 후보 컬럼 하나의 값 조회 SQL (MySQL · PostgreSQL LIMIT, SQL Server TOP)
    public static func sampleSQL(table: String, column: String, dialect: any SQLDialect) -> String {
        let c = dialect.quoteIdent(column)
        let t = dialect.quoteTable(table)
        if dialect.kind == .mssql {
            // WITH (NOLOCK): 바쁜 운영 테이블의 잠금에 막혀 시간 초과되지 않게. 값 몇 개를 훑어보는 읽기 전용 조회라
            // 커밋 전 값(dirty read)이 섞여도 괜찮다.
            return "SELECT TOP \(sampleRows) \(c) FROM \(t) WITH (NOLOCK) WHERE \(c) IS NOT NULL"
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

    /// 샘플 조회 하나의 결과
    public enum SampleOutcome: Equatable, Sendable {
        case values([String])
        case timedOut
        case failed(String)

        public var values: [String]? { if case .values(let v) = self { return v } else { return nil } }
    }

    /// 후보 + 컬럼별 샘플 (nil = 샘플 없음: 시간 초과 · 실패 · 조회 안 함)
    public struct SampledCandidate: Equatable, Sendable {
        public var candidate: Candidate
        public var samples: [String: [String]?]
        /// 컬럼별 조회 결과 (카드의 "값 N개 / 시간 초과 / 조회 실패")
        public var outcomes: [String: SampleOutcome]

        public init(candidate: Candidate, samples: [String: [String]?] = [:], outcomes: [String: SampleOutcome] = [:]) {
            self.candidate = candidate
            self.samples = samples
            self.outcomes = outcomes
        }

        /// 결과 하나 넣기 (값이면 samples 에도)
        public mutating func record(_ column: String, _ outcome: SampleOutcome) {
            outcomes[column] = outcome
            samples[column] = outcome.values
        }

        /// 카드에 보일 조회 상태: 값이 있으면 "값 N개", 아니면 시간 초과 · 조회 실패. 조회 안 했으면 nil.
        public var sampleStatus: String? {
            let list = candidate.columns.compactMap { outcomes[$0] }
            guard !list.isEmpty else { return nil }
            if let v = candidate.columns.compactMap({ outcomes[$0]?.values }).first(where: { !$0.isEmpty }) {
                return tr("값 %@개", "\(v.count)")
            }
            if list.contains(where: { $0 == .timedOut }) { return tr("시간 초과") }
            for case .failed(let m) in list { return tr("조회 실패: %@", m) }
            return tr("값 %@개", "0")
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
        /// AI 판단이 아니라 이름 · 코멘트 · 값 점수로 정했는지
        public var fallback: Bool = false
    }

    static func judgeSystemPrompt(_ kind: DatabaseKind, english: Bool) -> String {
        """
        You decide where the data a developer asks about lives in a \(kind.title) database.
        You receive the question and candidate tables/columns with their comments. In this data-finding mode you also see
        small samples of the candidate columns (at most \(maxSamples) distinct values each, read by the app and sent only to this local model).
        Choose the single best table and its columns. Judge by comments, names and what the sample values look like
        (for example a school grade is 1–6 or 1–12, not VIP/GOLD). Names are often English abbreviations.
        Reply with JSON only, no other text, in exactly this form:
        {"table":"…","columns":["…"],"confidence":"high|medium|low","explain":"…","sql":"SELECT …"}
        - "explain": one or two sentences in \(english ? "English" : "Korean (한국어)") — what the column holds, citing the comment and the values.
        - "sql": one simple \(kind.title) SELECT that shows this data. Never write anything but SELECT.
        """
    }

    public static func judgeMessages(question: String, sampled: [SampledCandidate], tables: [TableMeta], kind: DatabaseKind,
                                     english: Bool, terms: [String] = []) -> [OllamaClient.Message] {
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
                    if let hint = AbbreviationDictionary.valueHintText(terms: terms, samples: values) {
                        user += "     hint: \(hint)\n"
                    }
                } else {
                    user += "     samples: (not available)\n"
                }
            }
            if !s.candidate.reason.isEmpty { user += "   why picked: \(s.candidate.reason)\n" }
        }
        return [.init(role: "system", content: judgeSystemPrompt(kind, english: english)), .init(role: "user", content: user)]
    }

    /// 조회(SELECT) 하나만인지: 여러 문장 · SELECT INTO · 잠금(FOR UPDATE) · 쓰기 WITH 는 안 된다
    public static func isSelectOnly(_ sql: String, kind: DatabaseKind) -> Bool {
        let body = SQLText.stripComments(sql).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ";")))
        guard !body.isEmpty, !body.contains(";") else { return false }
        let kw = SQLText.firstKeyword(body)
        guard kw == "SELECT" || kw == "WITH", SQLText.isReadOnly(sql, kind: kind) else { return false }
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
        if !isSelectOnly(sql, kind: dialect.kind) { sql = defaultSQL(table: t.name, dialect: dialect) }
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

    /// 모델이 답을 만들다 실패함 (Ollama 오류 응답). 다시 물어도 소용없으므로 AI 없이 이어 간다.
    public struct Unavailable: Error, Equatable, Sendable {
        public let reason: String
    }

    /// 한 번 묻기. Ollama 오류 응답은 `Unavailable` 로 바꾼다. Ollama 가 꺼짐 · 원격 주소 차단 · 취소는 그대로 던진다.
    func ask(_ messages: [OllamaClient.Message]) async throws -> String {
        do {
            return try await complete(messages)
        } catch let e as OllamaError {
            if case .http = e { throw Unavailable(reason: ModelProbe.shortReason(e)) }
            throw e
        }
    }

    /// 묻고 읽기. 형식이 틀리면 한 번 더 묻는다. 두 번 다 틀리면 nil.
    func askParsed<T>(_ first: [OllamaClient.Message], retry: String, parse: (String) -> T?) async throws -> T? {
        var messages = first
        let reply = try await ask(messages)
        if let v = parse(reply) { return v }
        messages.append(.init(role: "assistant", content: reply))
        messages.append(.init(role: "user", content: retry))
        return parse(try await ask(messages))
    }

    public struct Picked: Equatable, Sendable {
        public var candidates: [DataFinder.Candidate]
        /// 보낸 테이블 수 (칩 `테이블 목록 N개`)
        public var tablesSent: Int
        /// AI 답을 못 받아(형식 틀림 · 모델 오류) 이름 · 코멘트 · 약어 사전으로 만든 후보인지
        public var fallback: Bool
        /// 모델 오류로 AI 를 못 쓴 이유 (nil = 형식만 틀림 또는 AI 사용)
        public var aiError: String? = nil
        /// 두 단계로 골랐는지 (큰 스키마)
        public var twoStage: Bool = false
    }

    /// 후보 고르기. 큰 스키마면 1단계(테이블 목록 → 최대 10개) 뒤 2단계(그 테이블의 컬럼 → 후보).
    /// 형식이 틀리면 한 번 더 묻고, 그래도 안 되거나 남는 후보가 없거나 모델이 실패하면 약어 사전 점수로.
    public func pickCandidates(question: String, terms: [String], tables: [TableMeta], notes: [TableNote],
                               budget: Int = DataFinder.defaultBudget) async throws -> Picked {
        let twoStage = DataFinder.needsTwoStages(tables: tables, budget: budget)
        var tablesSent = tables.count
        func fallback(_ error: String?) -> Picked {
            Picked(candidates: DataFinder.fallbackCandidates(terms: terms, tables: tables), tablesSent: tablesSent,
                   fallback: true, aiError: error, twoStage: twoStage)
        }
        do {
            var focus = tables
            if twoStage {
                let stage1 = DataFinder.tableMessages(question: question, terms: terms, kind: kind, tables: tables,
                                                      notes: notes, budget: budget)
                tablesSent = stage1.tablesSent
                let names = try await askParsed(stage1.messages, retry: DataFinder.tableRetryPrompt) {
                    DataFinder.parseTables($0, tables: tables)
                } ?? []
                focus = DataFinder.stage2Tables(picked: names, terms: terms, tables: tables)
                if focus.isEmpty { return fallback(nil) }
            }
            let prompt = DataFinder.candidateMessages(question: question, terms: terms, kind: kind, tables: focus,
                                                      notes: notes, english: english, budget: budget)
            if !twoStage { tablesSent = prompt.tablesSent }
            let parsed = try await askParsed(prompt.messages, retry: DataFinder.retryPrompt) {
                DataFinder.parseCandidates($0, tables: tables)
            }
            if let parsed, !parsed.isEmpty {
                return Picked(candidates: parsed, tablesSent: tablesSent, fallback: false, twoStage: twoStage)
            }
            return fallback(nil)
        } catch let e as Unavailable {
            return fallback(e.reason)
        }
    }

    /// 2차: 판단. 답이 형식에 안 맞거나 모델이 실패하면 이름 · 코멘트 · 값 점수가 가장 높은 후보 (신뢰도 낮음, fallback).
    public func judge(question: String, sampled: [DataFinder.SampledCandidate], tables: [TableMeta],
                      terms: [String] = []) async throws -> DataFinder.Verdict? {
        guard !sampled.isEmpty else { return nil }
        let dialect = Dialects.of(kind)
        do {
            let reply = try await ask(DataFinder.judgeMessages(question: question, sampled: sampled, tables: tables,
                                                               kind: kind, english: english, terms: terms))
            if let v = DataFinder.parseVerdict(reply, tables: tables, candidates: sampled.map(\.candidate), dialect: dialect) {
                return v
            }
        } catch is Unavailable {}
        return Self.fallbackVerdict(terms: terms, sampled: sampled, tables: tables, dialect: dialect)
    }

    /// AI 없이 판단: 값 모양까지 본 점수 1등 (신뢰도 낮음)
    public static func fallbackVerdict(terms: [String], sampled: [DataFinder.SampledCandidate], tables: [TableMeta],
                                       dialect: any SQLDialect) -> DataFinder.Verdict? {
        let ranked = terms.isEmpty ? sampled : DataFinder.rankSampled(terms: terms, sampled: sampled, tables: tables)
        guard let first = ranked.first?.candidate else { return nil }
        return DataFinder.Verdict(table: first.table, columns: first.columns, confidence: .low, explain: first.reason,
                                  sql: DataFinder.defaultSQL(table: first.table, dialect: dialect), fallback: true)
    }

    // MARK: - 한 번에 (후보 → 샘플 → 판단)

    public enum Step: Sendable { case picking, sampling, judging }

    public struct Found: Sendable {
        public var picked: Picked
        /// 판단 순서 (판단으로 고른 후보가 앞)
        public var sampled: [DataFinder.SampledCandidate]
        public var verdict: DataFinder.Verdict?
        public var sampleQueries: Int
        /// AI 없이 찾은 결과인지 (후보 또는 판단)
        public var usedFallback: Bool { picked.fallback || (verdict?.fallback ?? false) }
        /// 모델 오류로 AI 를 못 쓴 이유
        public var aiError: String?
    }

    /// 찾기 전체. `allowSamples` 가 false 면 취소, `sample` 은 컬럼 하나의 값을 조회한다 (앱 · 시험이 넣는다).
    /// 후보 고르기에서 모델이 실패하면 판단도 AI 없이 한다.
    public func find(question: String, terms: [String], tables: [TableMeta], notes: [TableNote],
                     budget: Int = DataFinder.defaultBudget,
                     progress: @escaping @Sendable (Step) async -> Void = { _ in },
                     allowSamples: @escaping @Sendable () async -> Bool = { true },
                     sample: @escaping @Sendable (_ table: String, _ column: String) async -> DataFinder.SampleOutcome) async throws -> Found {
        await progress(.picking)
        let picked = try await pickCandidates(question: question, terms: terms, tables: tables, notes: notes, budget: budget)
        try Task.checkCancellation()
        var found = Found(picked: picked, sampled: [], verdict: nil, sampleQueries: 0, aiError: picked.aiError)
        guard !picked.candidates.isEmpty else { return found }
        guard await allowSamples() else { throw CancellationError() }
        await progress(.sampling)
        var sampled: [DataFinder.SampledCandidate] = []
        for c in picked.candidates {
            var s = DataFinder.SampledCandidate(candidate: c)
            for col in c.columns {
                try Task.checkCancellation()
                found.sampleQueries += 1
                s.record(col, await sample(c.table, col))
            }
            sampled.append(s)
        }
        try Task.checkCancellation()
        let verdict: DataFinder.Verdict?
        if picked.aiError != nil {
            verdict = Self.fallbackVerdict(terms: terms, sampled: sampled, tables: tables, dialect: Dialects.of(kind))
        } else {
            await progress(.judging)
            verdict = try await judge(question: question, sampled: sampled, tables: tables, terms: terms)
        }
        if let v = verdict {
            let chosen = sampled.first { $0.candidate.table == v.table && $0.candidate.columns == v.columns }
                ?? sampled.first { $0.candidate.table == v.table }
            if let chosen, let i = sampled.firstIndex(of: chosen) {
                sampled.remove(at: i)
                sampled.insert(chosen, at: 0)
            }
            if v.fallback, picked.fallback {
                // AI 없이: 값 모양까지 본 순서로 다른 후보도
                sampled = DataFinder.rankSampled(terms: terms, sampled: sampled, tables: tables)
            }
        }
        found.sampled = sampled
        found.verdict = verdict
        return found
    }
}
