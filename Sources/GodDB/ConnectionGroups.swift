import GodDBCore
import SwiftUI

/// 접속 그룹 이름 입력창 (새 그룹으로 옮기기 / 그룹 이름 바꾸기)
struct GroupPrompt: Identifiable {
    enum Action { case move(UUID), rename(String) }
    let id = UUID()
    let action: Action
    var initial: String {
        if case .rename(let old) = action { return old }
        return ""
    }
}

extension AppState {
    /// 이름순 그룹 목록 (비어 있는 그룹 이름은 없음)
    var profileGroups: [String] {
        Array(Set(profiles.map(\.group).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func moveProfile(_ id: UUID, toGroup group: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        let g = group.trimmingCharacters(in: .whitespaces)
        guard profiles[i].group != g else { return }
        profiles[i].group = g
        persist()
        log(.info, .app, g.isEmpty ? tr("%@ 접속을 그룹에서 뺐어요", profiles[i].name)
                                   : tr("%@ 접속을 %@ 그룹으로 옮겼어요", profiles[i].name, g))
    }

    /// 접속 순서 직접 바꾸기 (우클릭 > 순서 바꾸기)
    func reorderProfile(_ id: UUID, _ move: ConnectionListOrder.Move) {
        freezeVisibleOrder()
        let next = ConnectionListOrder.moved(profiles, id, move)
        guard next.map(\.id) != profiles.map(\.id) else { return }
        profiles = next
        persist()
    }

    /// 끌어다 놓기: 놓은 접속 바로 앞으로, 그 접속의 그룹으로
    func reorderProfile(_ id: UUID, before target: UUID) {
        freezeVisibleOrder()
        let next = ConnectionListOrder.moved(profiles, id, before: target)
        guard next.map(\.id) != profiles.map(\.id) || next.map(\.group) != profiles.map(\.group) else { return }
        profiles = next
        persist()
    }

    /// 다른 정렬로 보고 있으면, 지금 보이는 순서를 저장 순서로 굳히고 "직접 정한 순" 으로 바꾼다
    /// (보이는 그대로에서 옮겨야 헷갈리지 않는다)
    private func freezeVisibleOrder() {
        let d = UserDefaults.standard
        let sort = d.string(forKey: ConnectionListKeys.sort).flatMap(ConnectionSort.init(rawValue:)) ?? .manual
        let connectedFirst = d.bool(forKey: ConnectionListKeys.connectedFirst)
        guard sort != .manual || connectedFirst else { return }
        profiles = ConnectionListOrder.visibleOrder(profiles, by: sort, connectedFirst: connectedFirst,
                                                    isConnected: { connectionState($0) == .connected })
        d.set(ConnectionSort.manual.rawValue, forKey: ConnectionListKeys.sort)
        d.set(false, forKey: ConnectionListKeys.connectedFirst)
    }

    /// 연결 성공 시각 기록 (사이드바 "최근 연결순")
    func noteConnected(_ id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].lastConnectedAt = Date()
        persist()
    }

    func renameGroup(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !old.isEmpty, old != n else { return }
        for i in profiles.indices where profiles[i].group == old { profiles[i].group = n }
        persist()
        log(.info, .app, n.isEmpty ? tr("%@ 그룹을 풀었어요", old) : tr("%@ 그룹 이름을 %@ 로 바꿨어요", old, n))
    }
}

/// 사이드바 접속 목록 정렬 · 찾기 설정 키
enum ConnectionListKeys {
    static let sort = "GodDB.sidebar.connectionSort"
    static let connectedFirst = "GodDB.sidebar.connectedFirst"
}

/// "접속" 제목 오른쪽 정렬 메뉴
struct ConnectionSortMenu: View {
    @AppStorage(ConnectionListKeys.sort) private var sortRaw = ConnectionSort.manual.rawValue
    @AppStorage(ConnectionListKeys.connectedFirst) private var connectedFirst = false

    var body: some View {
        let sort = ConnectionSort(rawValue: sortRaw) ?? .manual
        Menu {
            Picker(tr("접속 목록 정렬"), selection: $sortRaw) {
                ForEach(ConnectionSort.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Toggle(tr("연결된 접속 먼저"), isOn: $connectedFirst)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(sort.title)
            }
            .font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("접속 목록 정렬"))
    }
}

/// 사이드바 접속 목록: 찾기 칸, 그룹 없는 접속 먼저, 그다음 그룹별로 접었다 펼 수 있게 (정렬 메뉴를 따른다)
struct ProfileList: View {
    @Environment(AppState.self) private var app
    /// 접힌 그룹 (줄바꿈으로 구분해 저장)
    @AppStorage("GodDB.sidebar.collapsedGroups") private var collapsedRaw = ""
    @AppStorage(ConnectionListKeys.sort) private var sortRaw = ConnectionSort.manual.rawValue
    @AppStorage(ConnectionListKeys.connectedFirst) private var connectedFirst = false
    @State private var query = ""

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }

    private func setExpanded(_ group: String, _ expanded: Bool) {
        var c = collapsed
        if expanded { c.remove(group) } else { c.insert(group) }
        collapsedRaw = c.sorted().joined(separator: "\n")
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let sort = ConnectionSort(rawValue: sortRaw) ?? .manual
        let shown = ConnectionListOrder.sorted(app.profiles.filter { ConnectionListOrder.matches($0, query: query) },
                                               by: sort, connectedFirst: connectedFirst,
                                               isConnected: { app.connectionState($0) == .connected })
        let groups = ConnectionListOrder.sortedGroups(app.profiles, by: sort)
            .filter { g in shown.contains { $0.group == g } }
        if !app.profiles.isEmpty {
            ConnectionSearchField(query: $query)
                .selectionDisabled()
        }
        // 접속 · 그룹 줄은 목록 선택(테이블 여러 개 고르기)에 끼지 않는다. 접속 강조는 ProfileRow 가 직접 그린다
        ForEach(shown.filter { $0.group.isEmpty }) { ProfileRow(profile: $0).selectionDisabled() }
        ForEach(groups, id: \.self) { group in
            let members = shown.filter { $0.group == group }
            // 찾는 중에는 걸린 접속이 보이게 그룹을 펼친다 (접어 둔 상태는 그대로 둔다)
            DisclosureGroup(isExpanded: Binding(get: { searching || !collapsed.contains(group) },
                                                set: { if !searching { setExpanded(group, $0) } })) {
                ForEach(members) { ProfileRow(profile: $0).selectionDisabled() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor.opacity(0.8))
                    Text(group).fontWeight(.medium).lineLimit(1)
                    let connected = members.filter { app.connectionState($0.id) == .connected }.count
                    Spacer()
                    if connected > 0 {
                        Text("\(connected)").font(.caption2).foregroundStyle(.green)
                            .help(tr("연결된 접속 %@개", "\(connected)"))
                    }
                    Text("\(members.count)").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button(tr("그룹 이름 바꾸기…")) { app.groupPrompt = GroupPrompt(action: .rename(group)) }
                    Button(tr("그룹 풀기 (접속은 남아요)")) { app.renameGroup(group, to: "") }
                }
                .dropDestination(for: String.self) { items, _ in
                    for s in items { if let id = UUID(uuidString: s) { app.moveProfile(id, toGroup: group) } }
                    return !items.isEmpty
                }
            }
            // 그룹 이름이 꼬리표가 되어 선택되는 것을 막는다 (하위 접속을 눌렀는데 그룹 전체가 선택돼 보이던 문제)
            .selectionDisabled()
        }
        if searching {
            Text(shown.isEmpty ? tr("찾는 접속이 없어요") : tr("%@개 중 %@개", "\(app.profiles.count)", "\(shown.count)"))
                .font(.caption2).foregroundStyle(.secondary)
                .selectionDisabled()
        }
    }
}

/// 접속 찾기 칸 (esc 로 지움)
struct ConnectionSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(tr("접속 찾기 (이름 · 주소 · DB · 그룹)"), text: $query)
                .textFieldStyle(.plain)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(tr("지우기"))
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 접속 우클릭 메뉴의 "그룹으로 이동"
struct ProfileGroupMenu: View {
    @Environment(AppState.self) private var app
    let profile: ConnectionProfile

    var body: some View {
        Menu(tr("그룹으로 이동")) {
            ForEach(app.profileGroups.filter { $0 != profile.group }, id: \.self) { g in
                Button(g) { app.moveProfile(profile.id, toGroup: g) }
            }
            if !app.profileGroups.filter({ $0 != profile.group }).isEmpty { Divider() }
            Button(tr("새 그룹…")) { app.groupPrompt = GroupPrompt(action: .move(profile.id)) }
            if !profile.group.isEmpty {
                Button(tr("그룹에서 빼기")) { app.moveProfile(profile.id, toGroup: "") }
            }
        }
    }
}

/// 그룹 이름 입력 시트
struct GroupPromptView: View {
    @Environment(AppState.self) private var app
    let prompt: GroupPrompt
    @State private var name: String

    init(prompt: GroupPrompt) {
        self.prompt = prompt
        _name = State(initialValue: prompt.initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .rename = prompt.action {
                Label(tr("그룹 이름 바꾸기"), systemImage: "folder").font(.headline)
            } else {
                Label(tr("새 그룹"), systemImage: "folder.badge.plus").font(.headline)
            }
            TextField(tr("그룹 이름 (예: 운영, 개발, 프로젝트명)"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button(tr("취소")) { app.groupPrompt = nil }.keyboardShortcut(.cancelAction)
                Button(tr("확인"), action: submit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func submit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        switch prompt.action {
        case .move(let id): app.moveProfile(id, toGroup: n)
        case .rename(let old): app.renameGroup(old, to: n)
        }
        app.groupPrompt = nil
    }
}
