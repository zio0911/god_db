import GodDBCore
import SwiftUI

/// 객체 빠른 찾기 (⌘O): 테이블 · 뷰 · 프로시저 · 함수 · 컬럼 · DB 이름으로 찾아 바로 연다
struct QuickOpenView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var others: [QuickOpen.Item] = []
    @State private var loadingOthers = false
    @State private var selected: QuickOpen.Item.ID?
    @FocusState private var fieldFocused: Bool

    private var items: [QuickOpen.Item] {
        let db = app.currentDatabase
        var list: [QuickOpen.Item] = []
        for t in app.tables {
            list.append(.init(kind: .table, schema: db, name: t.name, detail: t.comment))
            for c in t.columns { list.append(.init(kind: .column, schema: db, name: c.name, detail: t.name)) }
        }
        for r in app.routines {
            let kind: QuickOpen.Kind = switch r.kind {
            case .view: .view
            case .procedure: .procedure
            case .function: .function
            case .trigger: .trigger
            }
            list.append(.init(kind: kind, schema: db, name: r.name, detail: r.comment))
        }
        for d in app.databases where d != db { list.append(.init(kind: .database, schema: d, name: d)) }
        return list + others
    }

    private var results: [QuickOpen.Item] {
        // 검색어가 없으면 컬럼은 빼고 보여준다 (너무 많음)
        query.isEmpty ? Array(items.filter { $0.kind != .column }.prefix(200)) : QuickOpen.search(query, in: items)
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tr("테이블 · 뷰 · 프로시저 · 컬럼 이름 (예: ord_it, shop.orders)"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { if let item = list.first(where: { $0.id == selected }) ?? list.first { open(item) } }
                    .onKeyPress(.downArrow) { move(1, in: list); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: list); return .handled }
                if loadingOthers { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Divider()
            if list.isEmpty {
                ContentUnavailableView(app.state == .connected ? tr("찾는 객체가 없어요") : tr("먼저 접속을 연결하세요"),
                                       systemImage: "magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(list, selection: $selected) { item in
                        row(item).tag(item.id).id(item.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: selected) { if let s = selected { proxy.scrollTo(s) } }
                    .contextMenu(forSelectionType: QuickOpen.Item.ID.self) { _ in } primaryAction: { ids in
                        if let id = ids.first, let item = list.first(where: { $0.id == id }) { open(item) }
                    }
                }
            }
            Divider()
            Text(tr("↑↓ 고르기 · ↩ 열기 · esc 닫기") + (app.dialect.allTablesSQL == nil ? tr(" · SQL Server 는 지금 DB 만 찾아요") : ""))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(width: 620, height: 460)
        .onAppear {
            fieldFocused = true
            Task { await loadOthers() }
        }
        .onChange(of: query) { selected = results.first?.id }
        .onExitCommand { dismiss() }
    }

    private func row(_ item: QuickOpen.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(item.kind)).foregroundStyle(color(item.kind)).frame(width: 18)
            Text(item.name).lineLimit(1)
            if item.kind == .column {
                Text(item.detail).foregroundStyle(.secondary).lineLimit(1)
            } else if !item.detail.isEmpty {
                Text(item.detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.kind != .database {
                Text(item.schema).font(.caption).foregroundStyle(item.schema == app.currentDatabase ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
    }

    private func icon(_ k: QuickOpen.Kind) -> String {
        switch k {
        case .table: "tablecells"
        case .view: "eye"
        case .procedure: "gearshape"
        case .function: "function"
        case .trigger: "bolt"
        case .column: "text.alignleft"
        case .database: "cylinder.split.1x2"
        }
    }

    private func color(_ k: QuickOpen.Kind) -> Color {
        switch k {
        case .table: .blue
        case .view: .teal
        case .procedure, .function, .trigger: .purple
        case .column: .secondary
        case .database: .orange
        }
    }

    private func move(_ delta: Int, in list: [QuickOpen.Item]) {
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : list.count)
        selected = list[max(0, min(list.count - 1, i + delta))].id
    }

    /// 다른 스키마의 테이블 · 뷰 (MySQL · PostgreSQL)
    private func loadOthers() async {
        guard let session = app.session, app.state == .connected else { return }
        loadingOthers = true
        defer { loadingOthers = false }
        let current = app.currentDatabase
        let rows = (try? await session.allTables()) ?? []
        others = rows.filter { $0.schema != current }
            .map { QuickOpen.Item(kind: $0.isView ? .view : .table, schema: $0.schema, name: $0.name) }
    }

    private func open(_ item: QuickOpen.Item) {
        dismiss()
        Task { await app.openQuickItem(item) }
    }
}

extension AppState {
    func openQuickItem(_ item: QuickOpen.Item) async {
        if item.kind == .database {
            await selectDatabase(item.name)
            return
        }
        if item.schema != currentDatabase, !item.schema.isEmpty {
            await selectDatabase(item.schema)
        }
        switch item.kind {
        case .table, .view:
            openTableQuery(item.name)
        case .column:
            openTableQuery(item.detail)
        case .procedure, .function, .trigger:
            if let r = routines.first(where: { $0.name == item.name }) { await openRoutine(r) }
        case .database:
            break
        }
    }
}
