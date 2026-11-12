import Foundation
import Testing
@testable import GodDBCore

@Suite("DiagramAI")
struct DiagramAITests {
    let member = TableMeta(name: "member", comment: "회원",
                           columns: [ColumnMeta(name: "member_id", columnType: "bigint", nullable: false, defaultValue: nil, extra: "", columnKey: "PRI", comment: "회원 번호", position: 1),
                                     ColumnMeta(name: "name", columnType: "varchar(50)", nullable: true, defaultValue: nil, extra: "", columnKey: "", comment: "", position: 2)],
                           indexes: [IndexMeta(name: "PRIMARY", unique: true, columns: ["member_id"], primary: true)])
    var order: TableMeta {
        TableMeta(name: "orders", comment: "",
                  columns: [ColumnMeta(name: "order_id", columnType: "bigint", nullable: false, defaultValue: nil, extra: "", columnKey: "PRI", comment: "", position: 1),
                            ColumnMeta(name: "member_id", columnType: "bigint", nullable: false, defaultValue: nil, extra: "", columnKey: "", comment: "", position: 2)],
                  indexes: [IndexMeta(name: "PRIMARY", unique: true, columns: ["order_id"], primary: true)],
                  foreignKeys: [ForeignKeyMeta(name: "fk_member", table: "orders", columns: ["member_id"], referencedTable: "member", referencedColumns: ["member_id"])])
    }

    @Test func schemaTextHasStructureAndRelations() {
        let guess = ForeignKeyMeta(name: "guess", table: "orders", columns: ["x"], referencedTable: "member", referencedColumns: ["member_id"])
        let text = DiagramAI.schemaText([member, order], inferred: [guess])
        #expect(text.contains("TABLE member  -- 회원"))
        #expect(text.contains("member_id bigint PK NOT NULL  -- 회원 번호"))
        #expect(text.contains("orders(member_id) -> member(member_id)"))
        #expect(text.contains("guessed"))
        #expect(text.contains("orders(x) -> member(member_id)"))
    }

    @Test func schemaTextShrinksWhenHuge() {
        let cols = (1...80).map { ColumnMeta(name: "column_\($0)_with_a_long_name", columnType: "varchar(255)", nullable: true, defaultValue: nil, extra: "", columnKey: "", comment: String(repeating: "c", count: 60), position: $0) }
        let tables = (1...60).map { TableMeta(name: "t\($0)", columns: cols) }
        let text = DiagramAI.schemaText(tables, inferred: [])
        #expect(text.count < DiagramAI.maxSchemaChars + 2_000)
        #expect(text.contains("more columns"))
    }

    @Test func messagesPutSchemaFirstAndCleanThink() {
        let m = DiagramAI.messages(kind: .postgres, schema: "S", history: [(role: "user", content: "Q")], english: false)
        #expect(m.first?.role == "system")
        #expect(m[1].content.hasSuffix("S"))
        #expect(m.last?.content == "Q")
        #expect(DiagramAI.clean("<think>abc</think>\n답") == "답")
        #expect(DiagramAI.clean("<think>아직 생각") == "")
    }
}

/// 실제 로컬 Ollama 로 관계 분석 + 이어지는 질문 (GODDB_OLLAMA_MODEL 이 있을 때만, 수십 초 걸림)
@Suite("DiagramAI live", .enabled(if: ProcessInfo.processInfo.environment["GODDB_OLLAMA_MODEL"] != nil))
struct DiagramAILiveTests {
    @Test func analyzesAndAnswersFollowUp() async throws {
        let model = ProcessInfo.processInfo.environment["GODDB_OLLAMA_MODEL"]!
        let base = DiagramAITests()
        let schema = DiagramAI.schemaText([base.member, base.order], inferred: [])
        let client = OllamaClient()
        func ask(_ history: [(role: String, content: String)]) async throws -> String {
            var text = ""
            for try await chunk in client.chat(model: model, messages: DiagramAI.messages(kind: .mysql, schema: schema, history: history, english: false)) {
                if case .content(let c) = chunk { text += c }
            }
            return DiagramAI.clean(text)
        }
        var history: [(role: String, content: String)] = [(role: "user", content: DiagramAI.analysisQuestion(english: false))]
        let first = try await ask(history)
        print("ANALYSIS:\n\(first)")
        #expect(first.contains("member") && first.contains("orders"))
        history.append((role: "assistant", content: first))
        history.append((role: "user", content: "회원별 주문 수를 구하는 SQL 만 짧게 줘"))
        let second = try await ask(history)
        print("FOLLOW-UP:\n\(second)")
        #expect(second.uppercased().contains("JOIN") || second.uppercased().contains("GROUP BY"))
    }
}
