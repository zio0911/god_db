import Foundation
import Testing
@testable import GodDBCore

@Suite("Diagram layout")
struct DiagramLayoutTests {
    let member = TableMeta(name: "member", columns: [ColumnMeta(name: "id", columnType: "int", nullable: false)])
    var order: TableMeta {
        TableMeta(name: "orders", columns: [ColumnMeta(name: "id", columnType: "int", nullable: false),
                                            ColumnMeta(name: "member_id", columnType: "int", nullable: false)],
                  foreignKeys: [ForeignKeyMeta(name: "fk_member", table: "orders", columns: ["member_id"],
                                               referencedTable: "member", referencedColumns: ["id"])])
    }
    var item: TableMeta {
        TableMeta(name: "order_item", foreignKeys: [ForeignKeyMeta(name: "fk_order", table: "order_item", columns: ["order_id"],
                                                                   referencedTable: "orders", referencedColumns: ["id"])])
    }
    let loose = TableMeta(name: "log")

    @Test func relatedTables() {
        let all = [member, order, item, loose]
        #expect(DiagramLayout.related(to: "orders", in: all).map(\.name) == ["orders", "member", "order_item"])
        #expect(DiagramLayout.related(to: "log", in: all).map(\.name) == ["log"])
    }

    @Test func parentsLeftChildrenRight() {
        let f = DiagramLayout.frames([item, order, member, loose])
        #expect(f["member"]!.minX < f["orders"]!.minX && f["orders"]!.minX < f["order_item"]!.minX)
        #expect(f["log"]!.minY >= max(f["member"]!.maxY, f["orders"]!.maxY))
        // 겹치지 않는다
        let rects = Array(f.values)
        for i in rects.indices { for j in rects.indices where i < j { #expect(!rects[i].intersects(rects[j])) } }
    }

    @Test func attachesMultiColumnKeys() {
        let tables = [TableMeta(name: "a"), TableMeta(name: "b")]
        let out = SchemaBuilder.attachForeignKeys(tables, rows: [["b", "fk_ab", "x1", "a", "y1", "1"], ["b", "fk_ab", "x2", "a", "y2", "2"]])
        #expect(out[1].foreignKeys.first?.columns == ["x1", "x2"])
        #expect(out[1].foreignKeys.first?.referencedColumns == ["y1", "y2"])
    }
}

extension MultiDBChecks {
    /// 세 DB 공통: 외래 키를 읽는다 (여러 컬럼 포함)
    static func foreignKeys(_ s: DBSession, container: String) async throws {
        let d = s.dialect
        _ = try? await s.raw(d.dropTableSQL("tb_fk_child"))
        _ = try? await s.raw(d.dropTableSQL("tb_fk_parent"))
        _ = try await s.raw("CREATE TABLE tb_fk_parent (a int NOT NULL, b int NOT NULL, PRIMARY KEY (a, b))")
        _ = try await s.raw("""
            CREATE TABLE tb_fk_child (id int PRIMARY KEY, pa int NULL, pb int NULL,
              CONSTRAINT fk_child_parent FOREIGN KEY (pa, pb) REFERENCES tb_fk_parent (a, b))
            """)
        let tables = try await s.loadSchema(container)
        let child = try #require(tables.first { $0.name == "tb_fk_child" })
        let fk = try #require(child.foreignKeys.first)
        #expect(fk.name == "fk_child_parent")
        #expect(fk.referencedTable == "tb_fk_parent")
        #expect(fk.columns == ["pa", "pb"] && fk.referencedColumns == ["a", "b"])
        #expect(DiagramLayout.related(to: "tb_fk_parent", in: tables).map(\.name).contains("tb_fk_child"))
        _ = try await s.raw(d.dropTableSQL("tb_fk_child"))
        _ = try await s.raw(d.dropTableSQL("tb_fk_parent"))
    }
}
