import AppKit
import GodDBCore
import SwiftUI

/// 개발용: GodDB --render-modeling-sample <폴더> → 모델링·테이블 수정·AI 패널·접속 그룹 화면 PNG
enum ModelingSample {
    @MainActor
    static func model() -> DataModel {
        var m = DataModel(name: "쇼핑몰 모델", kind: .mysql)
        let member = m.addTable(logicalName: "회원")
        let order = m.addTable(logicalName: "주문")
        let item = m.addTable(logicalName: "주문상품")
        let product = m.addTable(logicalName: "상품")
        func set(_ id: UUID, _ physical: String, _ pk: String, _ cols: [ModelColumn]) {
            let i = m.tableIndex(id)!
            m.tables[i].physicalName = physical
            m.tables[i].columns[0].physicalName = pk
            m.tables[i].columns += cols
        }
        set(member, "tb_member", "id", [ModelColumn(logicalName: "이메일", physicalName: "email", notNull: true, unique: true),
                                         ModelColumn(logicalName: "이름", physicalName: "name", dataType: "varchar(50)", notNull: true),
                                         ModelColumn(logicalName: "가입일시", physicalName: "", dataType: "datetime(3)", notNull: true,
                                                     defaultValue: "CURRENT_TIMESTAMP(3)")])
        set(order, "tb_order", "id", [ModelColumn(logicalName: "주문일시", physicalName: "ordered_at", dataType: "datetime(3)", notNull: true),
                                       ModelColumn(logicalName: "결제금액", physicalName: "total", dataType: "decimal(12,2)", notNull: true)])
        set(product, "tb_product", "id", [ModelColumn(logicalName: "상품명", physicalName: "name", dataType: "varchar(200)", notNull: true),
                                           ModelColumn(logicalName: "판매가", physicalName: "price", dataType: "decimal(12,2)")])
        set(item, "tb_order_item", "id", [ModelColumn(logicalName: "수량", physicalName: "qty", dataType: "int", notNull: true)])
        m.addRelation(parent: member, child: order)
        m.addRelation(parent: order, child: item, identifying: true)
        m.addRelation(parent: product, child: item)
        let pos: [(UUID, Double, Double)] = [(member, 40, 60), (order, 380, 60), (item, 720, 60), (product, 380, 330)]
        for (id, x, y) in pos { let i = m.tableIndex(id)!; m.tables[i].x = x; m.tables[i].y = y }
        m.tables[m.tableIndex(product)!].color = "green"
        return m
    }

    @MainActor
    static func render(dir: String, app: AppState) {
        func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func shot(_ name: String, _ view: some View, size: NSSize) {
            let host = NSHostingView(rootView: view.environment(app).frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            spin(1.0)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
            }
            window.orderOut(nil)
        }
        let m = model()
        app.modeling.useForPreview([m])
        app.mode = .modeling
        for mode in ["logical", "both"] {
            UserDefaults.standard.set(mode, forKey: "GodDB.model.nameMode")
            shot("modeling-\(mode)", ModelingView(), size: NSSize(width: 1300, height: 720))
        }
        if let b = app.modeling.binding(m.id) {
            shot("modeling-table-editor", ModelTableEditor(model: b, tableIndex: 0, selection: .constant(nil), onDelete: {}),
                 size: NSSize(width: 1250, height: 300))
            shot("modeling-relation-editor", ModelRelationEditor(model: b, relationID: m.relations[1].id, selection: .constant(nil)),
                 size: NSSize(width: 1000, height: 280))
            shot("modeling-sql", ModelSQLSheet(model: m), size: NSSize(width: 860, height: 620))
        }
        app.assistant.visible = true
        shot("assistant-modeling", AssistantPanel(), size: NSSize(width: 400, height: 720))
        app.mode = .query
        shot("assistant-query", AssistantPanel(), size: NSSize(width: 400, height: 720))

        let table = TableMeta(name: "external_api_scope", comment: "외부 API 권한 범위",
                              columns: [ColumnMeta(name: "external_scope_id", columnType: "bigint", nullable: false, extra: "auto_increment", columnKey: "PRI", position: 1),
                                        ColumnMeta(name: "external_id", columnType: "bigint", nullable: false, position: 2),
                                        ColumnMeta(name: "scope_code", columnType: "varchar(50)", nullable: false, position: 3),
                                        ColumnMeta(name: "created_at", columnType: "datetime(3)", nullable: false, defaultValue: "CURRENT_TIMESTAMP(3)",
                                                   extra: "DEFAULT_GENERATED", position: 4)],
                              indexes: [IndexMeta(name: "PRIMARY", unique: true, columns: ["external_scope_id"]),
                                        IndexMeta(name: "idx_scope_client", unique: false, columns: ["external_id"])])
        shot("table-editor", TableEditorView(table: table), size: NSSize(width: 1040, height: 740))

        var a = ConnectionProfile(name: "shop-dev"); a.group = "개발"
        var b = ConnectionProfile(kind: .postgres, name: "billing-dev", port: 5432); b.group = "개발"
        var c = ConnectionProfile(name: "shop-prd", readOnly: true); c.group = "운영"
        let d = ConnectionProfile(kind: .redis, name: "local redis", port: 6379)
        app.profiles = [d, a, b, c]
        var sample = QueryResult(columns: ["member_id", "email"], rows: (0..<500).map { [String($0), "user\($0)@sample.com"] }, elapsed: 0.01)
        sample.sql = "SELECT * FROM tb_member"; sample.pageSize = 500; sample.hasMore = true
        let req = ExportRequest(tabID: UUID(), result: sample, kind: .mysql, visibleRows: 500, canFetchAll: true,
                                knownTotal: 12_345, stable: true, sort: nil, defaultTable: "tb_member", baseName: "tb_member")
        shot("export-sheet", ExportSheet(request: req), size: NSSize(width: 540, height: 640))
        let req2 = ExportRequest(tabID: UUID(), result: sample, kind: .mysql, visibleRows: 500, canFetchAll: true,
                                 knownTotal: nil, stable: false, sort: nil, defaultTable: "table", baseName: "query")
        shot("export-sheet-unstable", ExportSheet(request: req2), size: NSSize(width: 540, height: 680))
        shot("sidebar-groups", List { Section(tr("접속")) { ProfileList() } }.listStyle(.sidebar), size: NSSize(width: 300, height: 320))
    }
}
