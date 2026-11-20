import Foundation
import Testing
@testable import GodDBCore

@Suite("TableNotes")
struct TableNotesTests {
    static let profile = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let date = Date(timeIntervalSince1970: 1_795_000_000)

    @Test func storeRoundTripAndJSONKeys() throws {
        var lib = TableNoteLibrary()
        lib.add(TableNote(profileID: Self.profile, database: "school", table: "tb_student", columns: ["grade_cd"],
                          terms: ["학년"], memo: "학생 테이블의 학년 코드 (1~6)", source: .ai, confirmed: false, createdAt: Self.date))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TableNoteStore(file: dir.appendingPathComponent("table-notes.json"))
        store.save(lib)
        #expect(store.load() == lib)

        // 권한 본인만
        let attrs = try FileManager.default.attributesOfItem(atPath: store.file.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        // 명세의 키 이름 · ISO 8601 날짜 (Windows 판과 같은 형식)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let note = try #require((json["notes"] as? [[String: Any]])?.first)
        #expect(Set(note.keys) == ["id", "profileID", "database", "table", "columns", "terms", "memo", "source", "confirmed",
                                   "createdAt", "updatedAt"])
        #expect(note["source"] as? String == "ai")
        #expect(note["confirmed"] as? Bool == false)
        #expect(note["profileID"] as? String == Self.profile.uuidString)
        #expect((note["createdAt"] as? String)?.hasSuffix("Z") == true)
    }

    @Test func readsSpecExampleAndMissingFields() throws {
        let text = """
        {"version":1,"notes":[
          {"id":"8C1F0000-0000-0000-0000-000000000001","profileID":"11111111-2222-3333-4444-555555555555",
           "database":"school","table":"tb_student","columns":["grade_cd"],"terms":["학년"],
           "memo":"학생 테이블의 학년 코드 (1~6)","source":"ai","confirmed":false,
           "createdAt":"2026-11-20T10:00:00Z","updatedAt":"2026-11-20T10:00:00Z"},
          {"id":"8C1F0000-0000-0000-0000-000000000002","profileID":"11111111-2222-3333-4444-555555555555","table":"tb_school"}
        ]}
        """
        let lib = try TableNoteStore.decode(Data(text.utf8))
        #expect(lib.notes.count == 2)
        #expect(lib.notes[0].terms == ["학년"])
        #expect(lib.notes[0].source == .ai)
        #expect(lib.notes[1].database == "")
        #expect(lib.notes[1].columns.isEmpty)
        #expect(lib.notes[1].source == .user)
    }

    @Test func userNotesAreConfirmedByDefault() {
        #expect(TableNote(profileID: Self.profile, database: "d", table: "t", source: .user).confirmed)
        #expect(!TableNote(profileID: Self.profile, database: "d", table: "t", source: .ai).confirmed)
    }

    @Test func autoSaveMergesTermsForSameLocation() {
        var lib = TableNoteLibrary()
        let first = lib.saveFound(profileID: Self.profile, database: "school", table: "tb_student", columns: ["grade_cd"],
                                  terms: ["학년"], memo: "학년 코드", now: Self.date)
        // 같은 table+columns (대소문자 · 순서 무시) → terms 만 합친다, 같은 말(공백 · 대소문자 무시)은 한 번
        let second = lib.saveFound(profileID: Self.profile, database: "school", table: "TB_STUDENT", columns: ["GRADE_CD"],
                                   terms: ["학년 코드", "학년"], memo: "다른 설명", now: Self.date.addingTimeInterval(60))
        #expect(first == second)
        #expect(lib.notes.count == 1)
        #expect(lib.notes[0].terms == ["학년", "학년 코드"])
        #expect(lib.notes[0].memo == "학년 코드")
        #expect(lib.notes[0].source == .ai)
        #expect(!lib.notes[0].confirmed)
        #expect(lib.notes[0].updatedAt == Self.date.addingTimeInterval(60))
        // 다른 컬럼 · 다른 DB 는 새 메모
        lib.saveFound(profileID: Self.profile, database: "school", table: "tb_student", columns: ["grade_cd", "class_no"],
                      terms: ["반"], memo: "")
        lib.saveFound(profileID: Self.profile, database: "other", table: "tb_student", columns: ["grade_cd"], terms: ["학년"], memo: "")
        #expect(lib.notes.count == 3)
        #expect(TableNoteLibrary.mergeTerms(["학년", "Grade"], ["grade", " 학 년 ", ""]) == ["학년", "Grade"])
    }

    @Test func filtersByConnectionDatabaseAndTable() {
        var lib = TableNoteLibrary()
        let other = UUID()
        lib.add(TableNote(profileID: Self.profile, database: "school", table: "tb_student", terms: ["학년"], source: .ai,
                          confirmed: false, createdAt: Self.date))
        lib.add(TableNote(profileID: Self.profile, database: "school", table: "tb_school", terms: ["학교"], source: .user,
                          createdAt: Self.date.addingTimeInterval(-100)))
        lib.add(TableNote(profileID: other, database: "school", table: "tb_student", terms: ["학년"]))
        lib.add(TableNote(profileID: Self.profile, database: "dev", table: "tb_student", terms: ["학년"]))
        #expect(lib.notes(profileID: Self.profile, database: "school").map(\.table) == ["tb_school", "tb_student"])
        #expect(lib.notes(profileID: Self.profile, database: "school", table: "TB_STUDENT").count == 1)
        #expect(lib.tablesWithNotes(profileID: Self.profile, database: "school") == ["tb_student", "tb_school"])
        #expect(lib.tablesWithNotes(profileID: Self.profile, database: "none").isEmpty)
    }

    @Test func updateAndDelete() {
        var lib = TableNoteLibrary()
        let id = lib.saveFound(profileID: Self.profile, database: "s", table: "t", columns: ["c"], terms: ["x"], memo: "", now: Self.date)
        lib.update(id, now: Self.date.addingTimeInterval(5)) { $0.confirmed = true }
        #expect(lib[id]?.confirmed == true)
        #expect(lib[id]?.updatedAt == Self.date.addingTimeInterval(5))
        lib.delete(id)
        #expect(lib.notes.isEmpty)
    }

    @Test func contextTextForAssistant() {
        var lib = TableNoteLibrary()
        #expect(lib.contextText(profileID: Self.profile, database: "s") == nil)
        for i in 0..<60 {
            lib.add(TableNote(profileID: Self.profile, database: "s", table: "t\(i)", columns: ["c"], terms: ["말\(i)"], memo: "m",
                              source: .ai, confirmed: false))
        }
        let text = lib.contextText(profileID: Self.profile, database: "s") ?? ""
        #expect(text.hasPrefix("Data locations confirmed by the team"))
        #expect(text.components(separatedBy: "\n  - ").count - 1 == 50)
        #expect(text.contains("(unconfirmed)"))
    }

    @Test func splitsCommaText() {
        #expect(TableNote.split(" 학년, 학년코드 ,, 학년 ") == ["학년", "학년코드"])
    }
}
