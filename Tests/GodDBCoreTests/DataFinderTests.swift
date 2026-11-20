import Foundation
import Testing
@testable import GodDBCore

@Suite("DataFinder")
struct DataFinderTests {
    static let students = TableMeta(name: "ui_students", comment: "학생", columns: [
        ColumnMeta(name: "id", columnType: "int", nullable: false, columnKey: "PRI"),
        ColumnMeta(name: "name", columnType: "varchar(50)", nullable: true, comment: "학생 이름"),
        ColumnMeta(name: "school_id", columnType: "int", nullable: true, comment: "학교 번호"),
        ColumnMeta(name: "grade_level", columnType: "int", nullable: true, comment: "학년"),
    ])
    static let schools = TableMeta(name: "ui_schools", comment: "학교", columns: [
        ColumnMeta(name: "id", columnType: "int", nullable: false, columnKey: "PRI"),
        ColumnMeta(name: "name", columnType: "varchar(50)", nullable: true, comment: "학교 이름"),
    ])
    static let customers = TableMeta(name: "ui_customers", columns: [
        ColumnMeta(name: "id", columnType: "int", nullable: false),
        ColumnMeta(name: "grade", columnType: "varchar(10)", nullable: true),
    ])
    static let tables = [customers, schools, students]

    // MARK: - 질문 판단

    @Test(arguments: ["학년 정보는 어디 있어?", "학년 정보는 어딨어?", "학교 정보 어디야", "회원 주소는 어디에 저장돼?",
                      "학년이 어디 들어있어", "where is the student grade?", "Which table has the school name?"])
    func detectsFindQuestions(_ q: String) {
        #expect(DataFinder.isFindQuestion(q), "\(q)")
    }

    @Test(arguments: ["이 쿼리 어디가 느려?", "지금 어디 붙어있어?", "에러 원인이 어디야?", "어디야?",
                      "SELECT * FROM t WHERE x = '어디 있어'", "인덱스가 빠진 테이블을 찾아 줘",
                      "which table has the most rows?", "학년 테이블을 설명해 줘", "where clause 쓰는 법"])
    func ambiguousGoesToNormalQuestion(_ q: String) {
        #expect(!DataFinder.isFindQuestion(q), "\(q)")
    }

    // MARK: - 핵심어

    @Test func extractsKeyTerms() {
        #expect(DataFinder.keyTerms("학년 정보는 어딨어?") == ["학년"])
        #expect(DataFinder.keyTerms("학년 정보는 어디 있어?") == ["학년"])
        #expect(DataFinder.keyTerms("학교 정보 어디야") == ["학교"])
        #expect(DataFinder.keyTerms("회원 주소는 어디에 저장돼?") == ["회원", "주소"])
        #expect(DataFinder.keyTerms("학년이 어디 들어있어") == ["학년"])
        #expect(DataFinder.keyTerms("where is the student grade stored?") == ["student", "grade"])
        // 두 글자 말은 조사처럼 보여도 자르지 않는다
        #expect(DataFinder.keyTerms("나이 데이터 어디 있어") == ["나이"])
    }

    @Test func normalizes() {
        #expect(DataFinder.normalize(" 학년 코드 ") == "학년코드")
        #expect(DataFinder.normalize("Grade CD") == "gradecd")
    }

    // MARK: - 메모 일치

    @Test func matchesNotes() {
        let p = UUID()
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let a = TableNote(profileID: p, database: "school", table: "ui_students", columns: ["grade_level"], terms: ["학년"],
                          source: .ai, confirmed: false, createdAt: new)
        let b = TableNote(profileID: p, database: "school", table: "tb_class", columns: ["grade"], terms: ["학년", "반"],
                          source: .user, createdAt: old)
        let c = TableNote(profileID: p, database: "school", table: "ui_members", columns: ["addr"], terms: ["회원 주소"],
                          source: .ai, confirmed: false)
        let notes = [a, b, c]
        // 확인된 것 먼저
        #expect(DataFinder.matchNotes(terms: ["학년"], in: notes).map(\.table) == ["tb_class", "ui_students"])
        // 공백 · 대소문자 무시: "회원 주소" ↔ ["회원", "주소"]
        #expect(DataFinder.matchNotes(terms: ["회원", "주소"], in: notes).map(\.table) == ["ui_members"])
        #expect(DataFinder.matchNotes(terms: ["회원주소"], in: notes).map(\.table) == ["ui_members"])
        // 핵심어가 모두 있어야
        #expect(DataFinder.matchNotes(terms: ["학년", "코드"], in: notes).isEmpty)
        #expect(DataFinder.matchNotes(terms: [], in: notes).isEmpty)
    }

    // MARK: - 후보 요청 (예산)

    @Test func budgetPrefersTablesOverlappingTerms() {
        // 관계 없는 큰 테이블을 앞에 많이 두고, 예산을 작게
        let filler = (0..<30).map { i in
            TableMeta(name: "zz_log_\(i)", comment: "로그", columns: (0..<10).map {
                ColumnMeta(name: "col_\($0)", columnType: "varchar(255)", nullable: true, comment: "기타 값")
            })
        }
        let all = filler + [Self.students]
        let r = DataFinder.schemaText(tables: all, terms: ["학년"], budget: 600)
        #expect(r.text.hasPrefix("ui_students — 학생\n"))
        #expect(r.text.contains("grade_level int — 학년"))
        #expect(r.count < all.count)
        #expect(r.text.count <= 600 + 60)   // 예산 + "… (N more tables not shown)" 한 줄
        // 예산이 넉넉하면 전부
        #expect(DataFinder.schemaText(tables: all, terms: ["학년"], budget: 1_000_000).count == all.count)
    }

    @Test func candidatePromptIncludesNotesAndCount() {
        let note = TableNote(profileID: UUID(), database: "s", table: "ui_students", columns: ["grade_level"], terms: ["학년"],
                             source: .ai, confirmed: false)
        let m = DataFinder.candidateMessages(question: "학년 정보는 어디 있어?", terms: ["학년"], kind: .mysql,
                                             tables: Self.tables, notes: [note], english: false)
        #expect(m.tablesSent == 3)
        #expect(m.messages.count == 2)
        #expect(m.messages[0].content.contains("{\"candidates\""))
        #expect(m.messages[1].content.contains("학년 → ui_students.grade_level (unconfirmed)"))
    }

    // MARK: - 답 읽기

    @Test func parsesGoodCandidates() {
        let reply = """
        Here you go:
        ```json
        {"candidates":[{"table":"UI_STUDENTS","columns":["Grade_Level"],"reason":"코멘트가 학년"},
                       {"table":"ui_customers","columns":["grade"],"reason":"이름이 grade"}]}
        ```
        """
        let c = DataFinder.parseCandidates(reply, tables: Self.tables)
        #expect(c == [.init(table: "ui_students", columns: ["grade_level"], reason: "코멘트가 학년"),
                      .init(table: "ui_customers", columns: ["grade"], reason: "이름이 grade")])
    }

    @Test func badFormatIsNil() {
        #expect(DataFinder.parseCandidates("학년은 ui_students 에 있어요", tables: Self.tables) == nil)
        #expect(DataFinder.parseCandidates("{\"answer\": 1}", tables: Self.tables) == nil)
        #expect(DataFinder.parseCandidates("{\"candidates\": [", tables: Self.tables) == nil)
    }

    @Test func dropsHallucinatedTablesAndColumns() {
        let reply = """
        {"candidates":[{"table":"tb_student","columns":["grade_cd"]},
                       {"table":"ui_students","columns":["grade_cd","grade_level","ui_students.name"]},
                       {"table":"ui_schools","columns":["nope"]}]}
        """
        let c = DataFinder.parseCandidates(reply, tables: Self.tables)
        #expect(c == [.init(table: "ui_students", columns: ["grade_level", "name"])])
        // 모두 없는 것이면 빈 목록 (형식은 맞음)
        #expect(DataFinder.parseCandidates("{\"candidates\":[{\"table\":\"x\",\"columns\":[\"y\"]}]}", tables: Self.tables) == [])
    }

    @Test func capsAtFiveCandidates() {
        let many = (0..<8).map { i in TableMeta(name: "t\(i)", columns: [ColumnMeta(name: "c", columnType: "int", nullable: true)]) }
        let json = "{\"candidates\":[" + (0..<8).map { "{\"table\":\"t\($0)\",\"columns\":[\"c\"]}" }.joined(separator: ",") + "]}"
        #expect(DataFinder.parseCandidates(json, tables: many)?.count == 5)
    }

    @Test func fallbackRanksByKeyword() {
        let c = DataFinder.fallbackCandidates(terms: ["학년"], tables: Self.tables)
        #expect(c.map(\.location) == ["ui_students.grade_level"])
        let school = DataFinder.fallbackCandidates(terms: ["학교"], tables: Self.tables)
        // 코멘트 일치(학교 이름 · 학교 번호), 테이블 코멘트도 맞는 ui_schools 가 먼저
        #expect(school.map(\.table) == ["ui_schools", "ui_students"])
        #expect(DataFinder.fallbackCandidates(terms: ["grade"], tables: Self.tables).map(\.location)
                == ["ui_customers.grade", "ui_students.grade_level"])
        #expect(DataFinder.fallbackCandidates(terms: ["없는말"], tables: Self.tables).isEmpty)
    }

    // MARK: - 샘플

    @Test func sampleSQLPerDialect() {
        #expect(DataFinder.sampleSQL(table: "ui_students", column: "grade_level", dialect: MySQLDialect())
                == "SELECT `grade_level` FROM `ui_students` WHERE `grade_level` IS NOT NULL LIMIT 200")
        #expect(DataFinder.sampleSQL(table: "ui_students", column: "grade_level", dialect: PostgresDialect())
                == "SELECT \"grade_level\" FROM \"ui_students\" WHERE \"grade_level\" IS NOT NULL LIMIT 200")
        #expect(DataFinder.sampleSQL(table: "sales.orders", column: "grade", dialect: MSSQLDialect())
                == "SELECT TOP 200 [grade] FROM [sales].[orders] WHERE [grade] IS NOT NULL")
    }

    @Test func cleansSamples() {
        let long = String(repeating: "가", count: 80)
        let values: [String?] = ["1", "2", nil, "1", "  ", long, long + "나"] + (0..<40).map { "v\($0)" }
        let out = DataFinder.cleanSamples(values)
        #expect(out.count == 20)
        #expect(out.prefix(3) == ["1", "2", String(repeating: "가", count: 50)])
        #expect(out.allSatisfy { $0.count <= 50 })
        #expect(Set(out).count == out.count)
    }

    @Test func timeoutReturnsNil() async {
        let slow = await DataFinder.withTimeout(seconds: 0.05, operation: {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return 1
        })
        #expect(slow == nil)
        let fast = await DataFinder.withTimeout(seconds: 2, operation: { 7 })
        #expect(fast == 7)
    }

    @Test func displaySamples() {
        let c = DataFinder.Candidate(table: "t", columns: ["a", "b"])
        #expect(DataFinder.SampledCandidate(candidate: c).displaySamples == nil)
        #expect(DataFinder.SampledCandidate(candidate: c, samples: ["a": nil, "b": nil]).displaySamples == [])
        #expect(DataFinder.SampledCandidate(candidate: c, samples: ["a": [], "b": ["x"]]).displaySamples == ["x"])
    }

    // MARK: - 판단 · SELECT 만

    @Test func selectOnly() {
        #expect(DataFinder.isSelectOnly("SELECT grade_level FROM ui_students"))
        #expect(DataFinder.isSelectOnly("  select * from t;  "))
        #expect(DataFinder.isSelectOnly("WITH x AS (SELECT 1) SELECT * FROM x"))
        #expect(!DataFinder.isSelectOnly("DELETE FROM ui_students"))
        #expect(!DataFinder.isSelectOnly("SELECT 1; DROP TABLE t"))
        #expect(!DataFinder.isSelectOnly("SELECT * INTO backup FROM t"))
        #expect(!DataFinder.isSelectOnly("SELECT * FROM t FOR UPDATE"))
        #expect(!DataFinder.isSelectOnly("WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x"))
        #expect(!DataFinder.isSelectOnly(""))
    }

    @Test func parsesVerdict() {
        let cands = [DataFinder.Candidate(table: "ui_students", columns: ["grade_level"])]
        let good = """
        {"table":"ui_students","columns":["grade_level"],"confidence":"high","explain":"학년 코멘트, 값 1~6","sql":"SELECT grade_level FROM ui_students"}
        """
        let v = DataFinder.parseVerdict(good, tables: Self.tables, candidates: cands, dialect: MySQLDialect())
        #expect(v == .init(table: "ui_students", columns: ["grade_level"], confidence: .high, explain: "학년 코멘트, 값 1~6",
                           sql: "SELECT grade_level FROM ui_students"))
        // SELECT 가 아니면 SELECT * FROM 으로, 신뢰도가 틀리면 낮음, 컬럼이 없으면 후보 컬럼
        let bad = """
        {"table":"ui_students","columns":["nope"],"confidence":"very","explain":"x","sql":"UPDATE ui_students SET grade_level = 1"}
        """
        let w = DataFinder.parseVerdict(bad, tables: Self.tables, candidates: cands, dialect: MySQLDialect())
        #expect(w?.sql == "SELECT * FROM `ui_students`")
        #expect(w?.confidence == .low)
        #expect(w?.columns == ["grade_level"])
        // 없는 테이블 · 형식 틀림
        #expect(DataFinder.parseVerdict("{\"table\":\"tb_student\"}", tables: Self.tables, candidates: cands, dialect: MySQLDialect()) == nil)
        #expect(DataFinder.parseVerdict("모르겠어요", tables: Self.tables, candidates: cands, dialect: MySQLDialect()) == nil)
    }

    @Test func auditLineHasNoQuestionOrValues() {
        #expect(DataFinder.auditResult(candidates: 3, sampleQueries: 4) == "데이터 찾기 · 후보 3 · 샘플 조회 4")
    }

    // MARK: - 가짜 전송으로 두 번의 AI 호출

    /// 정해 둔 답을 차례로 돌려주는 가짜 Ollama
    final class FakeTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private(set) var sent: [[OllamaClient.Message]] = []

        init(_ replies: [String]) { self.replies = replies }

        func complete(_ messages: [OllamaClient.Message]) -> String {
            lock.lock(); defer { lock.unlock() }
            sent.append(messages)
            return replies.isEmpty ? "" : replies.removeFirst()
        }

        var calls: Int { lock.lock(); defer { lock.unlock() }; return sent.count }
    }

    func ai(_ fake: FakeTransport) -> DataFinderAI {
        DataFinderAI(kind: .mysql, english: false) { fake.complete($0) }
    }

    @Test func picksCandidatesFirstTry() async throws {
        let fake = FakeTransport(["{\"candidates\":[{\"table\":\"ui_students\",\"columns\":[\"grade_level\"],\"reason\":\"r\"}]}"])
        let p = try await ai(fake).pickCandidates(question: "학년 정보는 어디 있어?", terms: ["학년"], tables: Self.tables, notes: [])
        #expect(p.candidates.map(\.location) == ["ui_students.grade_level"])
        #expect(!p.fallback)
        #expect(p.tablesSent == 3)
        #expect(fake.calls == 1)
    }

    @Test func retriesOnceThenSucceeds() async throws {
        let fake = FakeTransport(["학년은 학생 테이블에 있어요.",
                                  "{\"candidates\":[{\"table\":\"ui_students\",\"columns\":[\"grade_level\"]}]}"])
        let p = try await ai(fake).pickCandidates(question: "q", terms: ["학년"], tables: Self.tables, notes: [])
        #expect(p.candidates.map(\.location) == ["ui_students.grade_level"])
        #expect(!p.fallback)
        #expect(fake.calls == 2)
        // 다시 요청할 때 앞 답과 형식 안내를 함께 보낸다
        #expect(fake.sent[1].count == 4)
        #expect(fake.sent[1][3].content == DataFinder.retryPrompt)
    }

    @Test func fallsBackAfterSecondBadReply() async throws {
        let fake = FakeTransport(["몰라요", "정말 몰라요"])
        let p = try await ai(fake).pickCandidates(question: "q", terms: ["학년"], tables: Self.tables, notes: [])
        #expect(p.fallback)
        #expect(p.candidates.map(\.location) == ["ui_students.grade_level"])
        #expect(fake.calls == 2)
    }

    @Test func fallsBackWhenAllHallucinated() async throws {
        let fake = FakeTransport(["{\"candidates\":[{\"table\":\"tb_student\",\"columns\":[\"grade_cd\"]}]}"])
        let p = try await ai(fake).pickCandidates(question: "q", terms: ["학년"], tables: Self.tables, notes: [])
        #expect(p.fallback)
        #expect(p.candidates.first?.table == "ui_students")
        #expect(fake.calls == 1)
    }

    @Test func ollamaErrorReplyCountsAsBadFormat() async throws {
        // 모델이 답을 만들다 실패(HTTP 500)하면 다시 묻고, 그래도 안 되면 키워드 일치
        let ai = DataFinderAI(kind: .mysql, english: false) { _ in throw OllamaError.http(500, "token repeat limit reached") }
        let p = try await ai.pickCandidates(question: "q", terms: ["학년"], tables: Self.tables, notes: [])
        #expect(p.fallback)
        #expect(p.candidates.first?.location == "ui_students.grade_level")
        let v = try await ai.judge(question: "q", sampled: [.init(candidate: p.candidates[0])], tables: Self.tables)
        #expect(v?.confidence == .low)
        // Ollama 가 꺼져 있으면 그대로 오류
        let off = DataFinderAI(kind: .mysql, english: false) { _ in throw OllamaError.notRunning }
        await #expect(throws: OllamaError.self) {
            _ = try await off.pickCandidates(question: "q", terms: ["학년"], tables: Self.tables, notes: [])
        }
    }

    @Test func judgeSendsSamplesAndFallsBackToFirstCandidate() async throws {
        let c = DataFinder.Candidate(table: "ui_students", columns: ["grade_level"], reason: "학년 코멘트")
        let sampled = [DataFinder.SampledCandidate(candidate: c, samples: ["grade_level": ["1", "2", "3"]])]
        let fake = FakeTransport(["형식 없는 답"])
        let v = try await ai(fake).judge(question: "학년 정보는 어디 있어?", sampled: sampled, tables: Self.tables)
        #expect(fake.sent[0][1].content.contains("samples: 1 | 2 | 3"))
        #expect(v == .init(table: "ui_students", columns: ["grade_level"], confidence: .low, explain: "학년 코멘트",
                           sql: "SELECT * FROM `ui_students`"))
    }
}
