import GodDBCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            List(selection: $app.selectedTables) {
                Section(tr("접속")) {
                    ForEach(app.profiles) { profile in
                        ProfileRow(profile: profile)
                    }
                    Button {
                        app.newProfile()
                    } label: {
                        Label(tr("새 접속"), systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                if case .failed(let message) = app.state {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                if app.state == .connected {
                    Section {
                        if app.schemaLoading {
                            HStack { ProgressView().controlSize(.small); Text(tr("스키마 불러오는 중…")) }
                        }
                        ForEach(app.filteredTables) { table in
                            TableNode(table: table)
                                .tag(table.name)
                        }
                    } header: {
                        HStack {
                            Text(app.selectedProfile?.kind.containerTitle ?? "DB").foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { app.currentDatabase },
                                set: { db in Task { await app.selectDatabase(db) } }
                            )) {
                                ForEach(app.databases, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Spacer()
                            if app.selectedTables.count > 1 {
                                Text(tr("%@개 선택", "\(app.selectedTables.count)")).foregroundStyle(Color.accentColor)
                            } else {
                                Text("\(app.tables.count)").foregroundStyle(.secondary)
                            }
                            Button {
                                let id = app.selectedTables.count > 1
                                    ? app.makeDiagram(names: app.selectedTables)
                                    : app.makeDiagram(focus: nil)
                                if let id { openWindow(id: "diagram", value: id) }
                            } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                            .buttonStyle(.borderless)
                            .help(app.selectedTables.count > 1
                                  ? tr("선택한 테이블 %@개로 ER 다이어그램", "\(app.selectedTables.count)")
                                  : tr("스키마 전체 ER 다이어그램 (⌘/⇧ 클릭으로 테이블을 여러 개 고르면 그 테이블만)"))
                            Button {
                                Task { await app.refreshSchema() }
                            } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help(tr("스키마 새로고침 (⇧⌘R)"))
                        }
                    }

                    ForEach(RoutineMeta.Kind.allCases, id: \.self) { kind in
                        let items = app.filteredRoutines(kind)
                        if !items.isEmpty {
                            Section("\(kind.title) \(items.count)") {
                                ForEach(items) { RoutineRow(routine: $0) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if app.state == .connected {
                Divider()
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(tr("테이블 검색"), text: $app.tableFilter)
                        .textFieldStyle(.plain)
                }
                .padding(8)
            }
        }
    }
}

struct ProfileRow: View {
    @Environment(AppState.self) private var app
    let profile: ConnectionProfile

    var body: some View {
        let selected = app.selectedProfileID == profile.id
        let state = app.connectionState(profile.id)
        let tabCount = app.tabs.filter { $0.profileID == profile.id }.count
        HStack(spacing: 6) {
            // 연결 상태: 초록 = 연결됨, 빨강 = 실패, 회색 = 안 됨
            Circle()
                .fill(state == .connected ? Color.green : (state == .disconnected ? Color.secondary.opacity(0.4) : Color.red))
                .frame(width: 7, height: 7)
                .opacity(state == .connecting ? 0 : 1)
                .overlay { if state == .connecting { ProgressView().controlSize(.mini) } }
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Text(profile.name).lineLimit(1)
            KindBadge(kind: profile.kind)
            if profile.readOnly {
                Text(tr("읽기전용")).font(.caption2).foregroundStyle(.red)
            }
            Spacer()
            if tabCount > 0 {
                Text("\(tabCount)").font(.caption2).foregroundStyle(.secondary)
                    .help(tr("이 접속의 쿼리 탭 %@개", "\(tabCount)"))
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            // 다른 접속은 끊지 않고 이 접속을 열거나 보기로 바꾼다.
            Task { await app.open(profile.id) }
        }
        .contextMenu {
            if state == .connected {
                Button(tr("새 쿼리 탭")) {
                    app.selectedProfileID = profile.id
                    app.addTab(for: profile.id)
                }
                Button(tr("다시 연결")) {
                    Task {
                        await app.disconnect(profile.id)
                        await app.connect(profile.id)
                    }
                }
                Button(tr("연결 끊기")) { Task { await app.disconnect(profile.id) } }
            } else {
                Button(tr("연결")) { Task { await app.connect(profile.id) } }
            }
            Divider()
            Button(tr("편집…")) { app.edit(profile) }
            Button(tr("복제")) { app.duplicate(profile) }
            Divider()
            Button(tr("삭제"), role: .destructive) { app.deleteProfile(profile) }
        }
    }
}

/// DB 종류 작은 표시 (MY / PG / MSSQL)
struct KindBadge: View {
    let kind: DatabaseKind

    var body: some View {
        Text(kind == .mssql ? "MSSQL" : kind == .postgres ? "PG" : "MY")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 3)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .help(kind.title)
    }

    private var color: Color {
        switch kind {
        case .mysql: return .orange
        case .postgres: return .blue
        case .mssql: return .purple
        }
    }
}

struct TableNode: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    let table: TableMeta
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(table.columns) { col in
                HStack(spacing: 4) {
                    Image(systemName: col.isPrimaryKey ? "key.fill" : "circle.fill")
                        .font(.system(size: col.isPrimaryKey ? 9 : 4))
                        .foregroundStyle(col.isPrimaryKey ? .yellow : .secondary)
                        .frame(width: 12)
                    Text(col.name).lineLimit(1)
                    Text(col.columnType).foregroundStyle(.secondary).lineLimit(1)
                    if !col.nullable { Text("NN").font(.caption2).foregroundStyle(.tertiary) }
                }
                .font(.callout)
                .help(col.comment)
            }
            if !table.indexes.isEmpty {
                DisclosureGroup {
                    ForEach(table.indexes) { idx in
                        HStack(spacing: 4) {
                            Image(systemName: idx.isPrimary ? "key" : "list.bullet.indent")
                                .font(.caption).foregroundStyle(.purple).frame(width: 12)
                            Text(idx.name).lineLimit(1)
                            Text("(\(idx.columns.joined(separator: ", ")))").foregroundStyle(.secondary).lineLimit(1)
                            if idx.unique && !idx.isPrimary { Text("UQ").font(.caption2).foregroundStyle(.tertiary) }
                        }
                        .font(.callout)
                        .help("\(idx.unique ? "UNIQUE " : "")\(idx.name) (\(idx.columns.joined(separator: ", ")))")
                    }
                } label: {
                    Label(tr("인덱스 %@", "\(table.indexes.count)"), systemImage: "list.bullet.indent")
                        .font(.callout)
                        .contextMenu {
                            Button(tr("인덱스 상세 보기")) { app.openIndexes(table.name) }
                        }
                }
            }
        } label: {
            Label(table.name, systemImage: "tablecells")
                .lineLimit(1)
                .help(table.comment.isEmpty ? table.name : table.comment)
                .contentShape(Rectangle())
                // 한 번 클릭은 목록 선택(⌘/⇧ 다중 선택)에 맡기고, 두 번 클릭만 가로챈다
                .simultaneousGesture(TapGesture(count: 2).onEnded { app.openTableQuery(table.name) })
                .contextMenu {
                    Button(tr("데이터 보기 (SELECT)")) { app.openTableQuery(table.name) }
                    Button(tr("테이블 수정 (ALTER)…")) { app.alteringTable = table }
                    Button(tr("CREATE 문 보기")) { Task { await app.openTableDDL(table) } }
                    Button(tr("인덱스 상세 보기")) { app.openIndexes(table.name) }
                    // 여러 개를 골랐고 그중 하나를 우클릭했으면 → 고른 테이블 전부 (관계 없는 테이블도 따로)
                    // 아니면 → 이 테이블 + 바로 이어진 테이블
                    let useSelection = app.selectedTables.count > 1 && app.selectedTables.contains(table.name)
                    Button(useSelection ? tr("다이어그램 보기 (선택한 %@개)", "\(app.selectedTables.count)") : tr("다이어그램 보기")) {
                        let id = useSelection ? app.makeDiagram(names: app.selectedTables) : app.makeDiagram(focus: table.name)
                        if let id { openWindow(id: "diagram", value: id) }
                    }
                    Divider()
                    Button(tr("이름 복사")) { Pasteboard.copy(table.name) }
                    Divider()
                    let readOnly = app.selectedProfile?.readOnly == true
                    Button(tr("이름 변경…")) { app.requestRename(table.name) }
                        .disabled(readOnly)
                    Button(tr("삭제 (DROP)…"), role: .destructive) { app.requestDrop(table.name) }
                        .disabled(readOnly)
                }
        }
    }
}

struct RoutineRow: View {
    @Environment(AppState.self) private var app
    let routine: RoutineMeta

    private var icon: String {
        switch routine.kind {
        case .view: return "eye"
        case .procedure: return "gearshape"
        case .function: return "function"
        case .trigger: return "bolt"
        }
    }

    var body: some View {
        Label(routine.name, systemImage: icon)
            .lineLimit(1)
            .help(routine.comment.isEmpty ? tr("더블클릭하면 정의를 열어요") : routine.comment)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { Task { await app.openRoutine(routine) } }
            .contextMenu {
                Button(tr("정의 보기")) { Task { await app.openRoutine(routine) } }
                if routine.kind == .view {
                    Button(tr("데이터 보기 (SELECT)")) { app.openTableQuery(routine.name) }
                }
                if routine.kind == .procedure {
                    Button(tr("CALL 문 만들기")) {
                        app.addTab(text: app.dialect.callSQL(routine.name), title: tr("호출 · %@", "\(routine.name)"))
                    }
                }
                Divider()
                Button(tr("이름 복사")) { Pasteboard.copy(routine.name) }
            }
    }
}
