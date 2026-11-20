import Foundation
import Testing
@testable import GodDBCore

@Suite("IDSearch")
struct IDSearchTests {
    static let log = """
    2026-11-20 10:01:02 ERROR [main] memberNo=1023 failed (code 500)
    2026-11-20 10:01:03.120 WARN memberNo=2044, orderId=A-77 retry
    2026-11-20T10:01:04Z INFO memberNo=1023 done v1.2 user42
    """

    @Test func extractsNumbersFromThreeLogLinesInOrderWithoutDuplicates() {
        let r = IDSearch.extract(Self.log, numeric: true)
        // 날짜 · 시각 · 버전(1.2) · 단어에 붙은 숫자(user42, A-77)는 빼고
        #expect(r.values == ["1023", "500", "2044"])
        #expect(r.duplicates == 1)
        #expect(r.overflow == 0)
        #expect(r.uniqueCount == 3)
    }

    @Test func numericKeepsNegativeAndDedupesLeadingZeros() {
        let r = IDSearch.extract("id=-5 id=007 id=7 id=8", numeric: true)
        #expect(r.values == ["-5", "007", "8"])
        #expect(r.duplicates == 1)
    }

    @Test func textModeExcludesDatesTimesAndLevels() {
        let r = IDSearch.extract(Self.log, numeric: false)
        #expect(!r.values.contains { $0.hasPrefix("2026-11-20") })
        #expect(!r.values.contains("10:01:02"))
        #expect(!r.values.contains("10:01:03.120"))
        #expect(!r.values.contains("ERROR") && !r.values.contains("WARN") && !r.values.contains("INFO"))
        #expect(r.values.contains("A-77"))
        #expect(r.values.contains("1023") && r.values.contains("2044"))
        #expect(r.values.filter { $0 == "memberNo" }.count == 1)
        // 문장 끝 마침표는 떼기
        #expect(IDSearch.extract("see ORD-1. and debug", numeric: false).values == ["see", "ORD-1", "and"])
    }

    @Test func textModeKeepsUUIDs() {
        let uuid = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
        #expect(IDSearch.extract("req=\(uuid) INFO", numeric: false).values == ["req", uuid])
    }

    @Test func capsAtOneThousand() {
        let text = (1...1500).map { "id=\($0)" }.joined(separator: "\n") + "\nid=1"
        let r = IDSearch.extract(text, numeric: true)
        #expect(r.values.count == 1000)
        #expect(r.values.first == "1" && r.values.last == "1000")
        #expect(r.overflow == 500)
        #expect(r.duplicates == 1)
        #expect(r.uniqueCount == 1500)
    }

    @Test func previewShowsFirstTwenty() {
        let values = (1...25).map(String.init)
        let p = IDSearch.preview(values)
        #expect(p.hasPrefix("1, 2, 3"))
        #expect(p.contains("20") && !p.contains("21,"))
        #expect(p.hasSuffix(tr("…외 %@개", "5")))
        #expect(IDSearch.preview(["a", "b"]) == "a, b")
    }

    @Test func numericTypes() {
        for t in ["int", "bigint(20) unsigned", "INT UNSIGNED", "numeric(10,2)", "decimal(12,2)", "integer", "int4", "bigserial", "double precision", "smallint"] {
            #expect(IDSearch.isNumericType(t), "\(t)")
        }
        for t in ["varchar(50)", "uuid", "char(36)", "nvarchar(100)", "text", "datetime", "bit", "uniqueidentifier"] {
            #expect(!IDSearch.isNumericType(t), "\(t)")
        }
    }

    @Test func sqlPerDialect() {
        #expect(IDSearch.sql(table: "ui_orders", column: "id", values: ["1", "2"], numeric: true, dialect: MySQLDialect())
            == "SELECT * FROM `ui_orders` WHERE `id` IN (1, 2)")
        #expect(IDSearch.sql(table: "orders", column: "code", values: ["A-77", "O'B"], numeric: false, dialect: MySQLDialect())
            == "SELECT * FROM `orders` WHERE `code` IN ('A-77', 'O''B')")
        #expect(IDSearch.sql(table: "ui_orders", column: "id", values: ["1", "-2"], numeric: true, dialect: PostgresDialect())
            == #"SELECT * FROM "ui_orders" WHERE "id" IN (1, -2)"#)
        #expect(IDSearch.sql(table: "orders", column: "code", values: ["A-77"], numeric: false, dialect: PostgresDialect())
            == #"SELECT * FROM "orders" WHERE "code" IN ('A-77')"#)
        #expect(IDSearch.sql(table: "sales.orders", column: "id", values: ["10"], numeric: true, dialect: MSSQLDialect())
            == "SELECT * FROM [sales].[orders] WHERE [id] IN (10)")
        #expect(IDSearch.sql(table: "orders", column: "code", values: ["A-77", "가"], numeric: false, dialect: MSSQLDialect())
            == "SELECT * FROM [orders] WHERE [code] IN (N'A-77', N'가')")
        // 숫자 컬럼이어도 숫자가 아닌 값은 인용
        #expect(IDSearch.sql(table: "t", column: "id", values: ["1", "x"], numeric: true, dialect: PostgresDialect())
            == #"SELECT * FROM "t" WHERE "id" IN (1, 'x')"#)
    }

    @Test func titleAndRowLimit() {
        #expect(IDSearch.tabTitle(table: "ui_orders", column: "id", count: 3) == "ID: ui_orders.id (3)")
        #expect(IDSearch.rowLimit(current: 500, valueCount: 3) == 500)
        #expect(IDSearch.rowLimit(current: 500, valueCount: 1000) == 1000)
        #expect(IDSearch.rowLimit(current: 100, valueCount: 9000) == 5000)
        #expect(IDSearch.rowLimit(current: 5000, valueCount: 1000) == 5000)
        #expect(IDSearch.rowLimit(current: 0, valueCount: 1000) == 0)
    }

    @Test func missingComparison() {
        let c = IDSearch.compare(requested: ["1023", "007", "2044", "99", "ABC-1", "1.50"],
                                 found: ["1023", "7", nil, "2044", "abc-1", "1.5000"])
        #expect(c.requested == 6)
        #expect(c.found == 5)
        #expect(c.missing == ["99"])
        #expect(IDSearch.normalize("000") == "0")
        #expect(IDSearch.normalize("-007") == "-7")
        #expect(IDSearch.normalize("10.0") == "10")
    }

    @Test func memoryRemembersPerConnectionAndDatabase() throws {
        let p = UUID(), other = UUID()
        var m = IDSearchMemory()
        m.remember(.init(profileID: p, database: "shop", table: "orders", column: "id", updatedAt: Date(timeIntervalSince1970: 100)))
        m.remember(.init(profileID: p, database: "shop", table: "members", column: "member_no", updatedAt: Date(timeIntervalSince1970: 200)))
        m.remember(.init(profileID: other, database: "shop", table: "x", column: "y", updatedAt: Date(timeIntervalSince1970: 300)))
        m.remember(.init(profileID: p, database: "shop", table: "orders", column: "code", updatedAt: Date(timeIntervalSince1970: 150)))
        #expect(m.lastTable(profileID: p, database: "shop") == "members")
        #expect(m.lastTable(profileID: p, database: "other") == nil)
        #expect(m.lastColumn(profileID: p, database: "shop", table: "orders") == "code")
        #expect(m.last.count == 3)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("id-search-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = IDSearchStore(file: file)
        store.save(m)
        #expect(store.load() == m)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let first = try #require((json["last"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["profileID", "database", "table", "column", "updatedAt"])
        #expect(IDSearchStore(file: file.appendingPathExtension("none")).load() == IDSearchMemory())
    }
}
