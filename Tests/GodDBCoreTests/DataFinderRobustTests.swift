import Foundation
import Testing
@testable import GodDBCore

/// #151: 약어 사전 · 값 모양 · 2단계 후보 · 모델 확인 · NOLOCK
@Suite("DataFinder robust")
struct DataFinderRobustTests {
    static func col(_ name: String, _ type: String = "varchar(50)", comment: String = "") -> ColumnMeta {
        ColumnMeta(name: name, columnType: type, nullable: true, comment: comment)
    }

    /// 코멘트 없는 영어 약어 스키마 (학년 = schyr, 회원 등급 = mbr_grd_cd 가 섞여 있음)
    static let student = TableMeta(name: "tb_stdnt_info", columns: [
        col("stdnt_no", "int"), col("stdnt_nm"), col("schyr", "tinyint"), col("ban_cd"), col("schl_cd"),
    ])
    static let school = TableMeta(name: "tb_schl_info", columns: [col("schl_cd"), col("schl_nm"), col("schl_addr")])
    static let member = TableMeta(name: "tb_mbr_info", columns: [
        col("mbr_no", "int"), col("mbr_nm"), col("mbr_tel_no"), col("mbr_grd_cd"), col("reg_dt", "datetime"),
    ])
    static let sales = TableMeta(name: "tb_sales_yr_sum", columns: [col("base_yr", "int"), col("sale_amt", "decimal")])
    static func noise(_ i: Int) -> TableMeta {
        TableMeta(name: "tb_sys_log_\(i)", columns: [col("log_seq", "bigint"), col("req_url", "varchar(255)"),
                                                     col("resp_body", "text"), col("crt_dtm", "datetime")])
    }
    /// 회원 · 매출 테이블이 학생보다 앞에 오게 (같은 점수면 앞 테이블이 이기는 상황을 만든다)
    static let small = [member, sales, student, school]
    static let large = (0..<200).map(noise) + small

    // MARK: - 이름 조각 · 사전

    @Test func tokenizesNames() {
        #expect(AbbreviationDictionary.tokens("tb_stdnt_info") == ["tb", "stdnt", "info"])
        #expect(AbbreviationDictionary.tokens("StdntNm") == ["stdnt", "nm"])
        #expect(AbbreviationDictionary.tokens("HTTPServer2Id") == ["http", "server", "2", "id"])
        #expect(AbbreviationDictionary.tokens("schyr") == ["schyr"])
        #expect(AbbreviationDictionary.tokens("dbo.TB_MBR-INFO") == ["dbo", "tb", "mbr", "info"])
    }

    @Test func conceptsForTerms() {
        #expect(AbbreviationDictionary.concepts(for: "학년").first?.english.contains("schyr") == true)
        // 사전 말과 같으면 그 항목만 (전화번호 → 전화)
        #expect(AbbreviationDictionary.concepts(for: "전화번호").map { $0.english.first } == ["phone"])
        // 붙여 쓴 말은 나눠서
        #expect(AbbreviationDictionary.concepts(for: "학생이름").map { $0.english.first } == ["student", "name"])
        // 영어 질문 말
        #expect(AbbreviationDictionary.concepts(for: "grade").first?.korean.first == "학년")
        #expect(AbbreviationDictionary.concepts(for: "없는말").isEmpty)
    }

    @Test func dictionaryIsDataWithReasonableSize() {
        let n = AbbreviationDictionary.entries.count
        #expect((60...100).contains(n))
        for e in AbbreviationDictionary.entries {
            #expect(!e.korean.isEmpty && !e.english.isEmpty)
            #expect(e.english.allSatisfy { $0 == $0.lowercased() })
            if let p = e.valuePattern { #expect((try? NSRegularExpression(pattern: p)) != nil) }
        }
    }

    @Test func expansionText() {
        let t = AbbreviationDictionary.expansionText(terms: ["학년", "없는말"])
        #expect(t.hasPrefix("학년 → grade, grd, schyr"))
        #expect(!t.contains("없는말"))
    }

    // MARK: - AI 없이 (사전 점수)

    @Test func scorerAloneFindsSchyrForGrade() {
        let c = DataFinder.fallbackCandidates(terms: ["학년"], tables: Self.small)
        #expect(c.first?.table == "tb_stdnt_info")
        #expect(c.first?.columns.first == "schyr")
        // 큰 스키마에서도
        #expect(DataFinder.fallbackCandidates(terms: DataFinder.keyTerms("학년 정보는 어디 있어?"), tables: Self.large)
            .first?.location == "tb_stdnt_info.schyr")
    }

    @Test func scorerFindsSchoolNameAndMemberPhone() {
        let school = DataFinder.fallbackCandidates(terms: DataFinder.keyTerms("학교 이름은 어디야?"), tables: Self.large)
        #expect(school.first?.table == "tb_schl_info")
        #expect(school.first?.columns.first == "schl_nm")
        let phone = DataFinder.fallbackCandidates(terms: DataFinder.keyTerms("회원 전화번호 어디 있어?"), tables: Self.large)
        #expect(phone.first?.table == "tb_mbr_info")
        #expect(phone.first?.columns.first == "mbr_tel_no")
    }

    @Test func commentsStillCount() {
        let t = TableMeta(name: "t_x", columns: [Self.col("c1", comment: "학년코드"), Self.col("c2")])
        #expect(DataFinder.fallbackCandidates(terms: ["학년"], tables: [t]).first?.location == "t_x.c1")
    }

    // MARK: - 값 모양

    @Test func valueHints() {
        #expect(AbbreviationDictionary.valueFit(terms: ["학년"], samples: ["1", "2", "3", "4", "5", "6"]) == 1)
        #expect(AbbreviationDictionary.valueFit(terms: ["학년"], samples: ["1학년", "2학년", "3 학년"]) == 1)
        #expect(AbbreviationDictionary.valueFit(terms: ["학년"], samples: ["VIP", "GOLD", "SILVER"]) == -1)
        #expect(AbbreviationDictionary.valueFit(terms: ["학년"], samples: ["2019", "2020"]) == -1)
        #expect(AbbreviationDictionary.valueFit(terms: ["학교"], samples: ["a", "b"]) == 0)   // 모양 없음
        #expect(AbbreviationDictionary.valueFit(terms: ["학년"], samples: ["1"]) == 0)        // 값이 너무 적음
        #expect(AbbreviationDictionary.valueFit(terms: ["전화번호"], samples: ["010-1234-5678", "02-123-4567"]) == 1)
        #expect(AbbreviationDictionary.valueHintText(terms: ["학년"], samples: ["1", "2"]) == "values look like 학년")
        #expect(AbbreviationDictionary.valueHintText(terms: ["학년"], samples: ["VIP", "GOLD"]) == "values do not look like 학년")
    }

    @Test func valuesReorderFallbackCandidates() {
        // 회원 등급(grd)을 먼저 둔 후보라도 값이 1~6 인 schyr 가 앞으로
        var grd = DataFinder.SampledCandidate(candidate: .init(table: "tb_mbr_info", columns: ["mbr_grd_cd"]))
        grd.record("mbr_grd_cd", .values(["VIP", "GOLD", "SILVER"]))
        var yr = DataFinder.SampledCandidate(candidate: .init(table: "tb_stdnt_info", columns: ["schyr"]))
        yr.record("schyr", .values(["1", "2", "3", "4", "5", "6"]))
        let ranked = DataFinder.rankSampled(terms: ["학년"], sampled: [grd, yr], tables: Self.small)
        #expect(ranked.map(\.candidate.table) == ["tb_stdnt_info", "tb_mbr_info"])
    }

    @Test func judgePromptCarriesValueHint() {
        var s = DataFinder.SampledCandidate(candidate: .init(table: "tb_stdnt_info", columns: ["schyr"]))
        s.record("schyr", .values(["1", "2", "3"]))
        let m = DataFinder.judgeMessages(question: "학년 정보는 어디 있어?", sampled: [s], tables: Self.small, kind: .mssql,
                                         english: false, terms: ["학년"])
        #expect(m[1].content.contains("samples: 1 | 2 | 3"))
        #expect(m[1].content.contains("hint: values look like 학년"))
    }

    @Test func sampleStatusText() {
        let c = DataFinder.Candidate(table: "t", columns: ["a", "b"])
        #expect(DataFinder.SampledCandidate(candidate: c).sampleStatus == nil)
        var s = DataFinder.SampledCandidate(candidate: c)
        s.record("a", .timedOut)
        #expect(s.sampleStatus == "시간 초과")
        s.record("b", .values(["1", "2"]))
        #expect(s.sampleStatus == "값 2개")
        var f = DataFinder.SampledCandidate(candidate: c)
        f.record("a", .failed("권한 없음"))
        #expect(f.sampleStatus == "조회 실패: 권한 없음")
        #expect(f.samples["a"] == .some(nil))
    }

    // MARK: - NOLOCK

    @Test func mssqlSampleUsesNoLock() {
        #expect(DataFinder.sampleSQL(table: "tb_stdnt_info", column: "schyr", dialect: MSSQLDialect())
                == "SELECT TOP 200 [schyr] FROM [tb_stdnt_info] WITH (NOLOCK) WHERE [schyr] IS NOT NULL")
        #expect(!DataFinder.sampleSQL(table: "t", column: "c", dialect: MySQLDialect()).contains("NOLOCK"))
        #expect(DataFinder.sampleTimeout == 10)
    }

    // MARK: - 2단계 (큰 스키마)

    @Test func twoStagePromptKeepsScoredTablesWhenTruncated() {
        #expect(!DataFinder.needsTwoStages(tables: Self.small))
        #expect(DataFinder.needsTwoStages(tables: Self.large, budget: 2_000))
        // 학생 테이블은 목록 맨 끝이지만 사전 점수로 앞에, 맞은 컬럼과 함께
        let m = DataFinder.tableMessages(question: "학년 정보는 어디 있어?", terms: ["학년"], kind: .mssql,
                                         tables: Self.large, notes: [], budget: 1_000)
        let user = m.messages[1].content
        #expect(user.contains("학년 → grade, grd, schyr"))
        #expect(user.contains("tb_stdnt_info  [matching columns: schyr"))
        #expect(m.tablesSent < Self.large.count)
        #expect(user.contains("more tables not shown"))
        #expect(m.messages[0].content.contains("{\"tables\""))
        // 컬럼 정의는 보내지 않는다 (테이블 이름 · 코멘트만)
        #expect(!user.contains("varchar"))
    }

    @Test func parsesStage1Tables() {
        #expect(DataFinder.parseTables("{\"tables\":[\"TB_STDNT_INFO\",\"nope\",\"tb_schl_info\"]}", tables: Self.small)
                == ["tb_stdnt_info", "tb_schl_info"])
        #expect(DataFinder.parseTables("{\"candidates\":[{\"table\":\"tb_mbr_info\"}]}", tables: Self.small) == ["tb_mbr_info"])
        #expect(DataFinder.parseTables("학생 테이블이요", tables: Self.small) == nil)
        let many = "{\"tables\":[" + (0..<20).map { "\"tb_sys_log_\($0)\"" }.joined(separator: ",") + "]}"
        #expect(DataFinder.parseTables(many, tables: Self.large)?.count == 10)
    }

    @Test func stage2AddsTopScoredTables() {
        let t = DataFinder.stage2Tables(picked: ["tb_sys_log_1"], terms: ["학년"], tables: Self.large)
        #expect(t.first?.name == "tb_sys_log_1")
        #expect(t.contains { $0.name == "tb_stdnt_info" })
        #expect(t.count <= 1 + DataFinder.scorerExtraTables)
    }

    final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Result<String, Error>]
        private(set) var sent: [[OllamaClient.Message]] = []
        init(_ replies: [Result<String, Error>]) { self.replies = replies }
        func next(_ m: [OllamaClient.Message]) throws -> String {
            lock.lock(); defer { lock.unlock() }
            sent.append(m)
            return try (replies.isEmpty ? .success("") : replies.removeFirst()).get()
        }
    }

    @Test func twoStageFlowWithFakeTransport() async throws {
        let fake = Fake([.success("{\"tables\":[\"tb_stdnt_info\"]}"),
                         .success("{\"candidates\":[{\"table\":\"tb_stdnt_info\",\"columns\":[\"schyr\"],\"reason\":\"학년\"}]}")])
        let ai = DataFinderAI(kind: .mssql, english: false) { try fake.next($0) }
        let p = try await ai.pickCandidates(question: "학년 정보는 어디 있어?", terms: ["학년"], tables: Self.large, notes: [],
                                            budget: 2_000)
        #expect(p.twoStage)
        #expect(!p.fallback)
        #expect(p.candidates.map(\.location) == ["tb_stdnt_info.schyr"])
        #expect(fake.sent.count == 2)
        // 2단계에는 고른 테이블의 컬럼 정의만
        let stage2 = fake.sent[1][1].content
        #expect(stage2.contains("schyr tinyint"))
        #expect(!stage2.contains("tb_sys_log_150"))
    }

    @Test func findWithoutAIUsesValuesAndSaysSo() async throws {
        // 모델 오류 → 후보는 사전 점수, 판단은 값 모양 (AI 판단 요청은 보내지 않는다)
        let fake = Fake([.failure(OllamaError.http(500, "{\"error\":\"prediction aborted, token repeat limit reached\"}"))])
        let ai = DataFinderAI(kind: .mssql, english: false) { try fake.next($0) }
        let values: [String: [String]] = ["mbr_grd_cd": ["VIP", "GOLD"], "schyr": ["1", "2", "3", "4", "5", "6"]]
        let found = try await ai.find(question: "학년 정보는 어디 있어?", terms: ["학년"], tables: Self.small, notes: []) { _, col in
            .values(values[col] ?? ["x", "y"])
        }
        #expect(found.usedFallback)
        #expect(found.aiError == "prediction aborted, token repeat limit reached")
        #expect(found.verdict?.table == "tb_stdnt_info")
        #expect(found.verdict?.columns.first == "schyr")
        #expect(found.sampled.first?.candidate.table == "tb_stdnt_info")
        #expect(fake.sent.count == 1)
        #expect(found.sampleQueries > 0)
    }

    @Test func findCancelsWhenSamplesNotAllowed() async {
        let ai = DataFinderAI(kind: .mssql, english: false) { _ in "{\"candidates\":[{\"table\":\"tb_stdnt_info\",\"columns\":[\"schyr\"]}]}" }
        await #expect(throws: CancellationError.self) {
            _ = try await ai.find(question: "q", terms: ["학년"], tables: Self.small, notes: [], allowSamples: { false }) { _, _ in
                .values([])
            }
        }
    }

    // MARK: - 모델 확인

    @Test func probeOK() async {
        #expect(await ModelProbe.check { } == .ok)
    }

    @Test func probeFailureGivesShortReason() async {
        let h = await ModelProbe.check {
            throw OllamaError.http(500, "{\"error\":\"prediction aborted, token repeat limit reached\"}")
        }
        #expect(h == .failed("prediction aborted, token repeat limit reached"))
        #expect(h.reason == "prediction aborted, token repeat limit reached")
        #expect(!h.isOK)
        let plain = await ModelProbe.check { throw OllamaError.http(404, "model 'x' not found") }
        #expect(plain == .failed("model 'x' not found"))
    }

    @Test func probeTimesOut() async {
        let h = await ModelProbe.check(timeout: 0.05) { try await Task.sleep(nanoseconds: 3_000_000_000) }
        #expect(h == .timedOut)
        #expect(h.reason == "20초 안에 답이 없어요")
    }

    @Test func probeCache() async {
        let cache = ModelHealthCache()
        #expect(await cache.get("k") == nil)
        await cache.set("k", .failed("x"))
        #expect(await cache.get("k") == .failed("x"))
    }

    @Test func probeRefusesRemoteOllama() async {
        let h = await ModelProbe.check(model: "m", client: OllamaClient(baseURL: URL(string: "http://10.0.0.5:11434")!),
                                       cache: ModelHealthCache())
        if case .failed = h {} else { Issue.record("원격 주소는 실패여야 해요: \(h)") }
    }

    // MARK: - 추천 모델

    @Test func defaultModelPrefersQwen3() {
        #expect(AISettings.recommendedModels.first == "qwen3:30b")
        #expect(AISettings.defaultModel(installed: ["laguna-xs-2.1:q8_0", "qwen3:30b"]) == "qwen3:30b")
        #expect(AISettings.defaultModel(installed: ["llama3", "qwen2.5-coder:32b", "qwen2.5-coder:14b"]) == "qwen2.5-coder:14b")
        #expect(AISettings.defaultModel(installed: ["llama3", "mistral"]) == "llama3")
        #expect(AISettings.defaultModel(installed: []) == nil)
        #expect(AISettings.recommendedFirst(["a", "qwen2.5-coder:14b", "qwen3:30b"]) == ["qwen3:30b", "qwen2.5-coder:14b", "a"])
    }
}
