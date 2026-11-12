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
                           onCount: { Task { await app.countRows(in: tab.id) } })
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
    let tab: QueryTab
    var onSelectResult: (Int) -> Void = { _ in }
    var onPage: (Int) -> Void = { _ in }
    var onCount: () -> Void = {}
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
                    PlanWarningsView(result: result, tree: tab.planTree)
                }
                if result.columns.isEmpty {
                    Text(result.message ?? tr("실행 완료"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            ResultGrid(result: result, selection: $selection)
                            if let row = selectedRow(result) {
                                ResizeHandle(axis: .vertical, size: $detailWidth,
                                             range: 240...max(240, geo.size.width - 200))
                                RowDetailView(result: result, row: row, rowNumber: result.rowOffset + row.id + 1) { selection = [] }
                                    .frame(width: min(detailWidth, max(240, geo.size.width - 200)))
                            }
                        }
                    }
                }
                Divider()
                StatusBar(result: result, selectedCount: selection.count, onPage: onPage, onCount: onCount)
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

    private func selectedRow(_ result: QueryResult) -> QueryResult.Row? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return result.rows.first { $0.id == id }
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
            ResultGrid(result: result, selection: $selection)
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
                    .buttonStyle(.plain)
                    .help(r.sql ?? "")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

struct ResultGrid: View {
    let result: QueryResult
    @Binding var selection: Set<QueryResult.Row.ID>

    var body: some View {
        Table(result.rows, selection: $selection) {
            TableColumnForEach(result.columns) { column in
                TableColumn(column.name) { (row: QueryResult.Row) in
                    if let value = row.values[column.id] {
                        Text(Self.preview(value))
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                    } else {
                        Text("NULL")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .width(min: 50, ideal: 140)
            }
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: QueryResult.Row.ID.self) { ids in
            Button(tr("행 복사 (CSV)")) {
                var copy = result
                copy.rows = result.rows.filter { ids.contains($0.id) }
                Pasteboard.copy(copy.csv())
            }
        }
    }

    /// 한 줄 미리보기 (줄바꿈은 ⏎ 로 표시)
    static func preview(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
    }
}

/// 선택한 행의 모든 컬럼 값을 전체 텍스트로 보여준다.
struct RowDetailView: View {
    let result: QueryResult
    let row: QueryResult.Row
    var rowNumber: Int
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("행 상세")).font(.headline)
                Text(tr("%@번째 행", "\(rowNumber)")).foregroundStyle(.secondary)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(tr("닫기"))
            }
            .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(result.columns) { column in
                        let value = row.values[column.id]
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(column.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                if let value {
                                    Text(tr("%@자", "\(value.count)")).font(.caption2).foregroundStyle(.tertiary)
                                    Button { Pasteboard.copy(value) } label: { Image(systemName: "doc.on.doc") }
                                        .buttonStyle(.borderless)
                                        .help(tr("값 복사"))
                                }
                            }
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
                .padding(8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
    var onPage: (Int) -> Void = { _ in }
    var onCount: () -> Void = {}

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
            if !result.columns.isEmpty {
                Button {
                    Pasteboard.copy(result.csv())
                } label: {
                    Label(tr("CSV 복사"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(tr("지금 보이는 페이지의 행을 CSV 로 복사"))
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
        HStack(spacing: 4) {
            Button { onPage(0) } label: { Image(systemName: "backward.end.fill") }
                .disabled(result.page == 0).help(tr("첫 페이지"))
            Button { onPage(result.page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(result.page == 0).help(tr("이전 페이지"))
            Text(result.rows.isEmpty ? tr("0행") : tr("%@–%@행", "\(first.formatted())", "\(last.formatted())"))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Button { onPage(result.page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(!result.hasMore).help(tr("다음 페이지"))
            if let lastPage {
                Button { onPage(lastPage) } label: { Image(systemName: "forward.end.fill") }
                    .disabled(result.page >= lastPage).help(tr("마지막 페이지"))
            }
        }
        .buttonStyle(.borderless)
        if let total = result.totalCount {
            Text(tr("/ 전체 %@행 · %@/%@페이지", "\(total.formatted())", "\(result.page + 1)", "\((lastPage ?? 0) + 1)"))
        } else {
            Text(tr("%@페이지", "\(result.page + 1)") + (result.hasMore ? tr(" · 더 있음") : tr(" · 끝")))
            Button(tr("전체 행 수")) { onCount() }
                .buttonStyle(.borderless)
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
