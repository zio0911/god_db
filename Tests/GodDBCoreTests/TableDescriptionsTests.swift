import Foundation
import Testing
@testable import GodDBCore

/// 테이블 · 컬럼 · 데이터 설명 JSON (#178)
@Suite("Table descriptions")
struct TableDescriptionsTests {
    static func col(_ name: String, _ comment: String = "", position: Int = 0) -> ColumnMeta {
        ColumnMeta(name: name, columnType: "varchar(20)", nullable: true, comment: comment, position: position)
    }

    static let orders = TableMeta(name: "orders", columns: [col("id", position: 1), col("member_id", position: 2),
                                                             col("status", "주문 상태", position: 3)],
                                  foreignKeys: [ForeignKeyMeta(name: "fk_member", table: "orders", columns: ["member_id"],
                                                               referencedTable: "members", referencedColumns: ["id"])])
    static let members = TableMeta(name: "members", comment: "회원", columns: [col("id"), col("grade_cd")])

    static let sample = """
    {
      "format": "goddb-table-descriptions", "version": 1, "database": "shop",
      "overview": "쇼핑몰 주문 DB",
      "tables": [
        { "name": "orders", "title": "주문", "description": "결제한 주문 한 건", "terms": ["결제 내역"],
          "columns": [
            { "name": "status", "title": "상태", "values": { "P": "결제 대기", "C": "완료" } },
            { "name": "member_id", "references": "members.id" },
            { "name": "deleted_at", "title": "삭제일시" }
          ],
          "notes": ["deleted_at IS NULL 조건을 붙인다"] },
        { "name": "members", "columns": [ { "name": "grade_cd", "title": "회원 등급", "terms": ["등급"] } ] },
        { "name": "old_coupon" }
      ]
    }
    """

    func doc() throws -> TableDescriptionDoc { try TableDescriptionDoc.parse(Data(Self.sample.utf8)) }

    @Test func parsesSampleAndCounts() throws {
        let d = try doc()
        #expect(d.tables.count == 3)
        #expect(d.columnCount == 4)
        #expect(d.valueCount == 2)
        #expect(d.table("public.orders")?.column("STATUS")?.values?["C"] == "완료")
    }

    @Test func parseErrorsSayWhere() {
        func error(_ json: String) -> TableDescriptionDoc.ParseError? {
            do { _ = try TableDescriptionDoc.parse(Data(json.utf8)); return nil } catch { return error as? TableDescriptionDoc.ParseError }
        }
        if case .notJSON? = error("{ tables: ") {} else { Issue.record("not JSON") }
        #expect(error(#"{"tables": [{"title": "x"}]}"#) == .invalid(path: "tables[0].name", reason: "꼭 있어야 하는 칸이 없어요"))
        #expect(error(#"{"tables": [{"name": "t", "columns": [{"name": "c", "values": ["P"]}]}]}"#)?
            .errorDescription?.contains("tables[0].columns[0].values") == true)
        #expect(error(#"{"format": "other", "tables": [{"name": "t"}]}"#) == .wrongFormat("other"))
        #expect(error(#"{"version": 9, "tables": [{"name": "t"}]}"#) == .newerVersion(9))
        #expect(error(#"{"tables": []}"#) == .empty)
        #expect(error(#"{"tables": [{"name": " "}]}"#) == .invalid(path: "tables[0].name", reason: "비어 있어요"))
    }

    @Test func roundTripsThroughEncoding() throws {
        let d = try doc()
        #expect(try TableDescriptionDoc.parse(d.encoded()) == d)
    }

    @Test func skeletonHasNamesCommentsAndForeignKeysOnly() throws {
        let s = TableDescriptionDoc.skeleton(tables: [Self.orders, Self.members], database: "shop")
        #expect(s.format == TableDescriptionDoc.formatName && s.database == "shop")
        #expect(s.table("orders")?.columns?.map(\.name) == ["id", "member_id", "status"])
        #expect(s.table("orders")?.column("status")?.title == "주문 상태")
        #expect(s.table("orders")?.column("member_id")?.references == "members.id")
        #expect(s.table("members")?.title == "회원")
        #expect(s.tables.allSatisfy { ($0.columns ?? []).allSatisfy { $0.values == nil } })
        // 빈 양식도 다시 읽힌다
        #expect(try TableDescriptionDoc.parse(s.encoded()).tables.count == 2)
    }

    @Test func requestPromptNamesFormatAndDatabase() {
        for english in [false, true] {
            let p = TableDescriptionDoc.requestPrompt(database: "shop", kind: .postgres, english: english)
            #expect(p.contains(TableDescriptionDoc.formatName))
            #expect(p.contains("`shop`"))
            #expect(p.contains("values"))
        }
    }

    @Test func checksAgainstDatabase() throws {
        let c = try doc().check(against: [Self.orders, Self.members, TableMeta(name: "carts")])
        #expect(c.missingTables == ["old_coupon"])
        #expect(c.unknownColumns == ["orders.deleted_at"])
        #expect(c.undescribedTables == ["carts"])
        #expect(!c.isClean)
    }

    @Test func titlesFillOnlyEmptyComments() throws {
        let out = try doc().applyTitles(to: [Self.orders, Self.members])
        #expect(out[0].comment == "주문")
        #expect(out[0].columns.first { $0.name == "status" }?.comment == "주문 상태")   // 원래 코멘트 유지
        #expect(out[1].comment == "회원")
        #expect(out[1].columns.first { $0.name == "grade_cd" }?.comment == "회원 등급")
    }

    @Test func questionFindsTableByTitleOrTerm() throws {
        let d = try doc()
        let tables = [Self.orders, Self.members]
        #expect(AssistantAI.mentionedTables("결제 내역 보여줘", in: tables).isEmpty)
        #expect(AssistantAI.mentionedTables("결제 내역 보여줘", in: tables, aliases: d.aliases).map(\.name) == ["orders"])
        #expect(AssistantAI.mentionedTables("주문 상태별 건수", in: d.applyTitles(to: tables)).map(\.name) == ["orders"])
    }

    @Test func contextHasMeaningValuesAndRules() throws {
        let text = try #require(try doc().contextText(focus: ["orders"]))
        #expect(text.contains("쇼핑몰 주문 DB"))
        #expect(text.contains("orders — 주문: 결제한 주문 한 건"))
        #expect(text.contains("C=완료, P=결제 대기"))
        #expect(text.contains("→ members.id"))
        #expect(text.contains("rule: deleted_at IS NULL"))
        #expect(!text.contains("grade_cd"))
        #expect(try doc().contextText(focus: ["orders"], limit: 10)?.contains("truncated") == true)
    }

    @Test func finderNotesMatchTitlesAndTerms() throws {
        let p = UUID()
        let notes = try doc().finderNotes(profileID: p, database: "shop")
        #expect(DataFinder.matchNotes(terms: ["등급"], in: notes).map(\.location) == ["members.grade_cd"])
        #expect(DataFinder.matchNotes(terms: ["결제", "내역"], in: notes).map(\.location) == ["orders"])
        // id 는 위치마다 늘 같다
        #expect(try doc().finderNotes(profileID: p, database: "shop").map(\.id) == notes.map(\.id))
        #expect(Set(notes.map(\.id)).count == notes.count)
    }

    @Test func confirmAddsTermsAndRejectRemovesThem() throws {
        var d = try doc()
        d.addTerms(["학년 정보"], table: "members", columns: ["grade_cd"])
        d.addTerms(["쿠폰"], table: "coupons", columns: [])
        d.addTerms(["가입 경로"], table: "members", columns: ["join_path"])
        #expect(d.table("members")?.column("grade_cd")?.terms == ["등급", "학년 정보"])
        #expect(d.table("coupons")?.terms == ["쿠폰"])
        #expect(d.table("members")?.column("join_path")?.terms == ["가입 경로"])
        d.removeTerms(["학년정보"], table: "members", columns: ["grade_cd"])
        #expect(d.table("members")?.column("grade_cd")?.terms == ["등급"])
        d.removeTerms(["쿠폰"], table: "coupons", columns: [])
        #expect(d.table("coupons")?.terms == nil)
    }

    @Test func migratesOnlyConfirmedNotesOnce() {
        let p = UUID(), now = Date(timeIntervalSince1970: 100)
        var notes = TableNoteLibrary()
        notes.add(TableNote(profileID: p, database: "shop", table: "members", columns: ["grade_cd"], terms: ["학년"], memo: "1~6"))
        notes.add(TableNote(profileID: p, database: "shop", table: "orders", columns: [], terms: ["주문"], memo: "취소도 남음"))
        notes.add(TableNote(profileID: p, database: "shop", table: "orders", columns: ["a", "b"], terms: ["묶음"], memo: "둘이 짝"))
        notes.add(TableNote(profileID: p, database: "shop", table: "carts", terms: ["장바구니"], source: .ai, confirmed: false))
        var lib = TableDescriptionLibrary()
        lib.migrate(notes, now: now)
        let d = lib.doc(profileID: p, database: "shop")
        #expect(d?.table("members")?.column("grade_cd")?.terms == ["학년"])
        #expect(d?.table("members")?.column("grade_cd")?.description == "1~6")
        #expect(d?.table("orders")?.description == "취소도 남음")
        #expect(d?.table("orders")?.notes == ["a, b: 둘이 짝"])
        #expect(d?.table("carts") == nil)
        #expect(lib.migratedNotes)
        // 두 번째는 아무것도 하지 않는다
        var again = lib
        again.migrate(notes, now: now)
        #expect(again == lib)
    }

    @Test func storeSavesPrivatelyAndMigratesOnFirstLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = UUID()
        let noteStore = TableNoteStore(file: dir.appendingPathComponent("table-notes.json"))
        var notes = TableNoteLibrary()
        notes.add(TableNote(profileID: p, database: "db", table: "t", terms: ["말"]))
        noteStore.save(notes)
        let store = TableDescriptionStore(file: dir.appendingPathComponent("table-descriptions.json"))
        var lib = store.loadMigrating(notes: noteStore)
        #expect(lib.doc(profileID: p, database: "db")?.table("t")?.terms == ["말"])
        let perms = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        // 옮긴 뒤 지워도 다시 옮기지 않는다 (메모 파일은 그대로)
        lib.remove(profileID: p, database: "db")
        store.save(lib)
        #expect(store.loadMigrating(notes: noteStore).entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: noteStore.file.path))
    }
}
