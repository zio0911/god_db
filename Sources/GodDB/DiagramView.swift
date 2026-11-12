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
    /// 보라색으로 강조할 테이블 (사이드바에서 고른 테이블 / 중심 테이블)
    var highlighted: Set<String> = []
    /// 컬럼 이름으로 추정한 관계 (외래 키 제약이 없는 DB 용)
    var inferred: [ForeignKeyMeta] = []
    /// DB 종류 (AI 분석 SQL 문법용)
    var kind: DatabaseKind = .mysql
}

/// 다이어그램에 보일 이름
enum DiagramNameMode: String, CaseIterable, Identifiable {
    case physical, logical, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .physical: return tr("물리명")
        case .logical: return tr("논리명")
        case .both: return tr("둘 다")
        }
    }
}

/// 코멘트에서 논리명 (첫 줄, 너무 길면 자름)
func logicalName(_ comment: String) -> String? {
    let first = comment.split(whereSeparator: \.isNewline).first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    guard !first.isEmpty else { return nil }
    return first.count > 40 ? String(first.prefix(40)) + "…" : first
}

extension AppState {
    /// 고른 테이블들로 다이어그램: 고른 테이블은 모두(관계가 없어도) 보이고,
    /// 관계(외래 키·추정)가 있으면 이어진 테이블도 함께 그린다. 고른 테이블은 보라색으로 구분.
    func makeDiagram(names: Set<String>) -> UUID? {
        let list = DiagramLayout.withRelated(names, in: tables, extra: DiagramLayout.inferredRelations(tables))
        return makeDiagram(focus: nil, only: list, highlighted: names)
    }

    /// 다이어그램 문서를 만들고 창 id 를 돌려준다. focus 가 있으면 그 테이블과 바로 이어진 테이블만.
    func makeDiagram(focus: String?, only: [TableMeta]? = nil, highlighted: Set<String> = []) -> UUID? {
        guard let profile = selectedProfile, !tables.isEmpty else {
            log(.warning, .schema, tr("먼저 접속을 연결하고 스키마를 불러오세요."))
            return nil
        }
        // 추정 관계는 스키마 전체 기준으로 찾는다 (고른 테이블 밖과의 관계는 그리지 않음)
        let inferredAll = DiagramLayout.inferredRelations(tables)
        var list: [TableMeta]
        let title: String
        if let only {
            list = only
            title = "\(profile.name) / \(currentDatabase) / " + tr("선택 %@개", "\(highlighted.isEmpty ? only.count : highlighted.count)")
        } else if let focus {
            list = DiagramLayout.related(to: focus, in: tables, extra: inferredAll)
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
        let names = Set(list.map(\.name))
        let doc = DiagramDoc(title: title, tables: list, focus: focus,
                             highlighted: focus.map { [$0] } ?? highlighted.intersection(names),
                             inferred: inferredAll.filter { names.contains($0.table) && names.contains($0.referencedTable) },
                             kind: profile.kind)
        diagrams[doc.id] = doc
        let fkCount = list.reduce(0) { $0 + $1.foreignKeys.filter { names.contains($0.referencedTable) }.count }
        log(.info, .schema, tr("ER 다이어그램 · 테이블 %@개 · 관계 %@개 · 추정 %@개", "\(list.count)", "\(fkCount)", "\(doc.inferred.count)"))
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
    @State private var showInferred: Bool
    @State private var viewport: CGSize = .zero
    @State private var didFit = false
    @State private var showAI = false
    @State private var chat = DiagramChat()
    @State private var aiWidth: CGFloat = 380
    @AppStorage("GodDB.diagram.nameMode") private var nameModeRaw = DiagramNameMode.physical.rawValue

    private let margin: CGFloat = 40
    private var nameMode: DiagramNameMode { DiagramNameMode(rawValue: nameModeRaw) ?? .physical }
    private var cardWidth: CGFloat { nameMode == .both ? 320 : DiagramLayout.cardWidth }

    init(doc: DiagramDoc) {
        self.doc = doc
        let mode = DiagramNameMode(rawValue: UserDefaults.standard.string(forKey: "GodDB.diagram.nameMode") ?? "") ?? .physical
        // 처음 그릴 때(그리고 PNG 저장 때)부터 위치가 있어야 한다
        _frames = State(initialValue: DiagramLayout.frames(doc.tables, extra: doc.inferred,
                                                           cardWidth: mode == .both ? 320 : DiagramLayout.cardWidth))
        _showInferred = State(initialValue: true)
    }

    private func relayout() {
        frames = DiagramLayout.frames(doc.tables, extra: showInferred ? doc.inferred : [], cardWidth: cardWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    canvas
                        .scaleEffect(zoom, anchor: .topLeading)
                        .frame(width: contentSize.width * zoom, height: contentSize.height * zoom, alignment: .topLeading)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .onAppear {
                    viewport = geo.size
                    // 처음 열 때 전체가 한 화면에 보이게 (관계 없는 테이블이 아래로 밀려 안 보이는 일 방지)
                    if !didFit { fit(); didFit = true }
                }
                .onChange(of: geo.size) { viewport = geo.size }
            }
            if showAI {
                ResizeHandle(axis: .vertical, size: $aiWidth, range: 300...700)
                DiagramAIPanel(doc: doc, chat: chat)
                    .frame(width: aiWidth)
            }
            }
        }
        .onDisappear { chat.cancel() }
        .frame(minWidth: 700, minHeight: 480)

    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Color.accentColor)
            Text(doc.title).font(.headline).lineLimit(1)
            Text(tr("테이블 %@개 · 관계 %@개", "\(doc.tables.count)", "\(realRelations.count)"))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: Binding(get: { nameMode }, set: { nameModeRaw = $0.rawValue; relayoutAnimated() })) {
                ForEach(DiagramNameMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help(tr("물리명: 실제 테이블·컬럼 이름 / 논리명: 코멘트 (없으면 물리명)"))
            Toggle(isOn: Binding(get: { showInferred }, set: { showInferred = $0; relayoutAnimated() })) {
                Text(tr("관계 추정 %@개", "\(doc.inferred.count)"))
            }
            .toggleStyle(.checkbox)
            .disabled(doc.inferred.isEmpty)
            .help(tr("외래 키 제약이 없어도, 컬럼 이름이 다른 테이블의 기본 키 이름과 같으면 관계로 보고 점선으로 그려요"))
            Divider().frame(height: 16)
            Button { zoom = max(0.3, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .help(tr("축소"))
            Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 44)
            Button { zoom = min(2, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .help(tr("확대"))
            Button { zoom = 1 } label: { Text("100%") }
            Button { withAnimation(.easeInOut(duration: 0.2)) { fit() } } label: {
                Label(tr("화면에 맞추기"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help(tr("모든 테이블이 한 화면에 보이게 확대/축소"))
            Divider().frame(height: 16)
            Button { relayoutAnimated() } label: { Label(tr("자동 정렬"), systemImage: "rectangle.3.group") }
            Button { exportPNG() } label: { Label(tr("PNG 저장"), systemImage: "square.and.arrow.down") }
            Divider().frame(height: 16)
            Button { withAnimation(.easeInOut(duration: 0.2)) { showAI.toggle() } } label: {
                Label(tr("AI 분석"), systemImage: "sparkles")
            }
            .foregroundStyle(showAI ? Color.purple : Color.primary)
            .help(tr("로컬 Ollama 로 관계를 분석하고 질문할 수 있어요"))
        }
        .buttonStyle(.hover)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 모든 테이블이 창 안에 들어오게 배율 조정 (최대 100%, 최소 30%)
    private func fit() {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let z = min(viewport.width / contentSize.width, viewport.height / contentSize.height)
        zoom = max(0.3, min(1, (z * 100).rounded(.down) / 100))
    }

    private func relayoutAnimated() {
        withAnimation(.easeInOut(duration: 0.25)) { relayout() }
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

    /// 진짜 외래 키 (그림 안의 테이블끼리)
    private var realRelations: [ForeignKeyMeta] {
        let names = Set(doc.tables.map(\.name))
        return doc.tables.flatMap(\.foreignKeys).filter { names.contains($0.referencedTable) }
    }

    /// 그릴 관계 (추정 포함 여부에 따라)
    private var relations: [ForeignKeyMeta] {
        realRelations + (showInferred ? doc.inferred : [])
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
                    TableCard(table: table, focus: doc.highlighted.contains(table.name),
                              highlighted: hovered.map { isRelated(table.name, $0) } ?? false,
                              nameMode: nameMode,
                              inferredColumns: Set(doc.inferred.filter { $0.table == table.name && showInferred }
                                                    .flatMap(\.columns).map { $0.lowercased() }))
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
        let inferred = fk.name.hasPrefix("~")
        let width: CGFloat = active && hovered != nil ? 2.5 : 1.6
        context.stroke(path, with: .color(inferred ? color.opacity(0.85) : color),
                       style: StrokeStyle(lineWidth: width, dash: inferred ? [7, 5] : []))
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
    var nameMode: DiagramNameMode = .physical
    var inferredColumns: Set<String> = []

    /// 모드에 맞는 이름 (논리명이 없으면 물리명)
    private func label(_ physical: String, _ comment: String) -> (main: String, sub: String?, missing: Bool) {
        let logical = logicalName(comment)
        switch nameMode {
        case .physical: return (physical, nil, false)
        case .logical: return (logical ?? physical, nil, logical == nil)
        case .both: return (logical ?? physical, logical == nil ? nil : physical, logical == nil)
        }
    }

    var body: some View {
        let fkColumns = Set(table.foreignKeys.flatMap(\.columns).map { $0.lowercased() })
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "tablecells").font(.caption)
                let t = label(table.name, table.comment)
                Text(t.main).font(.system(.callout, design: nameMode == .physical ? .monospaced : .default).weight(.semibold))
                    .lineLimit(1)
                    .italic(t.missing && nameMode != .physical)
                if let sub = t.sub {
                    Text(sub).font(.system(.caption2, design: .monospaced)).opacity(0.8).lineLimit(1)
                }
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
                            } else if inferredColumns.contains(c.name.lowercased()) {
                                Image(systemName: "link").foregroundStyle(Color.accentColor.opacity(0.5))
                            } else {
                                Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption2)
                        .frame(width: 14)
                        let n = label(c.name, c.comment)
                        Text(n.main).font(.system(.caption, design: nameMode == .physical ? .monospaced : .default))
                            .lineLimit(1)
                            .foregroundStyle(n.missing && nameMode != .physical ? .secondary : .primary)
                        if let sub = n.sub {
                            Text(sub).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                        }
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

/// 개발용 샘플 다이어그램 (화면 확인). 외래 키 제약 없이 코멘트만 있는 테이블 → 관계 추정 + 논리명
enum DiagramSample {
    @MainActor
    static func render(to path: String, mode: String = "physical") {
        if mode == "ai-answer" {
            // AI 답변 마크다운 표시 확인용
            let sample = "### 1. 스키마 용도\n- **업무 도메인**: 회원 기반 주문 관리\n- 핵심 테이블: `member`, `orders`\n\n---\n\n### 2. 관계\n- `member` → `orders` (1:N)\n  - 정의된 FK\n\n### 5. 대표 JOIN\n```sql\nSELECT o.*, m.name\nFROM orders o\nJOIN member m ON o.member_id = m.member_id;\n```\n끝."
            let view = MarkdownBlocks(text: sample).padding(8)
                .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 360).padding(10).background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            return
        }
        UserDefaults.standard.set(mode.hasPrefix("selection") ? "physical" : mode, forKey: "GodDB.diagram.nameMode")
        func col(_ n: String, _ t: String, _ c: String, pk: Bool = false) -> ColumnMeta {
            ColumnMeta(name: n, columnType: t, nullable: !pk, columnKey: pk ? "PRI" : "", comment: c)
        }
        func table(_ n: String, _ c: String, _ cols: [ColumnMeta]) -> TableMeta {
            TableMeta(name: n, comment: c, columns: cols,
                      indexes: [IndexMeta(name: "PRIMARY", unique: true, columns: [cols[0].name])])
        }
        let tables = [
            table("tb_member", "회원", [col("member_id", "bigint", "회원 ID", pk: true), col("email", "varchar(100)", "이메일"),
                                        col("status", "char(1)", "상태"), col("reg_dt", "datetime", "가입일시")]),
            table("tb_order", "주문", [col("order_id", "bigint", "주문 ID", pk: true), col("member_id", "bigint", "회원 ID"),
                                       col("total", "decimal(12,2)", "결제 금액"), col("ordered_at", "datetime", "")]),
            table("tb_order_item", "주문 상품", [col("item_id", "bigint", "주문상품 ID", pk: true), col("order_id", "bigint", "주문 ID"),
                                               col("product_id", "bigint", "상품 ID"), col("qty", "int", "수량")]),
            table("tb_product", "상품", [col("product_id", "bigint", "상품 ID", pk: true), col("name", "varchar(200)", "상품명"),
                                         col("price", "decimal(12,2)", "판매가")]),
            table("tb_point_hist", "", [col("hist_id", "bigint", "", pk: true), col("member_id", "bigint", "회원 ID"), col("point", "int", "포인트")]),
        ]
        let inferred = DiagramLayout.inferredRelations(tables)
        // "selection" 모드: tb_order_item 과 tb_notice 를 고른 것처럼 (관계 있는 테이블은 함께, 없는 건 따로)
        // "selection10" 모드: 관계 있는 3개 + 단독 7개, 10개를 고른 것처럼
        let loners = ["tb_notice", "tb_banner", "tb_faq", "tb_code", "tb_config", "tb_popup", "tb_access_log"].map { n in
            table(n, "", [col(n.replacingOccurrences(of: "tb_", with: "") + "_no", "int", "", pk: true), col("title", "varchar(200)", "제목")])
        }
        let all = tables + loners
        let picked: Set<String> = mode == "selection10"
            ? Set(["tb_member", "tb_order", "tb_order_item"] + loners.map(\.name))
            : ["tb_order_item", "tb_notice"]
        let selecting = mode.hasPrefix("selection")
        let docTables = selecting ? DiagramLayout.withRelated(picked, in: all, extra: DiagramLayout.inferredRelations(all)) : tables
        let names = Set(docTables.map(\.name))
        let doc = DiagramDoc(title: "sample / shop", tables: docTables, focus: nil,
                             highlighted: selecting ? picked : [],
                             inferred: (selecting ? DiagramLayout.inferredRelations(all) : inferred)
                                .filter { names.contains($0.table) && names.contains($0.referencedTable) })
        let view = DiagramView(doc: doc).canvas
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
