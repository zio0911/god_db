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

    func renameGroup(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !old.isEmpty, old != n else { return }
        for i in profiles.indices where profiles[i].group == old { profiles[i].group = n }
        persist()
        log(.info, .app, n.isEmpty ? tr("%@ 그룹을 풀었어요", old) : tr("%@ 그룹 이름을 %@ 로 바꿨어요", old, n))
    }
}

/// 사이드바 접속 목록: 그룹 없는 접속 먼저, 그다음 그룹별로 접었다 펼 수 있게
struct ProfileList: View {
    @Environment(AppState.self) private var app
    /// 접힌 그룹 (줄바꿈으로 구분해 저장)
    @AppStorage("GodDB.sidebar.collapsedGroups") private var collapsedRaw = ""

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }

    private func setExpanded(_ group: String, _ expanded: Bool) {
        var c = collapsed
        if expanded { c.remove(group) } else { c.insert(group) }
        collapsedRaw = c.sorted().joined(separator: "\n")
    }

    var body: some View {
        ForEach(app.profiles.filter { $0.group.isEmpty }) { ProfileRow(profile: $0) }
        ForEach(app.profileGroups, id: \.self) { group in
            let members = app.profiles.filter { $0.group == group }
            DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(group) },
                                                set: { setExpanded(group, $0) })) {
                ForEach(members) { ProfileRow(profile: $0) }
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
        }
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
