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
        // Finder 에서 .sql 파일을 끌어 놓으면 새 탭으로 연다
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ["sql", "txt"].contains(url.pathExtension.lowercased()) else { return }
                    Task { @MainActor in AppState.shared?.openSQLFile(url) }
                }
            }
            return true
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
            if let profile { KindBadge(kind: profile.kind, redshift: profile.redshift) }
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.isDirty ? "● " + tab.title : tab.title).lineLimit(1)
                    .help(tab.fileURL?.path ?? "")
                Text("\(profile?.name ?? tr("삭제된 접속"))\(tab.database.isEmpty ? "" : " / \(tab.database)")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button { app.requestCloseTabs([tab.id]) } label: {
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
        .overlay(alignment: .leading) {
            // 접속 환경 색 띠 (운영 = 빨강)
            if let env = profile?.environment, env != .none {
                RoundedRectangle(cornerRadius: 1.5).fill(env.color).frame(width: 3).padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.selectTab(tab.id) }
        .help(connected ? "\(profile?.name ?? "") / \(tab.database)" : tr("연결이 끊긴 접속이에요. 왼쪽에서 다시 연결하세요."))
        .contextMenu {
            Button(tr("이 접속에 새 탭")) { app.addTab(for: tab.profileID) }
            Button(tr("탭 닫기")) { app.requestCloseTabs([tab.id]) }
            Button(tr("다른 탭 모두 닫기")) {
                app.requestCloseTabs(app.tabs.filter { $0.id != tab.id }.map(\.id))
            }
        }
    }
}

struct QueryTabView: View {
    @Environment(AppState.self) private var app
    @Binding var tab: QueryTab
    @State private var controller = EditorController()
    /// 편집기 높이 (결과 창과의 경계). 조절하면 모든 탭 · 다음 실행에 쓴다
    @AppStorage(Layout.queryEditorHeight) private var storedEditorHeight: Double = 220
    private var editorHeight: Binding<CGFloat> { $storedEditorHeight.cgFloat }
    /// 선택 없이 전체 실행할 때 변경 문이 섞여 있으면 확인을 받는다.
    @State private var pendingRun: RunConfirm?

    var body: some View {
        @Bindable var app = app
        GeometryReader { geo in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let p = app.profile(tab.profileID), p.environment == .production {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(tr("운영 접속 · %@", p.name)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.red)
                    }
                    toolbar
                    Divider()
                    SQLEditorView(text: $tab.text, controller: controller)
                }
                .frame(height: min(editorHeight.wrappedValue, max(80, geo.size.height - 140)))

                ResizeHandle(axis: .horizontal, size: editorHeight, range: 80...max(80, geo.size.height - 140),
                             growsTowardStart: false)

                ResultPane(tab: tab,
                           onSelectResult: { index in app.confirmDiscardingEdits([tab.id]) { app.selectResult(index, in: tab.id) } },
                           onPage: { page in app.confirmDiscardingEdits([tab.id]) { Task { await app.loadPage(page, in: tab.id) } } },
                           onCount: { Task { await app.countRows(in: tab.id) } },
                           onSort: { column, ascending in Task { await app.sortResult(tab.id, column: column, ascending: ascending) } })
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            controller.schemaProvider = { [app] in (app.tables, app.routines) }
            controller.lintContext = { [app, id = tab.id] in app.lintContext(tabID: id) }
            controller.serverChecker = { [app, id = tab.id] sql in await app.serverCheck(sql, tabID: id) }
            controller.focus()
            app.activeEditor = controller
        }
        // 저장 쿼리 [실행]: 넣은 내용을 평소 실행(⌥⌘↩ 와 같은 확인)으로 실행
        .onChange(of: app.runAllRequest, initial: true) { _, request in
            guard request == tab.id else { return }
            app.runAllRequest = nil
            run(explain: false, all: true)
        }
        .alert(pendingRun?.title ?? "", isPresented: Binding(get: { pendingRun != nil }, set: { if !$0 { pendingRun = nil } }),
               presenting: pendingRun) { confirm in
            Button(confirm.wholeScript ? tr("전체 실행") : tr("실행"), role: .destructive) {
                pendingRun = nil
                start(confirm)
            }
            Button(tr("취소"), role: .cancel) { pendingRun = nil }
        } message: { confirm in
            Text(confirm.message)
        }
    }

    private var toolbar: some View {
        AdaptiveBar { compact in toolbarRow(compact: compact) }
    }

    private func toolbarRow(compact: Bool) -> some View {
        @Bindable var app = app
        return HStack(spacing: 10) {
            if tab.running {
                Button {
                    Task { await app.cancelQuery(tab.id) }
                } label: {
                    Label(tr("취소"), systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help(tr("실행 중인 쿼리 멈추기 (⌘.)"))
            } else {
                Button {
                    run(explain: false)
                } label: {
                    Label(tr("실행"), systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help(tr("선택 영역만 실행, 선택이 없으면 커서가 있는 문장(강조된 문장)만 실행 (⌘↩)"))

                Button {
                    run(explain: false, all: true)
                } label: {
                    Label(tr("전체 실행"), systemImage: "forward.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .help(tr("편집기의 모든 문장을 위에서부터 실행 (⌥⌘↩)"))
            }

            Button {
                run(explain: true)
            } label: {
                Label(tr("실행 계획"), systemImage: "point.3.connected.trianglepath.dotted")
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(tab.running)
            .help(tr("EXPLAIN 으로 실행 계획 보기 (⇧⌘↩)"))

            if tab.source != nil {
                Button {
                    Task { await app.refreshSource(tab.id) }
                } label: {
                    Label(tr("생성문 새로고침"), systemImage: "arrow.clockwise")
                }
                .help(tr("DB 에서 생성문(정의)을 다시 읽어 편집기 내용을 바꿔요"))
            }

            Button { app.showHistory = true } label: {
                Label(tr("히스토리"), systemImage: "clock.arrow.circlepath")
            }
            .help(tr("실행한 쿼리 다시 찾기 (⌘Y)"))

            Button { app.openSavedQueries() } label: {
                Label(tr("저장 쿼리"), systemImage: "bookmark")
            }
            .help(tr("저장 쿼리 목록 (⇧⌘K) · 지금 쿼리 저장은 ⌥⌘S"))

            // 좁아져도 선택한 값(500 등)은 항상 보이게: 이름표는 compact 에서 숨기고 선택 상자는 줄이지 않는다
            HStack(spacing: 4) {
                if !compact { Text(tr("페이지")) }
                Picker(tr("페이지"), selection: $app.rowLimit) {
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                    Text("5000").tag(5000)
                    Text(tr("제한 없음")).tag(0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                // 좁을 때 도구 막대에 걸리는 아이콘만 보기(.iconOnly)가 선택한 값 글자까지 숨겨서 되돌린다
                .labelStyle(.titleAndIcon)
                .frame(minWidth: 72)
            }
            .fixedSize()
            .layoutPriority(1)
            .help(tr("한 번에 가져올 행 수"))
            if let p = app.profiles.first(where: { $0.id == tab.profileID }), p.kind != .redis, !p.readOnly,
               app.connections[tab.profileID]?.state == .connected {
                Divider().frame(height: 18)
                TransactionControls(profileID: tab.profileID)
            }
            Spacer(minLength: 0)
            if !compact {
                Text(tr("Tab 자동완성 · ⌘↩ 커서 문장 실행 · ⌥⌘↩ 전체 실행 · ⇧⌘↩ 실행 계획 · ⌘/ 주석 · ⌥⌘L 정렬")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private func run(explain: Bool, all: Bool = false) {
        if explain {
            // 실행 계획은 선택 영역 또는 커서가 있는 문장 하나
            guard let sql = controller.sqlToRun() else { return }
            let confirm = RunConfirm(statements: [sql], explain: true, discardedEdits: tab.edits.count)
            if confirm.needsConfirm { pendingRun = confirm } else { start(confirm) }
            return
        }
        // 전체 실행: 편집기의 모든 문장. 그 외: 선택 영역이 있으면 그 안의 문장들, 없으면 커서가 있는 문장 하나
        let selected = all ? nil : controller.selectedSQL()
        let statements: [String]
        if all {
            statements = SQLText.statements(in: tab.text).map(\.sql)
        } else if let selected {
            statements = SQLText.statements(in: selected).map(\.sql)
        } else {
            statements = controller.sqlToRun().map { SQLText.statements(in: $0).map(\.sql) } ?? []
        }
        guard !statements.isEmpty else { return }
        let kind = app.profile(tab.profileID)?.kind ?? .mysql
        let confirm = RunConfirm(statements: statements,
                                 wholeScript: all && statements.count > 1 && statements.contains { !SQLText.isReadOnly($0, kind: kind) },
                                 dangerous: AppState.confirmDangerous ? statements.filter { SQLText.danger($0) != nil } : [],
                                 discardedEdits: tab.edits.count,
                                 production: app.profile(tab.profileID)?.environment == .production,
                                 kind: kind)
        if confirm.needsConfirm { pendingRun = confirm } else { start(confirm) }
    }

    private func start(_ confirm: RunConfirm) {
        if confirm.explain {
            Task { await app.run(sql: confirm.statements[0], explain: true) }
        } else {
            Task { await app.runScript(confirm.statements) }
        }
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
    @AppStorage(Layout.rowDetailWidth) private var detailWidth: Double = 380
    /// 결과 안 빠른 필터 (보이는 행만 거른다)
    @State private var filterText = ""

    var body: some View {
        VStack(spacing: 0) {
            if !tab.running && tab.results.count > 1 {
                ResultTabsBar(results: tab.results, selected: tab.resultIndex, onSelect: onSelectResult)
                Divider()
            }
            if tab.running {
                RunningView(started: tab.runStarted) { Task { await app.cancelQuery(tab.id) } }
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
                    PlanWarningsView(result: result, tree: tab.planTree)
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
                    let allRows = tab.edits.displayRows(result)
                    let words = ResultCopy.words(filterText)
                    let rows = words.isEmpty ? allRows
                        : allRows.filter { $0.id >= newRowBase || ResultCopy.matches($0.values, words: words) }
                    QuickFilterBar(text: $filterText, shown: rows.count, total: allRows.count)
                    Divider()
                    let fk = app.fkContext(for: tab)
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            ResultGrid(result: result, rows: rows, edits: tab.edits, selection: $selection,
                                       onSort: { column, ascending in
                                           InlineCellTextField.endActiveEditing()
                                           onSort(column, ascending)
                                       },
                                       editable: { if case .success = target { return true } else { return false } }(),
                                       editableColumns: { if case .success(let t) = target { return Set(t.columnMap.keys) } else { return [] } }(),
                                       onSetCell: { row, column, value in app.setCell(tab.id, row: row, column: column, value: value) },
                                       onAddRow: { if let id = app.addRow(tab.id) { selection = [id] } },
                                       onDeleteRows: { ids in app.toggleDelete(tab.id, rows: ids) },
                                       onReachEnd: result.appendMode ? { Task { await app.loadMore(in: tab.id) } } : nil,
                                       copyTableName: { if case .success(let t) = target { return t.table.name } else { return "table" } }(),
                                       dialect: app.connections[tab.profileID]?.session?.dialect, fk: fk)
                            if let row = selectedRow(rows) {
                                ResizeHandle(axis: .vertical, size: $detailWidth.cgFloat,
                                             range: 240...max(240, geo.size.width - 200))
                                RowDetailView(result: result, row: row,
                                              rowNumber: row.id >= newRowBase ? nil : result.rowOffset + row.id + 1,
                                              editor: rowEditor(target), fk: fk) { selection = [] }
                                    .frame(width: min(CGFloat(detailWidth), max(240, geo.size.width - 200)))
                            }
                        }
                    }
                }
                if let run = tab.idSearch, IDSearchMissingBar.applies(run, to: result) {
                    Divider()
                    IDSearchMissingBar(run: run, result: result)
                }
                Divider()
                StatusBar(result: result, selectedCount: selection.count, loading: tab.pageLoading || !tab.edits.isEmpty,
                          exportProgress: tab.exportProgress, appendCapped: tab.appendCapped,
                          onPage: { page in
                              InlineCellTextField.endActiveEditing()
                              onPage(page)
                          }, onCount: onCount, onExport: { app.exportResult(tab.id) },
                          onCancelExport: { app.cancelExport(tab.id) })
            } else {
                Text(tr("쿼리를 실행하면 결과가 여기 나와요."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: tab.result?.sql) { filterText = "" }
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
    /// 그 자리에서 고칠 수 있는 컬럼 (테이블 컬럼과 이어진 결과 컬럼)
    var editableColumns: Set<Int> = []
    /// 칸 값 바꾸기 (행 id, 컬럼, 새 값 — nil 은 NULL)
    var onSetCell: ((Int, Int, String?) -> Void)?
    var onAddRow: (() -> Void)?
    var onDeleteRows: ((Set<Int>) -> Void)?
    /// 끝 근처 행이 보이면 (보이지 않는 페이징: 다음 행 이어 붙이기)
    var onReachEnd: (() -> Void)?
    /// INSERT 로 복사할 때 쓸 테이블 이름 / 문법
    var copyTableName = "table"
    var dialect: (any SQLDialect)?
    /// 외래 키 따라가기 (한 테이블 조회 결과일 때만)
    var fk: FKContext?
    @State private var sortOrder: [ColumnSortComparator] = []
    @State private var hoveredRow: Int?
    /// 그 자리에서 고치고 있는 칸 (이 칸에만 입력란을 만든다)
    /// 그 자리에서 고치는 칸. 표(NSTableView)는 줄 값이 그대로면 칸을 다시 그리지 않으므로,
    /// 칸마다 이 상태를 직접 지켜보게(@Observable) 해서 Esc 로 취소해도 입력란이 사라지게 한다
    @State private var editState = InlineEditState()
    private var editingCell: GridCell? {
        get { editState.cell }
        nonmutating set { editState.cell = newValue }
    }
    @State private var pointer = PointerCell()
    @State private var doubleTick = 0
    /// 행을 고르면 결과 표로 키보드 포커스를 옮긴다 (⌘C 가 편집기가 아니라 표에 가도록)
    @FocusState private var gridFocused: Bool

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumnForEach(result.columns) { column in
                TableColumn(header(column), sortUsing: ColumnSortComparator(column: column.id)) { (row: QueryResult.Row) in
                    cellOrEditor(row, column)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        // ⌘ 클릭: 참조 따라가기 (외래 키 칸에서만 — 다른 칸의 ⌘ 클릭 여러 행 선택은 그대로)
                        .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                            fk?.follow(column: column.id, row: row.values)
                        }, including: fk?.byColumn[column.id] == nil ? .subviews : .all)
                        .background(hoveredRow == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        .onHover { inside in
                            let here = GridCell(row: row.id, column: column.id)
                            if inside {
                                hoveredRow = row.id
                                pointer.cell = here
                                PointerCell.active = pointer
                            } else {
                                if hoveredRow == row.id { hoveredRow = nil }
                                if pointer.cell == here { pointer.cell = nil }
                            }
                        }
                        .onAppear {
                            if let onReachEnd, column.id == 0, row.id < newRowBase, row.id >= result.rows.count - 40 { onReachEnd() }
                        }
                }
                .width(min: 50, ideal: 140)
            }
        }
        .onAppear {
            syncSortOrder()
            PointerCell.startTracking()
            PointerCell.active = pointer
            pointer.doubleClicked = { doubleTick &+= 1 }
        }
        // 칸 더블클릭 (앱 이벤트에서 받은 표 위치) → 그 칸을 그 자리에서 고친다
        .onChange(of: doubleTick) {
            guard let hit = pointer.pendingDouble, rows.indices.contains(hit.row) else { return }
            pointer.pendingDouble = nil
            let rowID = rows[hit.row].id
            let named = result.columns.filter { hit.title == $0.name || hit.title.hasPrefix($0.name + " ↗") }
            let column = named.count == 1 ? named[0].id : (hit.column < result.columns.count ? result.columns[hit.column].id : nil)
            guard let column else { return }
            let c = GridCell(row: rowID, column: column)
            if canEditInline(c) {
                selection = [rowID]
                beginEditing(c)
            }
        }
        .onChange(of: result.id) {
            syncSortOrder()
            editingCell = nil
        }
        .onChange(of: sortOrder) {
            guard let first = sortOrder.first, result.columns.indices.contains(first.column) else { return }
            let sort = ResultSort(column: result.columns[first.column].name, ascending: first.order == .forward)
            if sort != result.activeSort { onSort?(sort.column, sort.ascending) }
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .focused($gridFocused)
        .onChange(of: selection) { if !selection.isEmpty && editingCell == nil { gridFocused = true } }
        // ⌘C: 고른 행을 TSV(머리글 포함)로 — 엑셀 · 스프레드시트에 바로 붙여 넣을 수 있다
        .onCopyCommand {
            let text = copyText(.tsv, selection)
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
        .contextMenu(forSelectionType: QueryResult.Row.ID.self) { ids in
            if let fk, ids.count == 1, let row = rows.first(where: { ids.contains($0.id) }), fk.hasMenu(row: row.values) {
                FKFollowMenuItems(context: fk, row: row.values)
                Divider()
            }
            if editable {
                Button(tr("이 행 편집")) { selection = ids }
                    .disabled(ids.count != 1)
                // 우클릭한 칸을 NULL 로 (고른 행이 여러 개면 모두, 삭제 표시한 행은 빼고)
                if let c = pointer.cell, ids.contains(c.row), editableColumns.contains(c.column),
                   result.columns.indices.contains(c.column) {
                    let targets = ids.filter { !edits.deletes.contains($0) }
                    Button(tr("NULL 로 설정 (%@)", result.columns[c.column].name)) {
                        InlineCellTextField.endActiveEditing()
                        for id in targets { onSetCell?(id, c.column, nil) }
                    }
                    .disabled(targets.isEmpty)
                }
                Button(tr("행 추가")) { onAddRow?() }
                Button(edits.deletes.isSuperset(of: ids.filter { $0 < newRowBase }) && !ids.isEmpty
                       ? tr("삭제 표시 해제") : tr("선택 행 삭제")) { onDeleteRows?(ids) }
                    .disabled(ids.isEmpty)
                Divider()
            }
            Button(tr("복사 (⌘C)")) { Pasteboard.copy(copyText(.tsv, ids)) }
                .disabled(ids.isEmpty)
            Menu(tr("다른 형식으로 복사")) {
                ForEach([ExportFormat.csv, .tsv, .sql, .json, .markdown]) { f in
                    Button(f.title) { Pasteboard.copy(copyText(f, ids)) }
                }
            }
            .disabled(ids.isEmpty)
            Menu(tr("IN 목록으로 복사")) {
                ForEach(result.columns) { c in
                    Button(c.name) {
                        let values = rows.filter { ids.contains($0.id) }.map { $0.values[c.id] }
                        Pasteboard.copy(ResultCopy.inList(values, quote: dialect?.quoteString ?? SQLText.quoteString))
                    }
                }
            }
            .disabled(ids.isEmpty)
        } primaryAction: { ids in
            // 편집 가능한 결과에서 칸 더블클릭: 그 칸을 그 자리에서 고친다.
            // 그 밖(편집 불가 결과 · 테이블 컬럼이 아닌 칸 · 여러 줄 값 · 칸 밖 · ↩ 키): 행을 골라 오른쪽 상세 패널을 연다
            selection = ids
            if NSApp.currentEvent?.type != .keyDown, ids.count == 1, let rowID = ids.first,
               let c = clickedCell(row: rowID) ?? pointer.cell.flatMap({ $0.row == rowID ? $0 : nil }),
               canEditInline(c) {
                beginEditing(c)
            }
        }
    }

    /// 더블클릭한 위치의 칸 (머리글 이름으로 컬럼을 찾고, 같은 이름이 여럿이면 화면 순서로)
    private func clickedCell(row: Int) -> GridCell? {
        guard let hit = PointerCell.clickedColumn() else { return nil }
        let named = result.columns.filter { hit.title == $0.name || hit.title.hasPrefix($0.name + " ↗") }
        if named.count == 1, let col = named.first { return GridCell(row: row, column: col.id) }
        guard hit.index < result.columns.count else { return nil }
        return GridCell(row: row, column: result.columns[hit.index].id)
    }

    /// 머리글: 외래 키 컬럼이면 이름 옆에 ↗ (추정 관계만 있으면 흐리게)
    private func header(_ column: QueryResult.Column) -> Text {
        guard let inferred = fk?.inferredOnly(column: column.id) else { return Text(column.name) }
        let arrow = Text(verbatim: "↗").foregroundStyle(inferred ? Color.secondary.opacity(0.5) : Color.accentColor)
        return Text("\(column.name) \(arrow)")
    }

    /// 고른 행을 화면 순서대로 글자로
    private func copyText(_ format: ExportFormat, _ ids: Set<QueryResult.Row.ID>) -> String {
        let picked = rows.filter { ids.contains($0.id) }.map(\.values)
        guard !picked.isEmpty else { return "" }
        return ResultCopy.text(format, columns: result.columns.map(\.name), rows: picked,
                               tableName: copyTableName, dialect: dialect)
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

    /// 고치는 칸이면 입력란, 아니면 보통 칸
    @ViewBuilder
    private func cellOrEditor(_ row: QueryResult.Row, _ column: QueryResult.Column) -> some View {
        let here = GridCell(row: row.id, column: column.id)
        let original = row.values[column.id]
        EditableGridCell(state: editState, here: here) {
            InlineCellEditor(initial: InlineCellEdit.initialText(original)) { text, how, keyboard in
                finishEditing(here, original: original, text: text, how: how, keyboard: keyboard)
            }
        } content: {
            cell(row, column)
        }
    }

    /// 그 자리에서 고칠 수 있는 칸인지: 테이블 컬럼, 삭제 표시 안 한 행, 한 줄 값
    private func canEditInline(_ c: GridCell) -> Bool {
        guard editable, onSetCell != nil, editableColumns.contains(c.column), !edits.deletes.contains(c.row),
              let row = rows.first(where: { $0.id == c.row }), row.values.indices.contains(c.column) else { return false }
        return InlineCellEdit.canEditInline(row.values[c.column])
    }

    /// 칸 편집을 끝낸다: 바뀌었으면 변경에 넣고, Tab/⇧Tab 이면 같은 행 옆 칸으로
    /// 칸 편집 시작: 표가 포커스를 다시 가져가지 않게 표 포커스를 먼저 놓는다 (입력란이 스스로 첫 응답자가 된다)
    private func beginEditing(_ c: GridCell) {
        gridFocused = false
        editingCell = c
    }

    private func finishEditing(_ c: GridCell, original: String?, text: String, how: InlineCellEdit.Finish, keyboard: Bool) {
        guard editingCell == c else { return }
        if let value = InlineCellEdit.committedValue(original: original, text: text, finish: how) {
            onSetCell?(c.row, c.column, value)
        }
        if let next = InlineCellEdit.neighbor(of: c.column, editable: Array(editableColumns), finish: how),
           case let nextCell = GridCell(row: c.row, column: next), canEditInline(nextCell) {
            beginEditing(nextCell)
        } else {
            editingCell = nil
            // 키보드로 끝냈으면 표로 포커스를 돌려 화살표 · ⌘C 가 이어지게 (다른 곳을 눌렀으면 그대로)
            if keyboard { gridFocused = true }
        }
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
    /// 외래 키 따라가기 (↗ 버튼 · 참조하는 테이블)
    var fk: FKContext?
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
                    if let fk {
                        FKReferencingList(context: fk, row: row.values)
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
                if let fk {
                    FKFollowButtons(context: fk, column: column.id, row: row.values)
                }
                Spacer()
                if let value {
                    Text(tr("%@자", "\(value.count)")).font(.caption2).foregroundStyle(.tertiary)
                    Button { Pasteboard.copy(value) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.hover)
                        .help(tr("값 복사"))
                }
            }
            let type = columnType(column)
            if editable, let editor {
                if state == .insertedDefault {
                    Button(tr("값 입력 (지금은 DB 기본값)")) { editor.set(column.id, "") }
                        .buttonStyle(.hover)
                        .font(.callout)
                } else {
                    // JSON 칸: 원문 편집만 (정렬 · 트리는 지금 값 보기). JSON 이 깨지면 경고 (저장은 가능)
                    let jsonColumn = isJSONColumn(column, type)
                    let detection = jsonColumn ? JSONCache.detect(value, columnType: type) : .notJSON
                    JSONFieldView(text: value ?? "", detection: detection) {
                        TextField("", text: Binding(
                            get: { value ?? "" },
                            set: { editor.set(column.id, $0) }
                        ), axis: .vertical)
                        .font(.system(.callout, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...8)
                        .disabled(value == nil)
                    }
                    if jsonColumn, !JSONView.isValid(value) {
                        Label(tr("JSON 형식이 아니에요"), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
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
            } else if let value, case let detection = JSONCache.detect(value, columnType: type), detection.isJSON {
                JSONFieldView(text: value, detection: detection)
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

    /// 결과 컬럼의 테이블 컬럼 타입 (한 테이블 조회 결과일 때만 알 수 있음)
    private func columnType(_ column: QueryResult.Column) -> String? {
        let table = editor?.target.table ?? fk?.source
        let name = editor?.target.columnMap[column.id] ?? column.name
        return table?.columns.first { $0.name.lowercased() == name.lowercased() }?.columnType
    }

    /// 편집 중 JSON 칸으로 다룰지: 타입이 json / jsonb 이거나 원래 값이 JSON
    private func isJSONColumn(_ column: QueryResult.Column, _ type: String?) -> Bool {
        if JSONView.isJSONType(type) { return true }
        guard let values = result.rows.first(where: { $0.id == row.id })?.values, values.indices.contains(column.id),
              let original = values[column.id] else { return false }
        return JSONCache.detect(original, columnType: nil).isJSON
    }
}

/// 실행 계획 주의사항 + 트리 형태 계획
struct PlanWarningsView: View {
    let result: QueryResult
    let tree: String?
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
    var appendCapped = false
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
                if result.appendMode {
                    HStack(spacing: 6) {
                        Text(tr("%@행", "\(result.rows.count.formatted())")).monospacedDigit().foregroundStyle(.primary)
                            .fixedSize()
                        if loading { ProgressView().controlSize(.small) }
                        Text(!result.hasMore ? tr("· 끝")
                             : appendCapped ? tr("· 화면 최대 %@행 — 전체는 [내보내기]", AppState.maxRowsInMemory.formatted())
                             : tr("· 스크롤하면 더 불러와요"))
                    }
                } else if result.isPaged {
                    pager
                } else {
                    Text(tr("%@행", "\(result.rows.count.formatted())")).fixedSize()
                }
                if selectedCount > 0 { Text(tr("%@행 선택", "\(selectedCount)")).fixedSize() }
            }
            Text(String(format: "%.0fms", result.elapsed * 1000)).fixedSize()
            if !result.columns.isEmpty && selectedCount == 0 && !result.isPaged {
                // 자리가 모자라면 이 안내부터 줄어든다
                Text(tr("행을 클릭하면 상세가 나와요")).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
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
                        .lineLimit(1)
                }
                .buttonStyle(.hover)
                .fixedSize()
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
                    .fixedSize()
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
        .fixedSize()
        if let total = result.totalCount {
            Text(tr("/ 전체 %@행 · %@/%@페이지", "\(total.formatted())", "\(result.page + 1)", "\((lastPage ?? 0) + 1)"))
                .lineLimit(1).truncationMode(.middle)
        } else {
            Text(tr("%@페이지", "\(result.page + 1)") + (result.hasMore ? tr(" · 더 있음") : tr(" · 끝")))
                .lineLimit(1)
            Button(tr("전체 행 수")) { onCount() }
                .buttonStyle(.hover)
                .fixedSize()
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

/// 실행 전에 확인할 것: 편집기 전체 실행 · 되돌리기 어려운 문장 · 적용하지 않은 결과 편집
@MainActor
struct RunConfirm: Identifiable {
    let id = UUID()
    var statements: [String]
    var explain = false
    var wholeScript = false
    var dangerous: [String] = []
    var discardedEdits = 0
    /// 운영 접속: 데이터를 바꾸는 문장이 있으면 항상 확인
    var production = false
    /// 쓰기 문장 판별에 쓰는 DB 종류 (주석 · 문자열 규칙이 다르다)
    var kind: DatabaseKind = .mysql

    private var writes: [String] { statements.filter { !SQLText.isReadOnly($0, kind: kind) } }
    private var productionWrites: Bool { production && !explain && !writes.isEmpty }

    var needsConfirm: Bool { wholeScript || !dangerous.isEmpty || discardedEdits > 0 || productionWrites }

    var title: String {
        if !dangerous.isEmpty { return tr("되돌리기 어려운 문장이 있어요") }
        if productionWrites { return tr("운영 접속에서 데이터를 바꿔요") }
        if wholeScript { return tr("전체 %@개 문장을 실행할까요?", "\(statements.count)") }
        return tr("적용하지 않은 편집이 있어요")
    }

    var message: String {
        var parts: [String] = []
        if productionWrites {
            parts.append(tr("운영 접속이에요. 데이터를 바꾸는 문장 %@개를 실행해요.", "\(writes.count)")
                         + (dangerous.isEmpty ? "\n" + writes.prefix(3).map { "• " + AppState.oneLine($0, max: 50) }.joined(separator: "\n") : ""))
        }
        if !dangerous.isEmpty {
            let lines = dangerous.prefix(3).map { "• " + Self.label(SQLText.danger($0)) + " — " + AppState.oneLine($0, max: 50) }
            parts.append(lines.joined(separator: "\n") + (dangerous.count > 3 ? "\n…" : ""))
        }
        if wholeScript {
            parts.append(tr("편집기의 모든 문장(%@개, 변경 문 %@개)을 위에서부터 실행해요. 한 문장만 실행하려면 그 문장에 커서를 두고 ⌘↩ 를 누르세요.",
                            "\(statements.count)", "\(writes.count)"))
        }
        if discardedEdits > 0 {
            parts.append(tr("결과 표에서 고치고 적용하지 않은 %@건은 사라져요.", "\(discardedEdits)"))
        }
        return parts.joined(separator: "\n\n")
    }

    static func label(_ d: SQLText.Danger?) -> String {
        switch d {
        case .deleteAll: tr("WHERE 없는 DELETE (모든 행 삭제)")
        case .updateAll: tr("WHERE 없는 UPDATE (모든 행 변경)")
        case .truncate: tr("TRUNCATE (모든 행 삭제)")
        case .drop: tr("DROP (객체 삭제)")
        case nil: ""
        }
    }
}

/// 결과 표 위 빠른 필터 (받아 온 행 안에서만 거른다)
struct QuickFilterBar: View {
    @Binding var text: String
    let shown: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField(tr("결과 안에서 찾기 (여러 단어는 모두 포함)"), text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Text(tr("%@ / %@행", "\(shown)", "\(total)")).monospacedDigit().foregroundStyle(.secondary)
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(tr("필터 지우기"))
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// 실행 중 표시: 경과 시간과 취소 버튼
struct RunningView: View {
    let started: Date?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = started.map { Int(context.date.timeIntervalSince($0)) } ?? 0
                Text(tr("실행 중… %@초", "\(seconds)")).monospacedDigit().foregroundStyle(.secondary)
            }
            Button(tr("취소"), role: .cancel, action: onCancel)
                .help(tr("실행 중인 쿼리 멈추기 (⌘.)"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
