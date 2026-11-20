import Foundation
import Testing
@testable import GodDBCore

@Suite("TableSpecExport")
struct TableSpecExportTests {
    /// 회원 1 — N 주문 (비식별), 주문 1 — N 주문상품 (식별), 상품 1 — N 주문상품
    static func model(kind: DatabaseKind = .mysql) -> DataModel {
        var m = DataModel(name: "샵", kind: kind)
        let member = m.addTable(logicalName: "회원")
        let order = m.addTable(logicalName: "주문")
        let item = m.addTable(logicalName: "주문상품")
        let product = m.addTable(logicalName: "상품")
        func set(_ id: UUID, _ physical: String, _ cols: [ModelColumn]) {
            let i = m.tableIndex(id)!
            m.tables[i].physicalName = physical
            m.tables[i].columns[0].physicalName = "id"
            m.tables[i].columns += cols
        }
        set(member, "tb_member", [ModelColumn(logicalName: "이메일", physicalName: "email", notNull: true, unique: true, comment: "로그인 ID")])
        set(order, "tb_order", [ModelColumn(logicalName: "금액", physicalName: "total", dataType: "decimal(12,2)", defaultValue: "0")])
        set(item, "tb_order_item", [ModelColumn(logicalName: "수량", physicalName: "qty", dataType: "int", notNull: true)])
        set(product, "tb_product", [ModelColumn(logicalName: "상태", physicalName: "status", dataType: "enum('a','b')")])
        m.tables[m.tableIndex(member)!].comment = "회원 기본 정보"
        m.addRelation(parent: member, child: order)
        m.addRelation(parent: order, child: item, identifying: true)
        m.addRelation(parent: product, child: item)
        let oi = m.tableIndex(item)!
        m.tables[oi].indexes = [ModelIndex(name: "idx_qty", columns: [m.tables[oi].columns.first { $0.physicalName == "qty" }!.id])]
        return m
    }

    static let info = TableSpecInfo(systemName: "샵 시스템", author: "홍길동", date: "2026-11-20")

    @Test func splitsTypeAndLength() {
        #expect(TableSpecExport.splitType("varchar(50)") == ("varchar", "50"))
        #expect(TableSpecExport.splitType("decimal(10,2)") == ("decimal", "10,2"))
        #expect(TableSpecExport.splitType("enum('a','b')") == ("enum", "'a','b'"))
        #expect(TableSpecExport.splitType("bigint") == ("bigint", ""))
        #expect(TableSpecExport.splitType("datetime(3)") == ("datetime", "3"))
        #expect(TableSpecExport.splitType("int(10) unsigned") == ("int unsigned", "10"))
    }

    @Test func keysAndReferencesFromRelations() {
        let m = Self.model()
        let item = m.tables.first { $0.physicalName == "tb_order_item" }!
        let rows = TableSpecExport.columnRows(m, item)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.physical, $0) })
        #expect(byName["id"]?.key == "PK")
        #expect(byName["id"]?.defaultValue == "AUTO_INCREMENT")
        #expect(byName["order_id"]?.key == "PK, FK")              // 식별 관계
        #expect(byName["order_id"]?.references == "tb_order.id")
        #expect(byName["product_id"]?.key == "FK")
        #expect(byName["product_id"]?.references == "tb_product.id")
        #expect(byName["product_id"]?.notNull == "Y")
        #expect(byName["qty"]?.key == "")
        #expect(byName["qty"]?.references == "")
        #expect(rows.map(\.no) == Array(1...rows.count))

        let member = m.tables.first { $0.physicalName == "tb_member" }!
        let email = TableSpecExport.columnRows(m, member).first { $0.physical == "email" }!
        #expect(email.note == "UQ")
        #expect(email.comment == "로그인 ID")
        #expect(email.type == "varchar" && email.length == "100")
        let order = m.tables.first { $0.physicalName == "tb_order" }!
        let total = TableSpecExport.columnRows(m, order).first { $0.physical == "total" }!
        #expect(total.type == "decimal" && total.length == "12,2" && total.defaultValue == "0" && total.notNull == "")
    }

    @Test func indexRowsStartWithPrimaryKey() {
        let m = Self.model()
        let item = m.tables.first { $0.physicalName == "tb_order_item" }!
        let idx = TableSpecExport.indexRows(m, item)
        #expect(idx.first?.name == "PRIMARY")
        #expect(idx.first?.kind == "PK")
        #expect(idx.first?.columns == "id, order_id")
        #expect(idx.contains { $0.name == "idx_qty" && $0.kind == "일반" && $0.columns == "qty" })
        let member = m.tables.first { $0.physicalName == "tb_member" }!
        #expect(TableSpecExport.indexRows(m, member).contains { $0.kind == "유니크" && $0.columns == "email" })

        let pg = Self.model(kind: .postgres)
        let pgItem = pg.tables.first { $0.physicalName == "tb_order_item" }!
        #expect(TableSpecExport.indexRows(pg, pgItem).first?.name == "pk_tb_order_item")
    }

    @Test func relationRows() {
        let m = Self.model()
        let item = m.tables.first { $0.physicalName == "tb_order_item" }!
        let rels = TableSpecExport.relationRows(m, item)
        #expect(rels.count == 2)
        #expect(rels[0].name == "fk_tb_order_item_tb_order")
        #expect(rels[0].mapping == "order_id → tb_order.id")
        #expect(rels[0].relation == "1:N · 식별")
        #expect(rels[1].relation == "1:N · 비식별")
        #expect(rels[0].onDelete == "NO ACTION")
        let member = m.tables.first { $0.physicalName == "tb_member" }!
        #expect(TableSpecExport.relationRows(m, member).isEmpty)
    }

    @Test func sheetNamesAreSanitizedAndUnique() {
        let long = String(repeating: "a", count: 40)
        let names = TableSpecExport.sheetNames(["a/b:c", "tb_x", "TB_X", "목차", "", long, long, "'q'", "x[1]*?"])
        #expect(names[0] == "a_b_c")
        #expect(names[1] == "tb_x")
        #expect(names[2] == "TB_X~2")
        #expect(names[3] == "목차~2")
        #expect(names[4] == "Table")
        #expect(names[5] == String(repeating: "a", count: 31))
        #expect(names[6] == String(repeating: "a", count: 29) + "~2")
        #expect(names[7] == "q")
        #expect(names[8] == "x_1___")
        #expect(names.allSatisfy { $0.count <= 31 })
        #expect(Set(names.map { $0.lowercased() }).count == names.count)
    }

    @Test func workbookIsValidZip() throws {
        let m = Self.model()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-spec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("spec.xlsx")
        try TableSpecExport.data(m, info: Self.info).write(to: url)

        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        test.arguments = ["-tq", url.path]
        test.standardOutput = FileHandle.nullDevice
        try test.run(); test.waitUntilExit()
        #expect(test.terminationStatus == 0)

        let out = dir.appendingPathComponent("x")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", url.path, "-d", out.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("[Content_Types].xml").path))
        let wb = try String(contentsOf: out.appendingPathComponent("xl/workbook.xml"), encoding: .utf8)
        for name in ["목차", "tb_member", "tb_order", "tb_order_item", "tb_product"] { #expect(wb.contains("name=\"\(name)\"")) }
        #expect(wb.components(separatedBy: "<sheet ").count - 1 == 5)
        let types = try String(contentsOf: out.appendingPathComponent("[Content_Types].xml"), encoding: .utf8)
        #expect(types.contains("/xl/worksheets/sheet5.xml"))

        let toc = try String(contentsOf: out.appendingPathComponent("xl/worksheets/sheet1.xml"), encoding: .utf8)
        #expect(toc.contains("테이블 명세서 — 샵 시스템"))
        #expect(toc.contains("테이블 목록 (4개)"))
        #expect(toc.contains("location=\"'tb_member'!A1\""))
        #expect(toc.contains("location=\"'tb_order_item'!A1\""))
        #expect(toc.contains("홍길동") && toc.contains("2026-11-20") && toc.contains("MySQL"))
        #expect(toc.contains("state=\"frozen\""))
        #expect(toc.contains("orientation=\"landscape\"") && toc.contains("fitToWidth=\"1\""))

        let sheet = try String(contentsOf: out.appendingPathComponent("xl/worksheets/sheet2.xml"), encoding: .utf8)
        #expect(sheet.contains("tb_member · 회원"))
        #expect(sheet.contains("location=\"'목차'!A1\""))
        #expect(sheet.contains("<mergeCells"))
        #expect(sheet.contains(">없음<"))                      // 관계 없음
        let styles = try String(contentsOf: out.appendingPathComponent("xl/styles.xml"), encoding: .utf8)
        #expect(styles.contains("맑은 고딕"))
        #expect(styles.contains("FFE6F1FB"))
        #expect(!styles.contains("medium") && !styles.contains("thick"))
    }

    @Test func crcMatchesKnownValue() {
        #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
