import GodDBCore
import SwiftUI

struct QueryWorkspaceView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            TabStrip()
            Divider()
            if let i = app.selectedTabIndex {
                QueryTabView(tab: $app.tabs[i])
                    .id(app.tabs[i].id)
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if app.state == .connected, let name = app.selectedProfile?.name {
            ContentUnavailableView {
                Label(tr("열린 쿼리 탭이 없어요"), systemImage: "terminal")
            } description: {
                Text(tr("%@ / %@ 에서 쿼리를 쓰려면 새 탭을 여세요.", "\(name)", "\(app.currentDatabase)"))
            } actions: {
                Button(tr("새 쿼리 탭 (⌘T)")) { app.addTab() }
            }
        } else {
            ContentUnavailableView(tr("접속을 연결하세요"), systemImage: "cylinder.split.1x2",
                                   description: Text(tr("왼쪽에서 접속을 누르면 연결되고, 그 접속의 쿼리 탭이 열려요.\n여러 접속을 동시에 열어 탭마다 다른 DB 에서 쿼리할 수 있어요.")))
        }
    }
}

/// 쿼리 탭 바. 탭마다 접속 이름 / DB 를 함께 보여준다.
struct TabStrip: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(app.tabs) { tab in
                    TabChip(tab: tab, selected: tab.id == app.selectedTabID)
                }
                Button { app.addTab() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(app.selectedProfile.map { tr("%@ / %@ 에 새 쿼리 탭 (⌘T)", "\($0.name)", "\(app.currentDatabase)") }
                          ?? tr("접속을 먼저 연결하세요"))
                    .disabled(app.state != .connected)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

struct TabChip: View {
    @Environment(AppState.self) private var app
    let tab: QueryTab
    let selected: Bool

    var body: some View {
        let profile = app.profile(tab.profileID)
        let connected = app.connectionState(tab.profileID) == .connected
        HStack(spacing: 6) {
            if tab.running {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(connected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
            }
            if let profile { KindBadge(kind: profile.kind) }
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title).lineLimit(1)
                Text("\(profile?.name ?? tr("삭제된 접속"))\(tab.database.isEmpty ? "" : " / \(tab.database)")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button { app.closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(tr("탭 닫기"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            if selected { Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6) }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.selectTab(tab.id) }
        .help(connected ? "\(profile?.name ?? "") / \(tab.database)" : tr("연결이 끊긴 접속이에요. 왼쪽에서 다시 연결하세요."))
        .contextMenu {
            Button(tr("이 접속에 새 탭")) { app.addTab(for: tab.profileID) }
            Button(tr("탭 닫기")) { app.closeTab(tab.id) }
            Button(tr("다른 탭 모두 닫기")) {
                for other in app.tabs where other.id != tab.id { app.closeTab(other.id) }
            }
        }
    }
}

struct QueryTabView: View {
    @Environment(AppState.self) private var app
    @Binding var tab: QueryTab
    @State private var controller = EditorController()
    @State private var editorHeight: CGFloat = 220
    /// 선택 없이 전체 실행할 때 변경 문이 섞여 있으면 확인을 받는다.
    @State private var pendingScript: [String]?

    var body: some View {
        @Bindable var app = app
        GeometryReader { geo in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    SQLEditorView(text: $tab.text, controller: controller)
                }
                .frame(height: min(editorHeight, max(80, geo.size.height - 140)))

                ResizeHandle(axis: .horizontal, size: $editorHeight, range: 80...max(80, geo.size.height - 140),
                             growsTowardStart: false)

                ResultPane(tab: tab,
                           onSelectResult: { index in app.selectResult(index, in: tab.id) },
                           onPage: { page in Task { await app.loadPage(page, in: tab.id) } },
                           onCount: { Task { await app.countRows(in: tab.id) } },
                           onSort: { column, ascending in Task { await app.sortResult(tab.id, column: column, ascending: ascending) } })
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            controller.schemaProvider = { [app] in (app.tables, app.routines) }
            controller.focus()
        }
        .alert(tr("전체 %@개 문장을 실행할까요?", "\(pendingScript?.count ?? 0)"),
               isPresented: Binding(get: { pendingScript != nil }, set: { if !$0 { pendingScript = nil } })) {
            Button(tr("전체 실행"), role: .destructive) {
                if let script = pendingScript { Task { await app.runScript(script) } }
                pendingScript = nil
            }
            Button(tr("취소"), role: .cancel) { pendingScript = nil }
        } message: {
            let writes = (pendingScript ?? []).filter { !SQLText.isReadOnly($0) }
            Text(tr("선택 영역이 없어서 편집기의 모든 문장을 위에서부터 실행해요.\n변경 문 %@개 포함: ", "\(writes.count)")
                 + writes.prefix(3).map { AppState.oneLine($0, max: 40) }.joined(separator: " / ")
                 + (writes.count > 3 ? " …" : "")
                 + tr("\n\n일부만 실행하려면 그 부분을 선택하고 실행하세요."))
        }
    }

    private var toolbar: some View {
        @Bindable var app = app
        return HStack(spacing: 10) {
            Button {
                run(explain: false)
            } label: {
                Label(tr("실행"), systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(tab.running)
            .help(tr("선택 영역만 실행, 선택이 없으면 전체를 위에서부터 실행 (⌘↩)"))

            Button {
                run(explain: true)
            } label: {
                Label(tr("실행 계획"), systemImage: "point.3.connected.trianglepath.dotted")
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(tab.running)
            .help(tr("EXPLAIN 으로 실행 계획 보기 (⇧⌘↩)"))

            Button {
                guard let sql = controller.sqlToRun() else { return }
                app.startTuning(sql: sql)
            } label: {
                Label(tr("AI 튜닝"), systemImage: "sparkles")
            }
            .tint(.purple)
            .buttonStyle(.bordered)
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(tab.running || app.tuningUnavailableReason != nil)
            .help(app.tuningUnavailableReason ?? tr("로컬 Ollama 로 이 쿼리를 튜닝해요 (⌥⌘T) — 선택 영역 또는 커서가 있는 문장"))

            if tab.source != nil {
                Button {
                    Task { await app.refreshSource(tab.id) }
                } label: {
                    Label(tr("생성문 새로고침"), systemImage: "arrow.clockwise")
                }
                .help(tr("DB 에서 생성문(정의)을 다시 읽어 편집기 내용을 바꿔요"))
            }

            Picker(tr("페이지"), selection: $app.rowLimit) {
                Text("100").tag(100)
                Text("500").tag(500)
                Text("1000").tag(1000)
                Text("5000").tag(5000)
                Text(tr("제한 없음")).tag(0)
            }
            .fixedSize()
            Spacer()
            Text(tr("Tab 자동완성 · ⌘↩ 실행 · ⇧⌘↩ 실행 계획 · ⌘T 새 탭")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func run(explain: Bool) {
        if explain {
            // 실행 계획은 선택 영역 또는 커서가 있는 문장 하나
            guard let sql = controller.sqlToRun() else { return }
            Task { await app.run(sql: sql, explain: true) }
            return
        }
        // 선택 영역이 있으면 그 안의 문장만, 없으면 편집기 전체
        let selected = controller.selectedSQL()
        let source = selected ?? tab.text
        let statements = SQLText.statements(in: source).map(\.sql)
        guard !statements.isEmpty else { return }
        if selected == nil && statements.count > 1 && statements.contains(where: { !SQLText.isReadOnly($0) }) {
            pendingScript = statements
            return
        }
        Task { await app.runScript(statements) }
    }
}

// MARK: - 결과 영역

struct ResultPane: View {
    @Environment(AppState.self) private var app
    let tab: QueryTab
    var onSelectResult: (Int) -> Void = { _ in }
    var onPage: (Int) -> Void = { _ in }
    var onCount: () -> Void = {}
    var onSort: (String, Bool) -> Void = { _, _ in }
    @State private var selection = Set<QueryResult.Row.ID>()
    @State private var detailWidth: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            if !tab.running && tab.results.count > 1 {
                ResultTabsBar(results: tab.results, selected: tab.resultIndex, onSelect: onSelectResult)
                Divider()
            }
            if tab.running {
                ProgressView(tr("실행 중…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = tab.error {
                ScrollView {
                    Text(error)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                // 앞 문장들의 결과가 있으면 위 탭에서 골라 볼 수 있다.
                .frame(maxHeight: tab.results.isEmpty ? .infinity : 160)
                if !tab.results.isEmpty, let result = tab.result {
                    Divider()
                    resultBody(result)
                }
            } else if let result = tab.result {
                if tab.isPlan {
                    PlanWarningsView(result: result, tree: tab.planTree,
                                     tuneDisabledReason: app.tuningUnavailableReason,
                                     onTune: { if let sql = result.sql { app.startTuning(sql: sql) } })
                }
                if result.columns.isEmpty {
                    Text(result.message ?? tr("실행 완료"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let target = app.editTarget(for: tab)
                    if let target {
                        EditBar(tab: tab, target: target, selection: $selection)
                        Divider()
                    }
                    let rows = tab.edits.displayRows(result)
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            ResultGrid(result: result, rows: rows, edits: tab.edits, selection: $selection,
                                       onSort: { column, ascending in onSort(column, ascending) },
                                       editable: { if case .success = target { return true } else { return false } }(),
                                       onAddRow: { if let id = app.addRow(tab.id) { selection = [id] } },
                                       onDeleteRows: { ids in app.toggleDelete(tab.id, rows: ids) })
                            if let row = selectedRow(rows) {
                                ResizeHandle(axis: .vertical, size: $detailWidth,
                                             range: 240...max(240, geo.size.width - 200))
                                RowDetailView(result: result, row: row,
                                              rowNumber: row.id >= newRowBase ? nil : result.rowOffset + row.id + 1,
                                              editor: rowEditor(target)) { selection = [] }
                                    .frame(width: min(detailWidth, max(240, geo.size.width - 200)))
                            }
                        }
                    }
                }
                Divider()
                StatusBar(result: result, selectedCount: selection.count, loading: tab.pageLoading || !tab.edits.isEmpty,
                          exportProgress: tab.exportProgress,
                          onPage: onPage, onCount: onCount, onExport: { app.exportResult(tab.id) },
                          onCancelExport: { app.cancelExport(tab.id) })
            } else {
                Text(tr("쿼리를 실행하면 결과가 여기 나와요."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: tab.result?.id) {
            // 결과가 1행이면 (SHOW CREATE 등) 바로 상세를 연다.
            if let r = tab.result, r.rows.count == 1 { selection = [r.rows[0].id] } else { selection = [] }
        }
        .onAppear {
            if let r = tab.result, r.rows.count == 1 { selection = [r.rows[0].id] }
        }
    }

    private func selectedRow(_ rows: [QueryResult.Row]) -> QueryResult.Row? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return rows.first { $0.id == id }
    }

    private func rowEditor(_ target: Result<EditTarget, Error>?) -> RowEditor? {
        guard case .success(let t) = target, let id = selection.first else { return nil }
        let tabID = tab.id
        return RowEditor(target: t, edits: tab.edits,
                         set: { col, value in app.setCell(tabID, row: id, column: col, value: value) },
                         resetToDefault: { col in app.resetInsertedCell(tabID, row: id, column: col) })
    }
}

extension ResultPane {
    /// 오류와 함께 보여줄 때 쓰는 간단한 결과 본문
    @ViewBuilder
    func resultBody(_ result: QueryResult) -> some View {
        if result.columns.isEmpty {
            Text(result.message ?? tr("실행 완료"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ResultGrid(result: result, rows: result.rows, edits: PendingEdits(), selection: $selection)
        }
    }
}

/// 여러 문장을 실행했을 때 문장별 결과 탭
struct ResultTabsBar: View {
    let results: [QueryResult]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(results.enumerated()), id: \.offset) { index, r in
                    let summary = r.columns.isEmpty ? (r.message ?? tr("완료")) : tr("%@행", "\(r.rows.count)")
                    Button {
                        onSelect(index)
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(index + 1)").font(.caption.weight(.semibold))
                            Text(SQLText.firstKeyword(r.sql ?? "")).font(.caption)
                            Text(summary).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(index == selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.hover)
                    .help(r.sql ?? "")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

/// 헤더 정렬용 비교자 (실제 정렬은 쿼리를 다시 실행해서 한다)
struct ColumnSortComparator: SortComparator, Hashable {
    let column: Int
    var order: SortOrder = .forward

    func compare(_ lhs: QueryResult.Row, _ rhs: QueryResult.Row) -> ComparisonResult {
        let r = ResultSorting.compare(lhs.values[column], rhs.values[column])
        return order == .forward ? r : (r == .orderedAscending ? .orderedDescending : r == .orderedDescending ? .orderedAscending : r)
    }
}

struct ResultGrid: View {
    let result: QueryResult
    /// 편집이 반영된 행 (기존 + 새 행)
    var rows: [QueryResult.Row]
    var edits: PendingEdits
    @Binding var selection: Set<QueryResult.Row.ID>
    /// 헤더 클릭 정렬 (컬럼 이름, 오름차순 여부)
    var onSort: ((String, Bool) -> Void)?
    /// 편집 가능한 결과면 우클릭 메뉴에 편집 항목을 보여준다
    var editable = false
    var onAddRow: (() -> Void)?
    var onDeleteRows: ((Set<Int>) -> Void)?
    @State private var sortOrder: [ColumnSortComparator] = []
    @State private var hoveredRow: Int?

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumnForEach(result.columns) { column in
                TableColumn(column.name, sortUsing: ColumnSortComparator(column: column.id)) { (row: QueryResult.Row) in
                    cell(row, column)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(hoveredRow == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        .onHover { inside in
                            if inside { hoveredRow = row.id } else if hoveredRow == row.id { hoveredRow = nil }
                        }
                }
                .width(min: 50, ideal: 140)
            }
        }
        .onAppear { syncSortOrder() }
        .onChange(of: result.id) { syncSortOrder() }
        .onChange(of: sortOrder) {
            guard let first = sortOrder.first, result.columns.indices.contains(first.column) else { return }
            let sort = ResultSort(column: result.columns[first.column].name, ascending: first.order == .forward)
            if sort != result.activeSort { onSort?(sort.column, sort.ascending) }
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: QueryResult.Row.ID.self) { ids in
            if editable {
                Button(tr("이 행 편집")) { selection = ids }
                    .disabled(ids.count != 1)
                Button(tr("행 추가")) { onAddRow?() }
                Button(edits.deletes.isSuperset(of: ids.filter { $0 < newRowBase }) && !ids.isEmpty
                       ? tr("삭제 표시 해제") : tr("선택 행 삭제")) { onDeleteRows?(ids) }
                    .disabled(ids.isEmpty)
                Divider()
            }
            Button(tr("행 복사 (CSV)")) {
                var copy = result
                copy.rows = rows.filter { ids.contains($0.id) }
                Pasteboard.copy(copy.csv())
            }
            .disabled(ids.isEmpty)
        } primaryAction: { ids in
            // 더블클릭: 그 행을 골라 오른쪽 상세(편집 가능하면 편집) 패널을 연다
            selection = ids
        }
    }

    /// 헤더 화살표를 결과의 실제 정렬과 맞춘다
    private func syncSortOrder() {
        guard let s = result.activeSort, let i = result.columns.firstIndex(where: { $0.name == s.column }) else {
            if !sortOrder.isEmpty { sortOrder = [] }
            return
        }
        let wanted = [ColumnSortComparator(column: i, order: s.ascending ? .forward : .reverse)]
        if sortOrder != wanted { sortOrder = wanted }
    }

    @ViewBuilder
    private func cell(_ row: QueryResult.Row, _ column: QueryResult.Column) -> some View {
        let state = edits.state(row: row.id, column: column.id)
        let value = row.values[column.id]
        Group {
            if state == .insertedDefault {
                Text(tr("(기본값)")).foregroundStyle(.tertiary)
            } else if let value {
                Text(Self.preview(value))
            } else {
                Text("NULL").foregroundStyle(state == .normal ? .tertiary : .secondary)
            }
        }
        .font(.system(.callout, design: .monospaced).weight(state == .modified ? .semibold : .regular))
        .lineLimit(1)
        .foregroundStyle(state == .modified ? .orange : state == .inserted ? .green : state == .deleted ? .red : .primary)
        .strikethrough(state == .deleted, color: .red)
    }

    /// 한 줄 미리보기 (줄바꿈은 ⏎ 로 표시)
    static func preview(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
    }
}

/// 선택한 행의 모든 컬럼 값을 전체 텍스트로 보여준다. 편집 가능한 결과면 값을 고칠 수 있다.
struct RowDetailView: View {
    let result: QueryResult
    let row: QueryResult.Row
    /// 새 행이면 nil
    var rowNumber: Int?
    var editor: RowEditor?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editor == nil ? tr("행 상세") : tr("행 편집")).font(.headline)
                Text(rowNumber.map { tr("%@번째 행", "\($0)") } ?? tr("새 행")).foregroundStyle(.secondary)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hover)
                    .help(tr("닫기"))
            }
            .padding(8)
            Divider()
            if editor?.edits.deletes.contains(row.id) == true {
                Label(tr("삭제 표시된 행이에요. 적용하면 삭제돼요."), systemImage: "trash")
                    .font(.caption).foregroundStyle(.red).padding(8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(result.columns) { column in
                        field(column)
                    }
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func field(_ column: QueryResult.Column) -> some View {
        let value = row.values[column.id]
        let editable = editor?.target.columnMap[column.id] != nil && editor?.edits.deletes.contains(row.id) != true
        let state = editor?.edits.state(row: row.id, column: column.id) ?? .normal
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(column.name).font(.caption.weight(.semibold))
                    .foregroundStyle(state == .modified ? .orange : state == .inserted ? .green : .secondary)
                if editor?.target.primaryKey.contains(where: { $0.lowercased() == column.name.lowercased() }) == true {
                    Image(systemName: "key.fill").font(.caption2).foregroundStyle(.yellow)
                }
                Spacer()
                if let value {
                    Text(tr("%@자", "\(value.count)")).font(.caption2).foregroundStyle(.tertiary)
                    Button { Pasteboard.copy(value) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.hover)
                        .help(tr("값 복사"))
                }
            }
            if editable, let editor {
                if state == .insertedDefault {
                    Button(tr("값 입력 (지금은 DB 기본값)")) { editor.set(column.id, "") }
                        .buttonStyle(.hover)
                        .font(.callout)
                } else {
                    TextField("", text: Binding(
                        get: { value ?? "" },
                        set: { editor.set(column.id, $0) }
                    ), axis: .vertical)
                    .font(.system(.callout, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                    .disabled(value == nil)
                    HStack(spacing: 10) {
                        Toggle("NULL", isOn: Binding(
                            get: { value == nil },
                            set: { editor.set(column.id, $0 ? nil : "") }
                        ))
                        .toggleStyle(.checkbox)
                        if row.id >= newRowBase {
                            Button(tr("DB 기본값 사용")) { editor.resetToDefault(column.id) }
                                .buttonStyle(.hover)
                        }
                    }
                    .font(.caption)
                }
            } else {
                Text(value ?? "NULL")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(value == nil ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

/// 실행 계획 주의사항 + 트리 형태 계획
struct PlanWarningsView: View {
    let result: QueryResult
    let tree: String?
    /// AI 튜닝을 못 쓰는 이유 (nil 이면 사용 가능)
    var tuneDisabledReason: String?
    var onTune: (() -> Void)?
    @State private var showTree = false

    var body: some View {
        let warnings = PlanAnalyzer.warnings(result)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text(tr("실행 계획")).font(.headline)
                if warnings.isEmpty {
                    Label(tr("특별한 주의사항 없음"), systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    Label(tr("주의 %@건", "\(warnings.count)"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Spacer()
                if tree != nil {
                    Toggle(tr("트리로 보기"), isOn: $showTree).toggleStyle(.switch).controlSize(.small)
                }
                if let onTune {
                    Button {
                        onTune()
                    } label: {
                        Label(tr("AI 로 튜닝하기"), systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                    .disabled(tuneDisabledReason != nil)
                    .help(tuneDisabledReason ?? tr("이 쿼리와 실행 계획을 로컬 Ollama 에 보내 개선 SQL 과 추천 인덱스를 받아요 (⌥⌘T)"))
                }
            }
            ForEach(warnings, id: \.self) { w in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(w.table).font(.system(.callout, design: .monospaced)).foregroundStyle(.orange)
                    Text(w.message).font(.callout)
                }
            }
            if showTree, let tree {
                ScrollView([.horizontal, .vertical]) {
                    Text(tree)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(.orange.opacity(warnings.isEmpty ? 0 : 0.06))
        Divider()
    }
}

/// 결과 아래 줄: 행 범위, 페이지 이동, 전체 행 수, CSV 복사
struct StatusBar: View {
    let result: QueryResult
    var selectedCount = 0
    /// 페이지 이동/행 수 세기 중 (표는 그대로 두고 여기만 표시)
    var loading = false
    var exportProgress: ExportProgress?
    var onPage: (Int) -> Void = { _ in }
    var onCount: () -> Void = {}
    var onExport: () -> Void = {}
    var onCancelExport: () -> Void = {}

    private var lastPage: Int? {
        guard let total = result.totalCount, result.pageSize > 0 else { return nil }
        return max(0, (total - 1) / result.pageSize)
    }

    var body: some View {
        HStack(spacing: 12) {
            if !result.columns.isEmpty {
                if result.isPaged {
                    pager
                } else {
                    Text(tr("%@행", "\(result.rows.count.formatted())"))
                }
                if selectedCount > 0 { Text(tr("%@행 선택", "\(selectedCount)")) }
            }
            Text(String(format: "%.0fms", result.elapsed * 1000))
            if !result.columns.isEmpty && selectedCount == 0 && !result.isPaged {
                Text(tr("행을 클릭하면 상세가 나와요")).foregroundStyle(.tertiary)
            }
            Spacer()
            if let p = exportProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(p.total.map { tr("%@ 내보내는 중 %@ / %@행", p.format.title, p.written.formatted(), $0.formatted()) }
                         ?? tr("%@ 내보내는 중 %@행", p.format.title, p.written.formatted()))
                        .monospacedDigit()
                    Button(tr("취소")) { onCancelExport() }.buttonStyle(.hover)
                }
            } else if !result.columns.isEmpty {
                Button {
                    onExport()
                } label: {
                    Label(tr("내보내기"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.hover)
                .disabled(loading)
                .help(tr("결과를 파일로 저장: CSV · TSV · Excel · JSON · SQL INSERT · Markdown (보이는 행 또는 쿼리 전체 데이터)"))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var pager: some View {
        let first = result.rowOffset + 1
        let last = result.rowOffset + result.rows.count
        HStack(spacing: 2) {
            Button { onPage(0) } label: { Image(systemName: "backward.end.fill") }
                .disabled(result.page == 0).help(tr("첫 페이지"))
            Button { onPage(result.page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(result.page == 0).help(tr("이전 페이지"))
            ZStack {
                Text(result.rows.isEmpty ? tr("0행") : tr("%@–%@행", "\(first.formatted())", "\(last.formatted())"))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .opacity(loading ? 0.3 : 1)
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 4)
            Button { onPage(result.page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(!result.hasMore).help(tr("다음 페이지"))
            if let lastPage {
                Button { onPage(lastPage) } label: { Image(systemName: "forward.end.fill") }
                    .disabled(result.page >= lastPage).help(tr("마지막 페이지"))
            }
        }
        .buttonStyle(.hover)
        .disabled(loading)
        if let total = result.totalCount {
            Text(tr("/ 전체 %@행 · %@/%@페이지", "\(total.formatted())", "\(result.page + 1)", "\((lastPage ?? 0) + 1)"))
        } else {
            Text(tr("%@페이지", "\(result.page + 1)") + (result.hasMore ? tr(" · 더 있음") : tr(" · 끝")))
            Button(tr("전체 행 수")) { onCount() }
                .buttonStyle(.hover)
                .disabled(loading)
                .help(tr("SELECT COUNT(*) 로 전체 행 수를 세요 (큰 테이블은 오래 걸릴 수 있어요)"))
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
