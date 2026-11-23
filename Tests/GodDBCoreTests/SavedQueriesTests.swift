import Foundation
import Testing
@testable import GodDBCore

@Suite("SavedQueries")
struct SavedQueriesTests {
    // MARK: - 빈칸 찾기

    @Test func specExampleFindsOnlyX() {
        // 명세 확인 기준: 캐스트 · 문자열 · 주석 안은 빈칸이 아니다
        let sql = "SELECT * FROM t WHERE a = :x AND b::text = ':y' -- :z"
        #expect(SQLParameters.names(in: sql, kind: .postgres) == ["x"])
        #expect(SQLParameters.names(in: sql, kind: .mysql) == ["x"])
    }

    @Test func namesFollowIdentifierRule() {
        let sql = "SELECT :a, :_b2, :Member_No, :1, : c, :é"
        #expect(SQLParameters.names(in: sql, kind: .mysql) == ["a", "_b2", "Member_No"])
    }

    @Test func ignoresStringLiterals() {
        let sql = #"SELECT ':a', ":b", `:c`, 'it''s :d', :e"#
        #expect(SQLParameters.names(in: sql, kind: .mysql) == ["e"])
        #expect(SQLParameters.names(in: sql, kind: .postgres) == ["e"])
        // MySQL 은 \' 가 문자열 안의 따옴표
        #expect(SQLParameters.names(in: #"SELECT 'a\' :x', :y"#, kind: .mysql) == ["y"])
    }

    @Test func ignoresEachCommentStyle() {
        #expect(SQLParameters.names(in: "SELECT :a -- :b\nFROM t WHERE c = :c", kind: .postgres) == ["a", "c"])
        #expect(SQLParameters.names(in: "SELECT /* :b\n :c */ :a", kind: .mssql) == ["a"])
        #expect(SQLParameters.names(in: "SELECT :a # :b\n, :c", kind: .mysql) == ["a", "c"])
    }

    @Test func hashIsCommentOnlyForMySQL() {
        let sql = "SELECT :a # :b"
        #expect(SQLParameters.names(in: sql, kind: .mysql) == ["a"])
        #expect(SQLParameters.names(in: sql, kind: .postgres) == ["a", "b"])
        #expect(SQLParameters.names(in: sql, kind: .mssql) == ["a", "b"])
    }

    @Test func ignoresCastAndAssignment() {
        #expect(SQLParameters.names(in: "SELECT created::date, :d::int FROM t", kind: .postgres) == ["d"])
        #expect(SQLParameters.names(in: "SET @n := 1; SELECT :n", kind: .mysql) == ["n"])
        #expect(SQLParameters.names(in: "SELECT a:=b", kind: .mysql).isEmpty)
    }

    @Test func ignoresPostgresDollarQuotes() {
        let sql = "DO $$ BEGIN PERFORM :inner; END $$; SELECT :outer"
        #expect(SQLParameters.names(in: sql, kind: .postgres) == ["outer"])
    }

    @Test func dedupesRepeatedNamesInFirstOrder() {
        let sql = "SELECT * FROM t WHERE a = :id OR b = :from OR c = :id"
        #expect(SQLParameters.names(in: sql, kind: .mysql) == ["id", "from"])
        #expect(SQLParameters.occurrences(in: sql, kind: .mysql).count == 3)
    }

    // MARK: - 값 변환

    @Test func convertsNumbersAndStrings() {
        let my = MySQLDialect()
        #expect(SQLParameters.render(.init(value: "1023"), dialect: my) == "1023")
        #expect(SQLParameters.render(.init(value: "-3.5"), dialect: my) == "-3.5")
        #expect(SQLParameters.render(.init(value: "2026-11-01"), dialect: my) == "'2026-11-01'")
        #expect(SQLParameters.render(.init(value: "O'Neil"), dialect: PostgresDialect()) == "'O''Neil'")
        #expect(SQLParameters.render(.init(value: "1e5"), dialect: my) == "'1e5'")
    }

    @Test func nullAndRaw() {
        let my = MySQLDialect()
        #expect(SQLParameters.render(.init(value: "abc", isNull: true), dialect: my) == "NULL")
        #expect(SQLParameters.render(.init(value: "NOW()", raw: true), dialect: my) == "NOW()")
        // 그대로 넣기면 쉼표도 그대로
        #expect(SQLParameters.render(.init(value: "1,2,3", raw: true), dialect: my) == "1,2,3")
        // NULL 이 그대로 넣기보다 먼저
        #expect(SQLParameters.render(.init(value: "x", isNull: true, raw: true), dialect: my) == "NULL")
    }

    @Test func commaExpandsToList() {
        let my = MySQLDialect()
        #expect(SQLParameters.render(.init(value: "1,2,3"), dialect: my) == "1, 2, 3")
        #expect(SQLParameters.render(.init(value: "a, b ,7"), dialect: my) == "'a', 'b', 7")
        let sql = SQLParameters.fill("SELECT * FROM t WHERE id IN (:ids)", inputs: ["ids": .init(value: "1,2,3")], dialect: my)
        #expect(sql == "SELECT * FROM t WHERE id IN (1, 2, 3)")
    }

    @Test func mssqlUsesNPrefix() {
        let ms = MSSQLDialect()
        #expect(SQLParameters.render(.init(value: "kim"), dialect: ms) == "N'kim'")
        #expect(SQLParameters.render(.init(value: "kim,lee"), dialect: ms) == "N'kim', N'lee'")
        #expect(SQLParameters.render(.init(value: "10"), dialect: ms) == "10")
    }

    @Test func fillReplacesEveryOccurrenceAndKeepsOthers() {
        let sql = "SELECT ':id', a::text FROM t WHERE a = :id AND b = :name OR c = :id -- :id"
        let out = SQLParameters.fill(sql, inputs: ["id": .init(value: "7"), "name": .init(value: "kim")], dialect: PostgresDialect())
        #expect(out == "SELECT ':id', a::text FROM t WHERE a = 7 AND b = 'kim' OR c = 7 -- :id")
        // 입력이 없는 빈칸은 그대로
        #expect(SQLParameters.substitute("SELECT :a, :b", fragments: ["a": "1"], kind: .mysql) == "SELECT 1, :b")
    }

    // MARK: - 이름 · 목록

    @Test func defaultNameIsFirstLine40Chars() {
        #expect(SavedQuery.defaultName(for: "\n  SELECT * FROM member WHERE member_no = :memberNo AND x = 1\nORDER BY 1")
                == String("SELECT * FROM member WHERE member_no = :memberNo AND x = 1".prefix(40)))
        #expect(SavedQuery.defaultName(for: "SELECT 1") == "SELECT 1")
    }

    @Test func searchGroupsAndVisibility() {
        let p1 = UUID(), p2 = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = SavedQuery(name: "회원 조회", folder: "회원", sql: "SELECT * FROM member WHERE no = :no", createdAt: t0,
                           lastUsedAt: t0.addingTimeInterval(50))
        let b = SavedQuery(name: "주문", folder: "", sql: "SELECT * FROM orders", createdAt: t0.addingTimeInterval(10))
        let c = SavedQuery(name: "탈퇴 회원", folder: "회원", sql: "SELECT 1", scope: .profile, profileID: p1,
                           createdAt: t0, lastUsedAt: t0.addingTimeInterval(100))
        let lib = SavedQueryLibrary(queries: [a, b, c])

        #expect(lib.search("", profileID: p1).count == 3)
        #expect(lib.search("", profileID: p2).map(\.id) == [a.id, b.id])
        #expect(lib.search("", profileID: nil).map(\.id) == [a.id, b.id])
        // 이름 · SQL · 폴더, 대소문자 무시
        #expect(lib.search("ORDERS", profileID: p1).map(\.id) == [b.id])
        #expect(lib.search("회원", profileID: p2).map(\.id) == [a.id])
        #expect(lib.search("member :no", profileID: p2).map(\.id) == [a.id])
        #expect(lib.folders == ["회원"])

        let groups = SavedQueryLibrary.grouped(lib.search("", profileID: p1))
        #expect(groups.map(\.folder) == ["회원", ""])
        #expect(groups[0].queries.map(\.id) == [c.id, a.id])
    }

    @Test func libraryEdits() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var lib = SavedQueryLibrary(queries: [SavedQuery(name: "q", sql: "SELECT :a", createdAt: t0)])
        let id = lib.queries[0].id
        lib.rename(id, to: "  새 이름 ", now: t0.addingTimeInterval(1))
        lib.rename(id, to: "   ")
        #expect(lib[id]?.name == "새 이름")
        #expect(lib[id]?.updatedAt == t0.addingTimeInterval(1))
        lib.setFolder(id, to: " 보고서 ")
        #expect(lib[id]?.folder == "보고서")
        lib.markUsed(id, values: ["a": "5"], now: t0.addingTimeInterval(9))
        #expect(lib[id]?.lastValues == ["a": "5"])
        #expect(lib[id]?.lastUsedAt == t0.addingTimeInterval(9))
        let copy = lib.duplicate(id, suffix: " 사본")
        #expect(copy?.name == "새 이름 사본")
        #expect(copy?.lastUsedAt == nil && copy?.lastValues == ["a": "5"] && copy?.id != id)
        lib.delete(id)
        #expect(lib.queries.map(\.id) == [copy!.id])
    }

    @Test func profileIDOnlyKeptForProfileScope() {
        let q = SavedQuery(name: "a", sql: "SELECT 1", scope: .all, profileID: UUID())
        #expect(q.profileID == nil)
    }

    // MARK: - 저장 형식

    @Test func storeRoundTripAndJSONKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-saved-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LocalDataCrypto(provider: StaticLocalDataKeyProvider())
        let store = SavedQueryStore(file: dir.appendingPathComponent("saved-queries.json"), crypto: crypto)
        #expect(store.load() == SavedQueryLibrary())

        let profile = UUID()
        let t0 = Date(timeIntervalSince1970: 1_763_600_000)
        let a = SavedQuery(name: "회원", folder: "업무", sql: "SELECT * FROM member WHERE no = :memberNo", scope: .profile,
                           profileID: profile, lastValues: ["memberNo": "1023"], createdAt: t0, lastUsedAt: t0)
        let b = SavedQuery(name: "전체", sql: "SELECT 1", createdAt: t0)
        store.save(SavedQueryLibrary(queries: [a, b]))
        #expect(store.load() == SavedQueryLibrary(queries: [a, b]))

        // 디스크는 암호화돼 있다 (GDBENC1). 풀면 Windows 판과 같은 JSON.
        let raw = try Data(contentsOf: store.file)
        #expect(LocalDataCrypto.isEncrypted(raw))
        #expect(raw.range(of: Data("member".utf8)) == nil)
        let data = try crypto.decryptDocument(raw)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let queries = try #require(json["queries"] as? [[String: Any]])
        #expect(Set(queries[0].keys) == ["id", "name", "folder", "sql", "scope", "profileID", "lastValues",
                                         "createdAt", "updatedAt", "lastUsedAt"])
        #expect(queries[0]["scope"] as? String == "profile")
        #expect(queries[0]["profileID"] as? String == profile.uuidString)
        #expect(queries[0]["lastValues"] as? [String: String] == ["memberNo": "1023"])
        // ISO 8601 날짜
        #expect(queries[0]["createdAt"] as? String == "2025-11-20T00:53:20Z")
        #expect(queries[1]["scope"] as? String == "all")
        #expect(queries[1]["profileID"] is NSNull)
        #expect(queries[1]["lastUsedAt"] is NSNull)
    }

    @Test func readsMinimalFileFromOtherApps() throws {
        // Windows 판이 빠뜨린 칸이 있어도 읽는다
        let json = """
        {"version":1,"queries":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"q","sql":"SELECT :a",
          "scope":"all","createdAt":"2026-11-20T01:02:03Z"}]}
        """
        let lib = try SavedQueryStore.decode(Data(json.utf8))
        #expect(lib.queries.count == 1)
        #expect(lib.queries[0].folder == "")
        #expect(lib.queries[0].lastValues.isEmpty)
        #expect(lib.queries[0].updatedAt == lib.queries[0].createdAt)
        #expect(lib.queries[0].lastUsedAt == nil)
    }
}
