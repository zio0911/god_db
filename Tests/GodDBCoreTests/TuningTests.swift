import Foundation
import Testing
@testable import GodDBCore

@Suite("Tuning parse")
struct TuningParseTests {
    @Test func parsesSections() {
        let text = """
        <think>internal</think>
        ## 요약
        status 조건에 인덱스가 없어 풀 스캔해요.

        ## 개선 SQL
        ```sql
        SELECT member_id FROM tb_member WHERE status = 'A'
        ```

        ## 추천 인덱스
        ```sql
        CREATE INDEX idx_member_status ON tb_member (status);
        ```

        ## 설명
        - 인덱스로 스캔 범위를 줄여요.
        """
        let r = TuningResult.parse(text)
        #expect(r.summary.hasPrefix("status 조건"))
        #expect(r.improvedSQL == "SELECT member_id FROM tb_member WHERE status = 'A'")
        #expect(r.indexSQL?.hasPrefix("CREATE INDEX idx_member_status") == true)
        #expect(r.hasIndexes)
        #expect(r.explanation.contains("스캔 범위"))
        #expect(!r.raw.contains("internal"))
    }

    @Test func noIndexesAndEnglishHeadings() {
        let r = TuningResult.parse("""
        ## Summary
        Fine already.
        ## Improved SQL
        ```sql
        SELECT 1
        ```
        ## Recommended indexes
        ```sql
        -- none needed
        ```
        ## Explanation
        - nothing
        """)
        #expect(r.improvedSQL == "SELECT 1")
        #expect(!r.hasIndexes)
        #expect(r.summary == "Fine already.")
    }
}

/// 실제 로컬 Ollama 로 튜닝 (GODDB_OLLAMA_MODEL 과 MySQL 테스트 DB 가 있을 때만, 수십 초 걸림)
@Suite("Tuning live", .serialized, .enabled(if: ProcessInfo.processInfo.environment["GODDB_OLLAMA_MODEL"] != nil
                                             && ProcessInfo.processInfo.environment["GODDB_IT_PORT"] != nil))
struct TuningLiveTests {
    @Test func tunesWithLocalModel() async throws {
        let env = ProcessInfo.processInfo.environment
        let client = OllamaClient()
        #expect(await client.status().isRunning)
        let profile = ConnectionProfile(name: "it", host: "127.0.0.1", port: Int(env["GODDB_IT_PORT"]!)!,
                                        username: "root", database: "shop", useTLS: false)
        let s = try await DBSession.connect(profile: profile, password: env["GODDB_IT_PASSWORD"])
        try await s.use("shop")
        let tables = try await s.loadSchema("shop")
        let sql = "SELECT member_id, email FROM tb_member WHERE status = 'A' ORDER BY reg_dt DESC"
        let ctx = await s.tuningContext(sql: sql, knownTables: tables)
        #expect(ctx.tables.map(\.meta.name) == ["tb_member"])
        #expect(ctx.plan != nil)
        #expect(ctx.warnings.contains { $0.message.contains("풀 테이블 스캔") })

        var text = ""
        for try await chunk in client.chat(model: env["GODDB_OLLAMA_MODEL"]!, messages: TuningPrompt.messages(ctx, english: false)) {
            if case .content(let c) = chunk { text += c }
        }
        let r = TuningResult.parse(text)
        print("TUNING RESULT:\n\(text)")
        #expect(!r.summary.isEmpty)
        #expect(r.improvedSQL?.uppercased().contains("TB_MEMBER") == true)
        // 개선 SQL 은 실행 계획을 다시 떠볼 수 있어야 한다
        if let improved = r.improvedSQL {
            _ = try await s.explain(improved.trimmingCharacters(in: CharacterSet(charactersIn: ";\n ")))
        }
        await s.close()
    }
}
