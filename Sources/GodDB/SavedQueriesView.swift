import GodDBCore
import SwiftUI

/// 저장 쿼리 창 하나 (같은 자리에서 목록 → 빈칸 입력으로 바꿔 띄운다)
enum SavedQuerySheet: Identifiable {
    /// 쿼리 저장 (⌥⌘S)
    case save(sql: String)
    /// 저장 쿼리 목록 (⇧⌘K)
    case list
    /// 빈칸 입력
    case fill(UUID)

    var id: String {
        switch self {
        case .save: "save"
        case .list: "list"
        case .fill(let id): "fill-\(id)"
        }
    }
}

extension AppState {
    /// 저장 쿼리를 쓸 수 있는지 (Redis 가 아닌 접속을 보고 있을 때)
    var canOpenSavedQueries: Bool {
        selectedProfile.map { $0.kind != .redis } ?? false
    }

    /// ⌥⌘S 가 가능한지 (SQL 쿼리 탭을 보고 있을 때)
    var canSaveQuery: Bool {
        mode == .query && selectedTab.map { profile($0.profileID)?.kind != .redis } == true
    }

    /// 보고 있는 접속의 SQL 문법 (빈칸 · 값 변환)
    var savedQueryDialect: any SQLDialect {
        if let id = selectedProfileID, let d = connections[id]?.session?.dialect { return d }
        return selectedProfile.map { Dialects.of($0.kind) } ?? dialect
    }

    /// 쿼리 저장 창: 선택 영역 → 커서가 있는 문장 → 편집기 전체
    func openSaveQuery() {
        guard canSaveQuery, let tab = selectedTab else { return }
        let picked = activeEditor?.sqlToRun()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sql = picked.isEmpty ? tab.text.trimmingCharacters(in: .whitespacesAndNewlines) : picked
        guard !sql.isEmpty else {
            log(.warning, .app, tr("저장할 쿼리가 없어요. 편집기에 쿼리를 쓰고 다시 저장하세요."))
            return
        }
        savedQuerySheet = .save(sql: sql)
    }

    func openSavedQueries() {
        guard canOpenSavedQueries else { return }
        savedQueries = SavedQueryStore.shared.load()
        savedQuerySheet = .list
    }

    /// 저장 쿼리 목록을 바꾸고 바로 파일에 쓴다
    func changeSavedQueries(_ change: (inout SavedQueryLibrary) -> Void) {
        change(&savedQueries)
        SavedQueryStore.shared.save(savedQueries)
    }

    /// 목록에서 실행 · 편집기에 넣기: 빈칸이 없으면 바로, 있으면 입력 창
    func useSavedQuery(_ id: UUID, run: Bool) {
        guard let q = savedQueries[id] else { return }
        if SQLParameters.names(in: q.sql, kind: savedQueryDialect.kind).isEmpty {
            savedQuerySheet = nil
            changeSavedQueries { $0.markUsed(id) }
            placeSavedQuery(q.sql, title: q.name, run: run)
        } else {
            savedQuerySheet = .fill(id)
        }
    }

    /// 빈칸을 채워 넣는다 (입력값은 다음을 위해 기억)
    func applySavedQuery(_ id: UUID, inputs: [String: SQLParameters.Input], run: Bool) {
        guard let q = savedQueries[id] else { return }
        let sql = SQLParameters.fill(q.sql, inputs: inputs, dialect: savedQueryDialect)
        savedQuerySheet = nil
        changeSavedQueries { $0.markUsed(id, values: inputs.mapValues(\.value)) }
        placeSavedQuery(sql, title: q.name, run: run)
    }

    /// 지금 탭이 비었으면 그 탭, 아니면 새 탭(제목 = 저장 쿼리 이름)에 넣는다. run 이면 평소 실행 경로로 실행.
    private func placeSavedQuery(_ sql: String, title: String, run: Bool) {
        guard let profileID = selectedProfileID else { return }
        let tabID: UUID
        if let i = selectedTabIndex, tabs[i].profileID == profileID, !tabs[i].running, tabs[i].source == nil,
           tabs[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tabs[i].text = sql
            tabID = tabs[i].id
        } else {
            guard let id = addTab(text: sql, title: title, for: profileID) else { return }
            tabID = id
        }
        if run { runAllRequest = tabID }
    }
}

/// ContentView 에서 띄우는 저장 쿼리 창
struct SavedQuerySheetView: View {
    let sheet: SavedQuerySheet

    var body: some View {
        switch sheet {
        case .save(let sql): SaveQueryView(sql: sql)
        case .list: SavedQueryListView()
        case .fill(let id): SavedQueryFillView(queryID: id)
        }
    }
}

// MARK: - 저장 창

/// 쿼리 저장 (⌥⌘S): 이름 · 폴더 · 범위
struct SaveQueryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let sql: String

    @State private var name = ""
    @State private var folder = ""
    @State private var scope: SavedQuery.Scope = .all

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let params = SQLParameters.names(in: sql, kind: app.savedQueryDialect.kind)
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("쿼리 저장"), systemImage: "bookmark").font(.headline)
            ScrollView {
                Text(sql)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(height: 110)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            Form {
                TextField(tr("이름"), text: $name)
                TextField(tr("폴더"), text: $folder, prompt: Text(tr("선택 사항")))
                    .textInputSuggestions {
                        ForEach(app.savedQueries.folders.filter { folder.isEmpty || $0.localizedCaseInsensitiveContains(folder) },
                                id: \.self) { f in
                            Text(f).textInputCompletion(f)
                        }
                    }
                Picker(tr("보이는 곳"), selection: $scope) {
                    Text(tr("모든 접속")).tag(SavedQuery.Scope.all)
                    Text(tr("이 접속만")).tag(SavedQuery.Scope.profile)
                }
                .pickerStyle(.segmented)
                .disabled(app.selectedProfileID == nil)
            }
            Text(params.isEmpty ? tr("빈칸 없음") : tr("빈칸: %@", params.map { ":" + $0 }.joined(separator: ", ")))
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button(tr("취소")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("저장")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { name = SavedQuery.defaultName(for: sql) }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        let q = SavedQuery(name: trimmedName, folder: folder.trimmingCharacters(in: .whitespacesAndNewlines), sql: sql,
                           scope: scope, profileID: app.selectedProfileID)
        app.changeSavedQueries { $0.add(q) }
        app.log(.info, .app, tr("저장 쿼리에 넣었어요: %@", q.name))
        dismiss()
    }
}

// MARK: - 목록 창

/// 저장 쿼리 목록 (⇧⌘K): 검색 · 폴더별 · 최근 사용 순
struct SavedQueryListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: UUID?
    @State private var renaming: SavedQuery?
    @State private var refoldering: SavedQuery?
    @State private var deleting: SavedQuery?
    @State private var editText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let found = app.savedQueries.search(query, profileID: app.selectedProfileID)
        let groups = SavedQueryLibrary.grouped(found)
        let ordered = groups.flatMap(\.queries)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tr("저장 쿼리 검색 (이름 · SQL · 폴더)"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { if let id = selected ?? ordered.first?.id { app.useSavedQuery(id, run: true) } }
                    .onKeyPress(.downArrow) { move(1, in: ordered); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: ordered); return .handled }
            }
            .padding(12)
            Divider()
            if found.isEmpty {
                ContentUnavailableView(app.savedQueries.queries.isEmpty ? tr("저장한 쿼리가 없어요") : tr("찾는 저장 쿼리가 없어요"),
                                       systemImage: "bookmark",
                                       description: Text(tr("편집기에서 ⌥⌘S 로 지금 쿼리를 저장하세요.")))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selected) {
                    ForEach(groups) { group in
                        Section(group.folder.isEmpty ? tr("폴더 없음") : group.folder) {
                            ForEach(group.queries) { q in row(q).tag(q.id) }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let q = app.savedQueries[id] { menu(q) }
                } primaryAction: { ids in
                    if let id = ids.first { app.useSavedQuery(id, run: true) }
                }
            }
            Divider()
            HStack {
                Text(tr("↩ · 더블클릭 실행 · 우클릭 메뉴 · esc 닫기"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("닫기")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 640, height: 480)
        .onAppear {
            fieldFocused = true
            selected = ordered.first?.id
        }
        .onChange(of: query) { selected = SavedQueryLibrary.grouped(app.savedQueries.search(query, profileID: app.selectedProfileID)).first?.queries.first?.id }
        .alert(tr("이름 바꾸기"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { q in
            TextField(tr("이름"), text: $editText)
            Button(tr("바꾸기")) { app.changeSavedQueries { $0.rename(q.id, to: editText) } }
            Button(tr("취소"), role: .cancel) {}
        }
        .alert(tr("폴더 바꾸기"), isPresented: Binding(get: { refoldering != nil }, set: { if !$0 { refoldering = nil } }), presenting: refoldering) { q in
            TextField(tr("폴더"), text: $editText)
            Button(tr("바꾸기")) { app.changeSavedQueries { $0.setFolder(q.id, to: editText) } }
            Button(tr("취소"), role: .cancel) {}
        } message: { _ in
            Text(tr("비우면 폴더 없음. 있는 폴더: %@", app.savedQueries.folders.isEmpty ? "—" : app.savedQueries.folders.joined(separator: ", ")))
        }
        .alert(tr("저장 쿼리를 지울까요?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { q in
            Button(tr("삭제"), role: .destructive) { app.changeSavedQueries { $0.delete(q.id) } }
            Button(tr("취소"), role: .cancel) {}
        } message: { q in
            Text(tr("'%@' 을(를) 지워요. 되돌릴 수 없어요.", q.name))
        }
    }

    private func row(_ q: SavedQuery) -> some View {
        let params = SQLParameters.names(in: q.sql, kind: app.savedQueryDialect.kind)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(q.name).lineLimit(1)
                if q.scope == .profile {
                    Image(systemName: "link").font(.caption).foregroundStyle(.secondary)
                        .help(tr("이 접속만"))
                }
                if !params.isEmpty {
                    Text(params.map { ":" + $0 }.joined(separator: " "))
                        .font(.caption.monospaced()).foregroundStyle(.orange).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let used = q.lastUsedAt {
                    Text(used, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Text(AppState.oneLine(q.sql, max: 100))
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func menu(_ q: SavedQuery) -> some View {
        Button(tr("실행")) { app.useSavedQuery(q.id, run: true) }
        Button(tr("편집기에 넣기")) { app.useSavedQuery(q.id, run: false) }
        Divider()
        Button(tr("이름 바꾸기")) { editText = q.name; renaming = q }
        Button(tr("폴더 바꾸기")) { editText = q.folder; refoldering = q }
        Button(tr("복제")) { app.changeSavedQueries { $0.duplicate(q.id, suffix: tr(" 사본")) } }
        Divider()
        Button(tr("삭제…"), role: .destructive) { deleting = q }
    }

    private func move(_ delta: Int, in list: [SavedQuery]) {
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : list.count)
        selected = list[max(0, min(list.count - 1, i + delta))].id
    }
}

// MARK: - 빈칸 입력 창

/// 빈칸 입력: 값 · NULL · 그대로 넣기. [넣기만] [취소] [실행 (⌘↩)]
struct SavedQueryFillView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let queryID: UUID

    @State private var names: [String] = []
    @State private var inputs: [String: SQLParameters.Input] = [:]
    @FocusState private var focused: String?

    private var query: SavedQuery? { app.savedQueries[queryID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(query?.name ?? tr("저장 쿼리"), systemImage: "bookmark").font(.headline).lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(names, id: \.self) { name in
                    GridRow {
                        Text(":" + name).font(.body.monospaced())
                        TextField(":" + name, text: binding(name, \.value))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220)
                            .disabled(inputs[name]?.isNull == true)
                            .focused($focused, equals: name)
                            .accessibilityLabel(":" + name)
                        Toggle("NULL", isOn: binding(name, \.isNull))
                        Toggle(tr("그대로 넣기"), isOn: binding(name, \.raw))
                            .disabled(inputs[name]?.isNull == true)
                            .help(tr("입력을 SQL 조각으로 그대로 넣어요 (예: NOW(), 1,2,3)"))
                    }
                }
            }
            Text(tr("숫자는 그대로, 그 밖은 따옴표로 감싸요. 쉼표로 나누면 목록(IN (…))이 돼요."))
                .font(.caption).foregroundStyle(.secondary)
            if let query {
                ScrollView {
                    Text(SQLParameters.fill(query.sql, inputs: inputs, dialect: app.savedQueryDialect))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                }
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            }
            HStack {
                Button(tr("넣기만")) { app.applySavedQuery(queryID, inputs: inputs, run: false) }
                    .help(tr("값을 채운 쿼리를 편집기에 넣고 실행하지 않아요"))
                Spacer()
                Button(tr("취소")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("실행")) { app.applySavedQuery(queryID, inputs: inputs, run: true) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help(tr("값을 채워 실행 (⌘↩)"))
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear(perform: load)
    }

    private func binding<T>(_ name: String, _ key: WritableKeyPath<SQLParameters.Input, T>) -> Binding<T> {
        Binding(get: { (inputs[name] ?? .init())[keyPath: key] },
                set: { inputs[name, default: .init()][keyPath: key] = $0 })
    }

    /// 빈칸 목록과 지난번 입력값
    private func load() {
        guard let query else { return }
        names = SQLParameters.names(in: query.sql, kind: app.savedQueryDialect.kind)
        for n in names { inputs[n] = .init(value: query.lastValues[n] ?? "") }
        focused = names.first
    }
}
