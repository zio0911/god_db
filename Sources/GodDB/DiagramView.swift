import AppKit
import GodDBCore
import SwiftUI

/// 다이어그램 창 하나의 내용 (열 때의 스키마 스냅샷)
struct DiagramDoc: Identifiable {
    let id = UUID()
    let title: String
    let tables: [TableMeta]
    /// 중심 테이블 (테이블에서 열었을 때)
    let focus: String?
}

extension AppState {
    /// 다이어그램 문서를 만들고 창 id 를 돌려준다. focus 가 있으면 그 테이블과 바로 이어진 테이블만.
    func makeDiagram(focus: String?) -> UUID? {
        guard let profile = selectedProfile, !tables.isEmpty else {
            log(.warning, .schema, tr("먼저 접속을 연결하고 스키마를 불러오세요."))
            return nil
        }
        var list: [TableMeta]
        let title: String
        if let focus {
            list = DiagramLayout.related(to: focus, in: tables)
            title = "\(profile.name) / \(currentDatabase) / \(focus)"
        } else {
            list = tables
            title = "\(profile.name) / \(currentDatabase)"
        }
        let limit = 200
        if list.count > limit {
            log(.warning, .schema, tr("테이블이 %@개라 앞의 %@개만 그려요.", "\(list.count)", "\(limit)"))
            list = Array(list.prefix(limit))
        }
        let doc = DiagramDoc(title: title, tables: list, focus: focus)
        diagrams[doc.id] = doc
        let fkCount = list.reduce(0) { $0 + $1.foreignKeys.count }
        log(.info, .schema, tr("ER 다이어그램 · 테이블 %@개 · 관계 %@개", "\(list.count)", "\(fkCount)"))
        return doc.id
    }
}

/// ER 다이어그램 창
struct DiagramWindow: View {
    @Environment(AppState.self) private var app
    let id: UUID?

    var body: some View {
        if let id, let doc = app.diagrams[id] {
            DiagramView(doc: doc)
                .navigationTitle(tr("ER 다이어그램 · %@", doc.title))
        } else {
            ContentUnavailableView(tr("다이어그램을 찾을 수 없어요"), systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text(tr("사이드바에서 테이블을 우클릭하고 '다이어그램 보기'를 눌러 주세요.")))
        }
    }
}

struct DiagramView: View {
    let doc: DiagramDoc
    @State private var frames: [String: CGRect]
    @State private var zoom: CGFloat = 1
    @State private var dragStart: [String: CGPoint] = [:]
    @State private var hovered: String?

    private let margin: CGFloat = 40

    init(doc: DiagramDoc) {
        self.doc = doc
        // 처음 그릴 때(그리고 PNG 저장 때)부터 위치가 있어야 한다
        _frames = State(initialValue: DiagramLayout.frames(doc.tables))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                canvas
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: contentSize.width * zoom, height: contentSize.height * zoom, alignment: .topLeading)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(minWidth: 700, minHeight: 480)

    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Color.accentColor)
            Text(doc.title).font(.headline).lineLimit(1)
            Text(tr("테이블 %@개 · 관계 %@개", "\(doc.tables.count)", "\(relations.count)"))
                .foregroundStyle(.secondary)
            Spacer()
            Button { zoom = max(0.3, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .help(tr("축소"))
            Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 44)
            Button { zoom = min(2, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .help(tr("확대"))
            Button { zoom = 1 } label: { Text("100%") }
            Divider().frame(height: 16)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { frames = DiagramLayout.frames(doc.tables) }
            } label: { Label(tr("자동 정렬"), systemImage: "rectangle.3.group") }
            Button { exportPNG() } label: { Label(tr("PNG 저장"), systemImage: "square.and.arrow.down") }
        }
        .buttonStyle(.hover)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 그림

    private var contentSize: CGSize {
        let maxX = frames.values.map(\.maxX).max() ?? 600
        let maxY = frames.values.map(\.maxY).max() ?? 400
        return CGSize(width: maxX + margin * 2, height: maxY + margin * 2)
    }

    /// 화면 좌표 (여백 포함)
    private func frame(_ name: String) -> CGRect? {
        frames[name].map { $0.offsetBy(dx: margin, dy: margin) }
    }

    private var relations: [ForeignKeyMeta] {
        let names = Set(doc.tables.map(\.name))
        return doc.tables.flatMap(\.foreignKeys).filter { names.contains($0.referencedTable) }
    }

    @ViewBuilder
    var canvas: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for fk in relations { drawRelation(fk, in: &context) }
            }
            .frame(width: contentSize.width, height: contentSize.height)

            ForEach(doc.tables) { table in
                if let f = frame(table.name) {
                    TableCard(table: table, focus: table.name == doc.focus,
                              highlighted: hovered.map { isRelated(table.name, $0) } ?? false)
                        .frame(width: f.width)
                        .position(x: f.midX, y: f.minY + DiagramLayout.cardHeight(table) / 2)
                        .onHover { hovered = $0 ? table.name : (hovered == table.name ? nil : hovered) }
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                let start = dragStart[table.name] ?? frames[table.name]!.origin
                                if dragStart[table.name] == nil { dragStart[table.name] = start }
                                frames[table.name]!.origin = CGPoint(x: max(0, start.x + v.translation.width),
                                                                     y: max(0, start.y + v.translation.height))
                            }
                            .onEnded { _ in dragStart[table.name] = nil })
                }
            }
        }
        .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
    }

    private func isRelated(_ a: String, _ b: String) -> Bool {
        a == b || relations.contains { ($0.table == a && $0.referencedTable == b) || ($0.table == b && $0.referencedTable == a) }
    }

    /// 컬럼 행의 세로 위치
    private func rowY(_ table: String, column: String) -> CGFloat? {
        guard let t = doc.tables.first(where: { $0.name == table }), let f = frame(table) else { return nil }
        let index = t.columns.firstIndex { $0.name.lowercased() == column.lowercased() } ?? 0
        let shown = min(index, DiagramLayout.maxRows - 1)
        return f.minY + DiagramLayout.headerHeight + CGFloat(shown) * DiagramLayout.rowHeight + DiagramLayout.rowHeight / 2 + 4
    }

    private func drawRelation(_ fk: ForeignKeyMeta, in context: inout GraphicsContext) {
        guard let child = frame(fk.table), let parent = frame(fk.referencedTable),
              let cy = rowY(fk.table, column: fk.columns.first ?? ""),
              let py = rowY(fk.referencedTable, column: fk.referencedColumns.first ?? "") else { return }
        let active = hovered == nil || hovered == fk.table || hovered == fk.referencedTable
        let color = active ? Color.accentColor : Color.secondary.opacity(0.35)
        var path = Path()
        let start: CGPoint, end: CGPoint, out: CGFloat
        if fk.table == fk.referencedTable {
            // 자기 참조: 오른쪽으로 고리
            start = CGPoint(x: child.maxX, y: cy); end = CGPoint(x: child.maxX, y: py)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x + 70, y: start.y), control2: CGPoint(x: end.x + 70, y: end.y))
            out = 1
        } else {
            let childLeft = child.midX > parent.midX
            start = CGPoint(x: childLeft ? child.minX : child.maxX, y: cy)
            end = CGPoint(x: childLeft ? parent.maxX : parent.minX, y: py)
            let bend = max(50, abs(end.x - start.x) * 0.45)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x + (childLeft ? -bend : bend), y: start.y),
                          control2: CGPoint(x: end.x + (childLeft ? bend : -bend), y: end.y))
            out = childLeft ? -1 : 1
        }
        context.stroke(path, with: .color(color), lineWidth: active && hovered != nil ? 2.5 : 1.6)
        // 자식 쪽: 까마귀발(여러 개), 부모 쪽: 막대(하나)
        var crow = Path()
        crow.move(to: CGPoint(x: start.x + out * 12, y: start.y)); crow.addLine(to: CGPoint(x: start.x, y: start.y - 7))
        crow.move(to: CGPoint(x: start.x + out * 12, y: start.y)); crow.addLine(to: CGPoint(x: start.x, y: start.y + 7))
        crow.move(to: CGPoint(x: start.x + out * 12, y: start.y)); crow.addLine(to: start)
        context.stroke(crow, with: .color(color), lineWidth: 1.6)
        let inward: CGFloat = fk.table == fk.referencedTable ? 1 : (child.midX > parent.midX ? 1 : -1)
        var bar = Path()
        bar.move(to: CGPoint(x: end.x + inward * 8, y: end.y - 7)); bar.addLine(to: CGPoint(x: end.x + inward * 8, y: end.y + 7))
        context.stroke(bar, with: .color(color), lineWidth: 2)
    }

    // MARK: - PNG 저장

    @MainActor
    private func exportPNG() {
        let renderer = ImageRenderer(content: canvas.background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "ERD_\(doc.focus ?? "schema").png"
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }
}

/// 테이블 카드: 이름 + 컬럼 (🔑 기본 키, 🔗 외래 키, 타입)
struct TableCard: View {
    let table: TableMeta
    var focus = false
    var highlighted = false

    var body: some View {
        let fkColumns = Set(table.foreignKeys.flatMap(\.columns).map { $0.lowercased() })
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "tablecells").font(.caption)
                Text(table.name).font(.system(.callout, design: .monospaced).weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: DiagramLayout.headerHeight)
            .background(focus ? Color.purple : Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(table.columns.prefix(DiagramLayout.maxRows)) { c in
                    HStack(spacing: 5) {
                        Group {
                            if c.isPrimaryKey {
                                Image(systemName: "key.fill").foregroundStyle(.yellow)
                            } else if fkColumns.contains(c.name.lowercased()) {
                                Image(systemName: "link").foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption2)
                        .frame(width: 14)
                        Text(c.name).font(.system(.caption, design: .monospaced)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(c.columnType).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(height: DiagramLayout.rowHeight)
                }
                if table.columns.count > DiagramLayout.maxRows {
                    Text(tr("… 컬럼 %@개 더", "\(table.columns.count - DiagramLayout.maxRows)"))
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(height: DiagramLayout.rowHeight)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: highlighted ? 2 : 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .help(table.comment.isEmpty ? table.name : table.comment)
    }
}

/// 개발용 샘플 다이어그램 (화면 확인)
enum DiagramSample {
    @MainActor
    static func render(to path: String) {
        func col(_ n: String, _ t: String, pk: Bool = false) -> ColumnMeta {
            ColumnMeta(name: n, columnType: t, nullable: !pk, columnKey: pk ? "PRI" : "")
        }
        func fk(_ table: String, _ c: String, _ ref: String, _ rc: String) -> ForeignKeyMeta {
            ForeignKeyMeta(name: "fk_\(table)_\(ref)", table: table, columns: [c], referencedTable: ref, referencedColumns: [rc])
        }
        let tables = [
            TableMeta(name: "tb_member", columns: [col("member_id", "bigint", pk: true), col("email", "varchar(100)"), col("status", "char(1)"), col("reg_dt", "datetime")]),
            TableMeta(name: "tb_order", columns: [col("order_id", "bigint", pk: true), col("member_id", "bigint"), col("total", "decimal(12,2)"), col("ordered_at", "datetime")],
                      foreignKeys: [fk("tb_order", "member_id", "tb_member", "member_id")]),
            TableMeta(name: "tb_order_item", columns: [col("item_id", "bigint", pk: true), col("order_id", "bigint"), col("product_id", "bigint"), col("qty", "int")],
                      foreignKeys: [fk("tb_order_item", "order_id", "tb_order", "order_id"), fk("tb_order_item", "product_id", "tb_product", "product_id")]),
            TableMeta(name: "tb_product", columns: [col("product_id", "bigint", pk: true), col("name", "varchar(200)"), col("price", "decimal(12,2)")]),
            TableMeta(name: "tb_point_hist", columns: [col("hist_id", "bigint", pk: true), col("member_id", "bigint"), col("point", "int")],
                      foreignKeys: [fk("tb_point_hist", "member_id", "tb_member", "member_id")]),
            TableMeta(name: "tb_notice", columns: [col("notice_id", "int", pk: true), col("title", "varchar(200)")]),
        ]
        // ImageRenderer 는 ScrollView 안을 그리지 않아서 다이어그램 본문만 그린다
        let view = DiagramView(doc: DiagramDoc(title: "sample / shop", tables: tables, focus: "tb_order")).canvas
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
