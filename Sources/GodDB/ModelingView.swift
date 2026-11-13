import AppKit
import GodDBCore
import SwiftUI

/// 모델링 모드: 왼쪽 모델 목록 + 가운데 다이어그램 + 아래 테이블/관계 편집기 (MySQL Workbench 모델과 비슷)
struct ModelingView: View {
    @Environment(AppState.self) private var app
    @State private var listWidth: CGFloat = 220

    var body: some View {
        let modeling = app.modeling
        HStack(spacing: 0) {
            ModelListView()
                .frame(width: listWidth)
            ResizeHandle(axis: .vertical, size: $listWidth, range: 170...360, growsTowardStart: false)
            if let id = modeling.selectedID, let binding = modeling.binding(id) {
                ModelEditorView(model: binding)
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label(tr("모델이 없어요"), systemImage: "square.3.layers.3d")
                } description: {
                    Text(tr("논리명으로 테이블을 설계하고 관계를 이어 다이어그램으로 보고, 물리명을 붙여 SQL 로 뽑을 수 있어요."))
                } actions: {
                    Button(tr("새 모델")) { modeling.create(kind: app.selectedProfile?.kind ?? .mysql) }
                        .buttonStyle(.borderedProminent)
                    Button(tr("현재 DB 에서 리버스 엔지니어링…")) { app.showReverseEngineer = true }
                        .disabled(!app.canReverseEngineer)
                }
            }
        }
        .onAppear { modeling.loadIfNeeded() }
        .sheet(isPresented: Binding(get: { app.showReverseEngineer }, set: { app.showReverseEngineer = $0 })) {
            ReverseEngineerSheet()
        }
    }
}

extension AppState {
    /// 리버스 엔지니어링은 연결된 SQL DB 가 있어야 한다
    var canReverseEngineer: Bool {
        state == .connected && selectedProfile?.kind.isSQL == true && !tables.isEmpty
    }
}

// MARK: - 모델 목록

struct ModelListView: View {
    @Environment(AppState.self) private var app
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var deleting: DataModel?

    var body: some View {
        let modeling = app.modeling
        VStack(spacing: 0) {
            HStack {
                Text(tr("모델")).font(.headline)
                Spacer()
                Menu {
                    Button(tr("새 모델")) { modeling.create(kind: app.selectedProfile?.kind ?? .mysql) }
                    Button(tr("현재 DB 에서 리버스 엔지니어링…")) { app.showReverseEngineer = true }
                        .disabled(!app.canReverseEngineer)
                    Divider()
                    Button(tr("모델 파일 열기…")) { modeling.importFile() }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("새 모델 / 리버스 엔지니어링 / 파일 열기"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            List(selection: Binding(get: { modeling.selectedID }, set: { modeling.selectedID = $0 })) {
                ForEach(modeling.models) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        if renaming == m.id {
                            TextField("", text: $renameText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    let n = renameText.trimmingCharacters(in: .whitespaces)
                                    if !n.isEmpty { modeling.edit(m.id, checkpoint: false) { $0.name = n } }
                                    renaming = nil
                                }
                        } else {
                            Text(m.name).lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            KindBadge(kind: m.kind)
                            Text(tr("테이블 %@ · 관계 %@", "\(m.tables.count)", "\(m.relations.count)"))
                            Spacer(minLength: 0)
                            Text(m.updated.formatted(.relative(presentation: .named)))
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(m.id)
                    .contextMenu {
                        Button(tr("이름 바꾸기")) { renameText = m.name; renaming = m.id }
                        Button(tr("복제")) { modeling.duplicate(m.id) }
                        Button(tr("파일로 내보내기…")) { modeling.exportFile(m.id) }
                        Divider()
                        Button(tr("삭제…"), role: .destructive) { deleting = m }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Text(tr("자동 저장돼요. 파일로 내보내면 다른 사람과 공유할 수 있어요."))
                .font(.caption2).foregroundStyle(.secondary)
                .padding(8)
        }
        .alert(tr("이 모델을 삭제할까요?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(tr("삭제"), role: .destructive) { if let d = deleting { modeling.delete(d.id) }; deleting = nil }
            Button(tr("취소"), role: .cancel) { deleting = nil }
        } message: {
            Text(tr("%@ 모델 파일을 지워요. 되돌릴 수 없어요. (필요하면 먼저 파일로 내보내 두세요)", deleting?.name ?? ""))
        }
    }
}

// MARK: - 편집기

enum ModelTool: Equatable {
    case select
    case addTable
    case relation(ModelRelation.Cardinality, identifying: Bool)
}

enum ModelSelection: Equatable {
    case table(UUID)
    case relation(UUID)
}

struct ModelEditorView: View {
    @Environment(AppState.self) private var app
    @Binding var model: DataModel
    @State private var tool: ModelTool = .select
    @State private var pendingParent: UUID?
    @State private var selection: ModelSelection?
    @State private var zoom: CGFloat = 1
    @State private var editorHeight: CGFloat = 280
    @State private var showSQL = false
    @State private var showCompare = false
    @State private var showIssues = false
    @State private var confirmDelete: ModelSelection?
    @AppStorage("GodDB.model.nameMode") private var nameModeRaw = DiagramNameMode.logical.rawValue

    private var nameMode: DiagramNameMode { DiagramNameMode(rawValue: nameModeRaw) ?? .logical }
    private var modeling: ModelingState { app.modeling }

    var body: some View {
        let issues = model.issues()
        VStack(spacing: 0) {
            toolbar(issues)
            Divider()
            GeometryReader { geo in
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        ScrollView([.horizontal, .vertical]) {
                            ModelCanvas(model: $model, nameMode: nameMode, tool: $tool, pendingParent: $pendingParent,
                                        selection: $selection)
                                .scaleEffect(zoom, anchor: .topLeading)
                                .frame(width: ModelCanvas.size(model).width * zoom,
                                       height: ModelCanvas.size(model).height * zoom, alignment: .topLeading)
                        }
                        .background(Color(nsColor: .underPageBackgroundColor))
                        HStack(spacing: 6) {
                            Spacer()
                            Picker("", selection: $nameModeRaw) {
                                ForEach(DiagramNameMode.allCases) { Text($0.title).tag($0.rawValue) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .help(tr("다이어그램에 논리명 / 물리명 / 둘 다"))
                            HStack(spacing: 2) {
                                Button { zoom = max(0.3, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                                Text("\(Int(zoom * 100))%").monospacedDigit().font(.caption).frame(width: 38)
                                Button { zoom = min(2, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                            }
                            .buttonStyle(.hover)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .padding(10)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        if let hint = toolHint {
                            Text(hint)
                                .font(.callout)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                                .padding(.top, 10)
                        }
                    }
                    .onDeleteCommand { if let s = selection { confirmDelete = s } }
                    .onExitCommand { tool = .select; pendingParent = nil }
                    if selection != nil {
                        let maxH = max(160, geo.size.height - 160)
                        ResizeHandle(axis: .horizontal, size: $editorHeight, range: 140...maxH)
                        selectionEditor
                            .frame(height: min(editorHeight, maxH))
                    }
                }
            }
        }
        .onChange(of: tool) { pendingParent = nil }
        .sheet(isPresented: $showSQL) { ModelSQLSheet(model: model) }
        .sheet(isPresented: $showCompare) { ModelCompareSheet(model: model) }
        .alert(tr("삭제할까요?"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button(tr("삭제"), role: .destructive) { if let s = confirmDelete { delete(s) }; confirmDelete = nil }
            Button(tr("취소"), role: .cancel) { confirmDelete = nil }
        } message: {
            Text(tr("되돌리기 버튼으로 다시 살릴 수 있어요."))
        }
    }

    private var toolHint: String? {
        switch tool {
        case .select: return nil
        case .addTable: return tr("빈 곳을 누르면 테이블이 생겨요. (Esc: 선택 도구)")
        case .relation(let c, let identifying):
            let kind = (identifying ? tr("식별 ") : "") + c.title
            if let p = pendingParent, let t = model.table(p) {
                return tr("%@ 관계 · 부모 %@ → 이제 자식(FK 를 받을) 테이블을 누르세요", kind, t.displayName)
            }
            return tr("%@ 관계 · 먼저 부모(참조되는) 테이블을 누르세요", kind)
        }
    }

    // MARK: 도구 막대

    private func toolbar(_ issues: [ModelIssue]) -> some View {
        HStack(spacing: 8) {
            TextField(tr("모델 이름"), text: $model.name)
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(minWidth: 90, maxWidth: 180)
            Picker("", selection: $model.kind) {
                ForEach([DatabaseKind.mysql, .postgres, .mssql], id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help(tr("SQL 을 뽑을 대상 DB"))
            Divider().frame(height: 16)
            toolButton(.select, "cursorarrow", tr("선택 / 이동"))
            toolButton(.addTable, "tablecells.badge.ellipsis", tr("테이블 추가"))
            toolButton(.relation(.oneToMany, identifying: false), "arrow.triangle.branch", tr("1:N 비식별 관계"), label: "1:N")
            toolButton(.relation(.oneToMany, identifying: true), "arrow.triangle.branch", tr("1:N 식별 관계 (자식 PK 에 포함)"), label: "1:N ●")
            toolButton(.relation(.oneToOne, identifying: false), "arrow.left.and.right", tr("1:1 관계"), label: "1:1")
            Divider().frame(height: 16)
            Button { modeling.undoLast(model.id) } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!modeling.canUndo(model.id))
                .help(tr("되돌리기 (테이블·관계 추가/삭제, 이동)"))
            Button {
                modeling.checkpoint(model.id)
                withAnimation(.easeInOut(duration: 0.25)) { autoLayout() }
            } label: { Image(systemName: "rectangle.3.group") }
                .help(tr("자동 정렬"))
            Spacer(minLength: 8)
            Button { showIssues.toggle() } label: {
                let errors = issues.filter { $0.level == .error }.count
                Label(errors > 0 ? "\(errors)" : (issues.isEmpty ? "OK" : "\(issues.count)"),
                      systemImage: errors > 0 ? "xmark.octagon.fill" : (issues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"))
                    .foregroundStyle(errors > 0 ? .red : (issues.isEmpty ? .green : .orange))
            }
            .help(tr("모델 검사 (물리명·타입·기본 키)"))
            .popover(isPresented: $showIssues, arrowEdge: .bottom) { issueList(issues) }
            Button { exportPNG() } label: { Image(systemName: "photo") }
                .help(tr("PNG 저장"))
            Button { showCompare = true } label: { Label(tr("DB와 비교"), systemImage: "arrow.left.arrow.right").fixedSize() }
                .help(tr("연결된 DB 와 비교해서 모델에 맞추는 ALTER SQL 을 만들어요 (Synchronize)"))
                .disabled(app.state != .connected || app.selectedProfile?.kind.isSQL != true)
            Button { showSQL = true } label: { Label(tr("SQL 추출"), systemImage: "doc.text").fixedSize() }
                .buttonStyle(.borderedProminent)
                .help(tr("CREATE TABLE · FK SQL 로 뽑기 (Forward Engineering)"))
        }
        .buttonStyle(.hover)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toolButton(_ t: ModelTool, _ icon: String, _ help: String, label: String? = nil) -> some View {
        Button { tool = (tool == t && t != .select) ? .select : t } label: {
            HStack(spacing: 3) {
                Image(systemName: icon)
                if let label { Text(label).font(.caption.weight(.semibold)).lineLimit(1) }
            }
            .fixedSize()
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(tool == t ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .help(help)
    }

    private func issueList(_ issues: [ModelIssue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("모델 검사")).font(.headline)
            if issues.isEmpty {
                Label(tr("문제가 없어요. SQL 로 뽑을 수 있어요."), systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues) { i in
                        Button {
                            if let t = i.table { selection = .table(t) }
                            showIssues = false
                        } label: {
                            Label(i.message, systemImage: i.level == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                .foregroundStyle(i.level == .error ? .red : .orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.hover)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(12)
        .frame(width: 420)
    }

    // MARK: 아래 편집기

    @ViewBuilder
    private var selectionEditor: some View {
        switch selection {
        case .table(let id):
            if let i = model.tableIndex(id) {
                ModelTableEditor(model: $model, tableIndex: i, selection: $selection,
                                 onDelete: { confirmDelete = .table(id) })
            }
        case .relation(let id):
            if model.relations.contains(where: { $0.id == id }) {
                ModelRelationEditor(model: $model, relationID: id, selection: $selection)
            }
        case nil:
            EmptyView()
        }
    }

    private func delete(_ s: ModelSelection) {
        modeling.checkpoint(model.id)
        switch s {
        case .table(let id): model.removeTable(id)
        case .relation(let id): model.removeRelation(id, dropColumns: true)
        }
        selection = nil
    }

    private func autoLayout() {
        let metas = model.tables.map { t in
            TableMeta(name: t.id.uuidString, columns: t.columns.map { ColumnMeta(name: $0.id.uuidString, columnType: "", nullable: true) })
        }
        let fks = model.relations.map {
            ForeignKeyMeta(name: "r", table: $0.child.uuidString, columns: [], referencedTable: $0.parent.uuidString, referencedColumns: [])
        }
        let frames = DiagramLayout.frames(metas, extra: fks, cardWidth: ModelCanvas.cardWidth)
        for i in model.tables.indices {
            if let f = frames[model.tables[i].id.uuidString] {
                model.tables[i].x = f.minX + 40
                model.tables[i].y = f.minY + 40
            }
        }
    }

    @MainActor
    private func exportPNG() {
        let view = ModelCanvas(model: .constant(model), nameMode: nameMode, tool: .constant(.select),
                               pendingParent: .constant(nil), selection: .constant(nil))
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(app)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(model.name).png"
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}

// MARK: - 캔버스

struct ModelCanvas: View {
    @Environment(AppState.self) private var app
    @Binding var model: DataModel
    let nameMode: DiagramNameMode
    @Binding var tool: ModelTool
    @Binding var pendingParent: UUID?
    @Binding var selection: ModelSelection?
    @State private var dragStart: [UUID: CGPoint] = [:]
    @State private var hovered: UUID?

    static let cardWidth: CGFloat = 260
    static let headerHeight: CGFloat = 34
    static let rowHeight: CGFloat = 20

    static func cardHeight(_ t: ModelTable) -> CGFloat {
        headerHeight + CGFloat(max(t.columns.count, 1)) * rowHeight + 10
    }

    static func size(_ m: DataModel) -> CGSize {
        let maxX = m.tables.map { $0.x + cardWidth }.max() ?? 600
        let maxY = m.tables.map { $0.y + cardHeight($0) }.max() ?? 400
        return CGSize(width: max(1200, maxX + 400), height: max(800, maxY + 300))
    }

    private func frame(_ t: ModelTable) -> CGRect {
        CGRect(x: t.x, y: t.y, width: Self.cardWidth, height: Self.cardHeight(t))
    }

    var body: some View {
        let size = Self.size(model)
        ZStack(alignment: .topLeading) {
            // 배경: 빈 곳 클릭 → 테이블 추가 / 선택 해제
            Color.clear
                .contentShape(Rectangle())
                .frame(width: size.width, height: size.height)
                .onTapGesture(coordinateSpace: .local) { p in
                    if tool == .addTable {
                        app.modeling.checkpoint(model.id)
                        let id = model.addTable(at: CGPoint(x: max(0, p.x - Self.cardWidth / 2), y: max(0, p.y - 20)))
                        selection = .table(id)
                        tool = .select
                    } else {
                        selection = nil
                        pendingParent = nil
                    }
                }
            Canvas { context, _ in
                for r in model.relations { draw(r, in: &context) }
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)

            ForEach(model.relations) { r in
                if let mid = midpoint(r) {
                    Button { selection = .relation(r.id); tool = .select } label: {
                        Text((r.identifying ? "● " : "") + r.cardinality.title)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(selection == .relation(r.id) ? Color.accentColor : Color(nsColor: .textBackgroundColor),
                                        in: Capsule())
                            .foregroundStyle(selection == .relation(r.id) ? Color.white : Color.accentColor)
                            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .position(mid)
                    .help(relationHelp(r))
                }
            }

            ForEach(model.tables) { t in
                let f = frame(t)
                ModelTableCard(table: t, model: model, nameMode: nameMode,
                               selected: selection == .table(t.id) || pendingParent == t.id,
                               highlighted: hovered.map { h in h == t.id || model.relations.contains {
                                   ($0.parent == h && $0.child == t.id) || ($0.child == h && $0.parent == t.id) } } ?? false)
                    .frame(width: f.width)
                    .position(x: f.midX, y: f.minY + f.height / 2)
                    .onHover { hovered = $0 ? t.id : (hovered == t.id ? nil : hovered) }
                    .onTapGesture { tap(t.id) }
                    .gesture(DragGesture(minimumDistance: 3)
                        .onChanged { v in
                            guard tool == .select, let i = model.tableIndex(t.id) else { return }
                            if dragStart[t.id] == nil {
                                app.modeling.checkpoint(model.id)
                                dragStart[t.id] = CGPoint(x: t.x, y: t.y)
                            }
                            let s = dragStart[t.id]!
                            model.tables[i].x = max(0, (s.x + v.translation.width).rounded())
                            model.tables[i].y = max(0, (s.y + v.translation.height).rounded())
                        }
                        .onEnded { _ in dragStart[t.id] = nil })
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func relationHelp(_ r: ModelRelation) -> String {
        let p = model.table(r.parent)?.displayName ?? "?"
        let c = model.table(r.child)?.displayName ?? "?"
        return "\(p) → \(c) · \(r.cardinality.title)" + (r.identifying ? tr(" · 식별") : tr(" · 비식별"))
            + (r.createConstraint ? "" : tr(" · FK 제약 없음"))
    }

    private func tap(_ id: UUID) {
        switch tool {
        case .select, .addTable:
            selection = .table(id)
            tool = .select
        case .relation(let c, let identifying):
            if let parent = pendingParent {
                app.modeling.checkpoint(model.id)
                if let r = model.addRelation(parent: parent, child: id, cardinality: c, identifying: identifying) {
                    selection = .relation(r)
                } else {
                    app.log(.warning, .schema, tr("부모 테이블에 컬럼이 없어서 관계를 만들 수 없어요."))
                }
                pendingParent = nil
                tool = .select
            } else {
                pendingParent = id
            }
        }
    }

    // MARK: 관계 선

    private func rowY(_ t: ModelTable, column: UUID?) -> CGFloat {
        let i = column.flatMap { c in t.columns.firstIndex { $0.id == c } } ?? 0
        return t.y + Self.headerHeight + CGFloat(i) * Self.rowHeight + Self.rowHeight / 2 + 5
    }

    private struct Geometry { let start, c1, c2, end: CGPoint; let out, inward: CGFloat }

    private func geometry(_ r: ModelRelation) -> Geometry? {
        guard let child = model.table(r.child), let parent = model.table(r.parent) else { return nil }
        let cf = frame(child), pf = frame(parent)
        let cy = rowY(child, column: r.pairs.first?.child)
        let py = rowY(parent, column: r.pairs.first?.parent)
        if r.child == r.parent {
            let s = CGPoint(x: cf.maxX, y: cy), e = CGPoint(x: cf.maxX, y: py == cy ? cy + 30 : py)
            return Geometry(start: s, c1: CGPoint(x: s.x + 70, y: s.y), c2: CGPoint(x: e.x + 70, y: e.y), end: e, out: 1, inward: 1)
        }
        let childLeft = cf.midX > pf.midX
        let s = CGPoint(x: childLeft ? cf.minX : cf.maxX, y: cy)
        let e = CGPoint(x: childLeft ? pf.maxX : pf.minX, y: py)
        let bend = max(50, abs(e.x - s.x) * 0.45)
        return Geometry(start: s, c1: CGPoint(x: s.x + (childLeft ? -bend : bend), y: s.y),
                        c2: CGPoint(x: e.x + (childLeft ? bend : -bend), y: e.y), end: e,
                        out: childLeft ? -1 : 1, inward: childLeft ? 1 : -1)
    }

    private func midpoint(_ r: ModelRelation) -> CGPoint? {
        guard let g = geometry(r) else { return nil }
        func b(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat { 0.125 * a + 0.375 * b + 0.375 * c + 0.125 * d }
        return CGPoint(x: b(g.start.x, g.c1.x, g.c2.x, g.end.x), y: b(g.start.y, g.c1.y, g.c2.y, g.end.y))
    }

    private func draw(_ r: ModelRelation, in context: inout GraphicsContext) {
        guard let g = geometry(r) else { return }
        let active = hovered == nil || hovered == r.child || hovered == r.parent || selection == .relation(r.id)
        let color = active ? Color.accentColor : Color.secondary.opacity(0.35)
        var path = Path()
        path.move(to: g.start)
        path.addCurve(to: g.end, control1: g.c1, control2: g.c2)
        let width: CGFloat = selection == .relation(r.id) ? 2.6 : 1.6
        // 식별 관계 = 실선, 비식별 = 점선 (IE 표기)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, dash: r.identifying ? [] : [6, 4]))
        let s = g.start, o = g.out
        var mark = Path()
        if r.cardinality == .oneToMany {
            // 자식 쪽 까마귀발 (여러 개)
            mark.move(to: CGPoint(x: s.x + o * 12, y: s.y)); mark.addLine(to: CGPoint(x: s.x, y: s.y - 7))
            mark.move(to: CGPoint(x: s.x + o * 12, y: s.y)); mark.addLine(to: CGPoint(x: s.x, y: s.y + 7))
            mark.move(to: CGPoint(x: s.x + o * 12, y: s.y)); mark.addLine(to: s)
        } else {
            mark.move(to: CGPoint(x: s.x + o * 8, y: s.y - 7)); mark.addLine(to: CGPoint(x: s.x + o * 8, y: s.y + 7))
        }
        context.stroke(mark, with: .color(color), lineWidth: 1.6)
        if r.optional {
            // 선택(0 허용): 작은 원
            let c = CGPoint(x: s.x + o * 19, y: s.y)
            context.stroke(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(color), lineWidth: 1.4)
        }
        // 부모 쪽: 막대 둘 (반드시 하나)
        let e = g.end, n = -g.inward
        var bars = Path()
        for d in [CGFloat(7), 12] {
            bars.move(to: CGPoint(x: e.x + n * d, y: e.y - 7)); bars.addLine(to: CGPoint(x: e.x + n * d, y: e.y + 7))
        }
        context.stroke(bars, with: .color(color), lineWidth: 1.6)
    }
}

/// 모델 테이블 카드
struct ModelTableCard: View {
    let table: ModelTable
    let model: DataModel
    let nameMode: DiagramNameMode
    var selected = false
    var highlighted = false

    static let colors: [String: Color] = ["blue": .accentColor, "purple": .purple, "green": .green, "orange": .orange,
                                         "red": .red, "teal": .teal, "gray": .gray]

    private func label(logical: String, physical: String) -> (main: String, sub: String?, missing: Bool) {
        switch nameMode {
        case .logical: return (logical.isEmpty ? physical : logical, nil, logical.isEmpty)
        case .physical: return (physical.isEmpty ? logical : physical, nil, physical.isEmpty)
        case .both: return (logical.isEmpty ? physical : logical, physical.isEmpty ? tr("물리명 없음") : physical, physical.isEmpty)
        }
    }

    var body: some View {
        let fkColumns = Set(model.relations.filter { $0.child == table.id }.flatMap { $0.pairs.map(\.child) })
        let header = Self.colors[table.color ?? ""] ?? .accentColor
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "tablecells").font(.caption)
                let n = label(logical: table.logicalName, physical: table.physicalName)
                Text(n.main.isEmpty ? tr("(이름 없음)") : n.main)
                    .font(.system(.callout, design: nameMode == .physical ? .monospaced : .default).weight(.semibold))
                    .italic(n.missing)
                    .lineLimit(1)
                if let sub = n.sub {
                    Text(sub).font(.system(.caption2, design: .monospaced)).opacity(0.85).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: ModelCanvas.headerHeight)
            .background(header)
            VStack(alignment: .leading, spacing: 0) {
                if table.columns.isEmpty {
                    Text(tr("컬럼 없음")).font(.caption).foregroundStyle(.secondary).frame(height: ModelCanvas.rowHeight)
                }
                ForEach(table.columns) { c in
                    HStack(spacing: 5) {
                        Group {
                            if c.primaryKey && fkColumns.contains(c.id) {
                                Image(systemName: "key.fill").foregroundStyle(.orange)
                            } else if c.primaryKey {
                                Image(systemName: "key.fill").foregroundStyle(.yellow)
                            } else if fkColumns.contains(c.id) {
                                Image(systemName: "link").foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: c.notNull ? "diamond.fill" : "diamond").font(.system(size: 6))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption2)
                        .frame(width: 14)
                        let n = label(logical: c.logicalName, physical: c.physicalName)
                        Text(n.main.isEmpty ? tr("(이름 없음)") : n.main)
                            .font(.system(.caption, design: nameMode == .physical ? .monospaced : .default))
                            .foregroundStyle(n.missing ? .secondary : .primary)
                            .italic(n.missing)
                            .lineLimit(1)
                        if let sub = n.sub {
                            Text(sub).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(n.missing ? Color.orange : Color.secondary.opacity(0.7)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if nameMode != .logical {
                            Text(c.dataType).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(height: ModelCanvas.rowHeight)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? Color.orange : (highlighted ? Color.accentColor : Color.primary.opacity(0.15)),
                          lineWidth: selected ? 2.5 : (highlighted ? 2 : 1)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .contentShape(Rectangle())
    }
}
