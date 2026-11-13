import GodDBCore
import SwiftUI

/// 표에 쓰는 두 칸짜리 행
struct KVRow: Identifiable, Hashable {
    let id: Int
    let a: String
    let b: String
}

func redisTypeColor(_ t: String) -> Color {
    switch t {
    case "string": return .blue
    case "hash": return .purple
    case "list": return .orange
    case "set": return .green
    case "zset": return .pink
    case "stream": return .teal
    default: return .secondary
    }
}

func ttlText(_ ms: Int) -> String {
    if ms == -1 { return tr("만료 없음") }
    if ms == -2 { return tr("키 없음") }
    let s = ms / 1000
    if s < 60 { return tr("%@초", "\(s)") }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    return "\(s / 86400)d \((s % 86400) / 3600)h"
}

// MARK: - 사이드바

struct RedisSidebarSection: View {
    @Environment(AppState.self) private var app
    @Bindable var ws: RedisWorkspace

    var body: some View {
        Section {
            if ws.loadingKeys && ws.keys.isEmpty {
                HStack { ProgressView().controlSize(.small); Text(tr("키 불러오는 중…")) }
            }
            if ws.treeMode {
                RedisTreeRows(nodes: ws.tree, ws: ws)
            } else {
                ForEach(ws.keys, id: \.self) { key in
                    RedisKeyRow(ws: ws, key: key, label: key)
                }
            }
            if ws.nextCursor != nil {
                Button {
                    Task { await ws.loadMoreKeys() }
                } label: {
                    Label(ws.loadingKeys ? tr("불러오는 중…") : tr("키 더 불러오기"), systemImage: "ellipsis.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(ws.loadingKeys)
            } else if !ws.keys.isEmpty {
                Text(tr("키 %@개 (전부)", "\(ws.keys.count)")).font(.caption).foregroundStyle(.secondary)
            } else if !ws.loadingKeys {
                Text(tr("맞는 키가 없어요.")).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("DB").foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { ws.db }, set: { i in Task { await ws.selectDB(i) } })) {
                        ForEach(ws.databases) { d in
                            Text(d.keys > 0 ? "db\(d.index) (\(d.keys))" : "db\(d.index)").tag(d.index)
                        }
                        if !ws.databases.contains(where: { $0.index == ws.db }) { Text("db\(ws.db)").tag(ws.db) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Text("\(ws.keys.count)\(ws.nextCursor != nil ? "+" : "")").foregroundStyle(.secondary)
                    Button { ws.showNewKey = true } label: { Image(systemName: "plus") }
                        .help(tr("새 키"))
                        .disabled(ws.readOnly)
                }
                HStack(spacing: 6) {
                    // 트리 / 목록 전환
                    Picker("", selection: $ws.treeMode) {
                        Image(systemName: "list.bullet.indent").help(tr("트리")).tag(true)
                        Image(systemName: "list.bullet").help(tr("목록")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help(tr("트리 / 목록 보기"))
                    if ws.treeMode {
                        Menu {
                            Picker(tr("구분자"), selection: $ws.delimiter) {
                                ForEach([":", "/", ".", "_", "-", "|"], id: \.self) { Text("  \($0)  ").tag($0) }
                            }
                            .pickerStyle(.inline)
                            Divider()
                            Button(tr("모두 펼치기")) { ws.expanded = Set(Self.folderIDs(ws.tree)) }
                            Button(tr("모두 접기")) { ws.expanded = [] }
                        } label: {
                            Text(ws.delimiter).font(.system(.body, design: .monospaced))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(tr("폴더 구분자, 모두 펼치기/접기"))
                    }
                    Spacer()
                    Button {
                        Task { await ws.refreshAll() }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .help(tr("새로고침 (키 목록, TTL, 열린 값)"))
                    // 자동 새로고침
                    Toggle(isOn: Binding(get: { ws.autoRefresh }, set: { ws.setAutoRefresh($0) })) {
                        Image(systemName: ws.autoRefresh ? "timer.circle.fill" : "timer")
                    }
                    .toggleStyle(.button)
                    .tint(ws.autoRefresh ? .green : nil)
                    .help(tr("자동 새로고침 켜기/끄기"))
                    TextField("", value: Binding(get: { ws.autoRefreshSeconds }, set: { ws.setAutoRefreshSeconds($0) }),
                              format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 38)
                        .help(tr("자동 새로고침 간격 (초, 1~3600)"))
                    Text(tr("초")).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .textCase(nil)
            // 오른쪽 스크롤바와 겹치지 않게
            .padding(.trailing, 16)
        }
    }

    static func folderIDs(_ nodes: [RedisKeyNode]) -> [String] {
        nodes.flatMap { n in n.isFolder ? [n.id] + folderIDs(n.children ?? []) : [] }
    }
}

/// 키 한 줄
struct RedisKeyRow: View {
    let ws: RedisWorkspace
    let key: String
    let label: String

    var body: some View {
        let m = ws.meta[key]
        HStack(spacing: 6) {
            if let m {
                Text(Self.typeLetter(m.type))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(redisTypeColor(m.type))
                    .frame(width: 16, height: 14)
                    .background(redisTypeColor(m.type).opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                    .help(m.type)
            } else {
                Image(systemName: "key").font(.caption).foregroundStyle(.secondary).frame(width: 16)
            }
            Text(label.isEmpty ? "(empty)" : label).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(label.isEmpty || m?.type == "none" ? .secondary : .primary)
                .strikethrough(m?.type == "none")
            Spacer()
            if let ttl = ws.remainingTTL(key) {
                if ttl >= 0 {
                    Label(Self.shortTTL(ttl), systemImage: "timer")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(ttl < 60_000 ? .orange : .secondary)
                        .help(tr("남은 시간 %@", ttlText(ttl)))
                } else if ttl == -2 {
                    Text(tr("만료됨")).font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .onAppear { ws.wantMeta(key) }
        .contentShape(Rectangle())
        .padding(.vertical, 1)
        .background(ws.selectedKey == key ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onTapGesture { Task { await ws.open(key) } }
        .help(key)
        .contextMenu {
            Button(tr("열기")) { Task { await ws.open(key) } }
            Button(tr("이름 복사")) { Pasteboard.copy(key) }
            Divider()
            Button(tr("삭제"), role: .destructive) { Task { await ws.deleteKey(key) } }
                .disabled(ws.readOnly)
        }
    }
}

extension RedisKeyRow {
    static func typeLetter(_ t: String) -> String {
        switch t {
        case "string": return "S"
        case "hash": return "H"
        case "list": return "L"
        case "set": return "St"
        case "zset": return "Z"
        case "stream": return "X"
        case "none": return "–"
        default: return "?"
        }
    }

    /// 목록용 짧은 남은 시간: 45s, 12m, 3h, 2d
    static func shortTTL(_ ms: Int) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// 키 트리 (폴더는 펼치기/접기, 하위 키 개수 표시)
struct RedisTreeRows: View {
    let nodes: [RedisKeyNode]
    @Bindable var ws: RedisWorkspace

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(
                    get: { ws.expanded.contains(node.id) },
                    set: { if $0 { ws.expanded.insert(node.id) } else { ws.expanded.remove(node.id) } })) {
                    RedisTreeRows(nodes: children, ws: ws)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: ws.expanded.contains(node.id) ? "folder.fill" : "folder")
                            .font(.caption).foregroundStyle(Color.accentColor)
                        Text(node.name.isEmpty ? "(empty)" : node.name).lineLimit(1)
                        Spacer()
                        Text("\(node.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .help(node.path + ws.delimiter + "*")
                    .contextMenu {
                        Button(tr("이 폴더만 검색 (%@)", RedisKeyTree.pattern(forFolder: node.path, delimiter: ws.delimiter))) {
                            Task { await ws.searchFolder(node.path) }
                        }
                        Button(tr("접두어 복사")) { Pasteboard.copy(node.path + ws.delimiter) }
                    }
                }
            } else if let key = node.key {
                RedisKeyRow(ws: ws, key: key, label: node.name)
            }
        }
    }
}

/// 사이드바 아래 키 검색 (패턴 + 타입)
struct RedisKeySearchBar: View {
    @Bindable var ws: RedisWorkspace

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(tr("키 패턴 (예: user:*)"), text: $ws.pattern)
                .textFieldStyle(.plain)
                .onSubmit { Task { await ws.reloadKeys() } }
            Picker("", selection: $ws.typeFilter) {
                Text(tr("모든 타입")).tag("")
                ForEach(["string", "hash", "list", "set", "zset", "stream"], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: ws.typeFilter) { Task { await ws.reloadKeys() } }
        }
        .padding(8)
        .help(tr("SCAN MATCH 패턴. * 는 아무 글자, ? 는 한 글자. Enter 로 검색"))
    }
}

struct RedisNewKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let ws: RedisWorkspace
    @State private var type = "string"
    @State private var key = ""
    @State private var field = ""
    @State private var value = ""
    @State private var ttl = ""
    @State private var error: String?

    var fieldLabel: String? {
        switch type {
        case "hash": return tr("필드")
        case "zset": return tr("점수")
        case "stream": return tr("필드")
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(tr("새 키"), systemImage: "key").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(tr("타입")).gridColumnAlignment(.trailing)
                    Picker("", selection: $type) {
                        ForEach(["string", "hash", "list", "set", "zset", "stream"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text(tr("키"))
                    TextField("", text: $key, prompt: Text("user:1001"))
                }
                if let fieldLabel {
                    GridRow {
                        Text(fieldLabel)
                        TextField("", text: $field, prompt: Text(type == "zset" ? "0" : "name"))
                    }
                }
                GridRow(alignment: .top) {
                    Text(type == "zset" ? tr("멤버") : tr("값"))
                    TextEditor(text: $value)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                }
                GridRow {
                    Text(tr("만료 (초)"))
                    HStack {
                        TextField("", text: $ttl, prompt: Text(tr("비우면 없음"))).frame(width: 120)
                        Spacer()
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(tr("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("만들기")) {
                    Task {
                        error = await ws.create(type: type, key: key, field: field, value: value, ttl: Int(ttl))
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(key.isEmpty || (type == "hash" && field.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 작업 영역

struct RedisWorkspaceView: View {
    @Bindable var ws: RedisWorkspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $ws.tab) {
                    ForEach(RedisWorkspace.Tab.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if !ws.topologyText.isEmpty {
                    Text(ws.topologyText)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12), in: Capsule())
                        .foregroundStyle(.purple)
                        .help(ws.nodes.joined(separator: "\n"))
                }
                Text("\(ws.name) · db\(ws.db)").foregroundStyle(.secondary)
                if ws.readOnly {
                    Label(tr("읽기전용"), systemImage: "lock").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            Group {
                switch ws.tab {
                case .keys: RedisKeyView(ws: ws)
                case .console: RedisConsoleView(ws: ws)
                case .pubsub: RedisPubSubView(ws: ws)
                case .streams: RedisStreamsView(ws: ws)
                case .info: RedisInfoView(ws: ws)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 새 키 창은 여기 한 곳에만 붙인다 (목록 섹션에 붙이면 행마다 복사돼 창이 반복해서 열린다)
        .sheet(isPresented: $ws.showNewKey) { RedisNewKeySheet(ws: ws) }
    }
}

// MARK: - 키 보기 / 편집

struct RedisKeyView: View {
    @Bindable var ws: RedisWorkspace
    @State private var draft = ""
    @State private var prettyJSON = false
    @State private var selection: Set<Int> = []
    @State private var fieldInput = ""
    @State private var valueInput = ""
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var showTTL = false
    @State private var ttlInput = ""
    @State private var showRename = false
    @State private var renameInput = ""

    var body: some View {
        if let key = ws.selectedKey {
            VStack(spacing: 0) {
                header(key)
                Divider()
                if let e = ws.valueError {
                    Text(e).foregroundStyle(.red).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let v = ws.value {
                    content(key, v)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            .onChange(of: ws.selectedKey) { resetInputs() }
            .onChange(of: stringValue) { draft = stringValue ?? "" }
            .onAppear { draft = stringValue ?? "" }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "key").font(.largeTitle).foregroundStyle(.secondary)
                Text(tr("왼쪽에서 키를 고르세요.")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var stringValue: String? {
        if case .string(let s) = ws.value { return s }
        return nil
    }

    private func resetInputs() {
        selection = []
        fieldInput = ""
        valueInput = ""
        error = nil
        prettyJSON = false
    }

    private func header(_ key: String) -> some View {
        HStack(spacing: 8) {
            if let info = ws.keyInfo {
                Text(info.type).font(.caption.weight(.semibold)).foregroundStyle(redisTypeColor(info.type))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(redisTypeColor(info.type).opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            }
            Text(key).font(.headline).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            CopyButton(title: "") { key }
            Spacer()
            if let info = ws.keyInfo {
                Group {
                    Text("TTL \(ttlText(info.ttlMillis))")
                    if let n = info.length { Text(info.type == "string" ? tr("%@바이트", "\(n)") : tr("%@개", "\(n)")) }
                    if let m = info.memory { Text(ByteCountFormatter.string(fromByteCount: Int64(m), countStyle: .memory)) }
                    if let e = info.encoding { Text(e) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if ws.loadingValue { ProgressView().controlSize(.small) }
            Button { Task { await ws.reloadValue() } } label: { Image(systemName: "arrow.clockwise") }
                .help(tr("새로고침"))
            Button { ttlInput = ""; showTTL = true } label: { Image(systemName: "timer") }
                .help(tr("만료(TTL) 설정"))
                .disabled(ws.readOnly)
                .popover(isPresented: $showTTL) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("만료(TTL) 설정")).font(.headline)
                        TextField(tr("초"), text: $ttlInput).frame(width: 160)
                        HStack {
                            Button(tr("만료 없앰")) { Task { error = await ws.setTTL(key, seconds: nil); showTTL = false } }
                            Button(tr("적용")) { Task { error = await ws.setTTL(key, seconds: Int(ttlInput)); showTTL = false } }
                                .keyboardShortcut(.defaultAction)
                                .disabled(Int(ttlInput) == nil)
                        }
                    }
                    .padding(12)
                }
            Button { renameInput = key; showRename = true } label: { Image(systemName: "pencil") }
                .help(tr("이름 변경"))
                .disabled(ws.readOnly)
                .popover(isPresented: $showRename) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("이름 변경")).font(.headline)
                        TextField(tr("새 이름"), text: $renameInput).frame(width: 280)
                        Button(tr("변경")) { Task { error = await ws.renameKey(key, to: renameInput); showRename = false } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(renameInput.isEmpty || renameInput == key)
                    }
                    .padding(12)
                }
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .help(tr("키 삭제"))
                .disabled(ws.readOnly)
                .confirmationDialog(tr("키 %@ 를 삭제할까요?", key), isPresented: $confirmDelete) {
                    Button(tr("삭제"), role: .destructive) { Task { await ws.deleteKey(key) } }
                } message: { Text(tr("되돌릴 수 없어요.")) }
        }
        .buttonStyle(.hover)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(_ key: String, _ v: RedisWorkspace.Value) -> some View {
        switch v {
        case .string(let s):
            stringEditor(key, s)
        case .hash(let items):
            table(items.enumerated().map { KVRow(id: $0.offset, a: $0.element.0, b: $0.element.1) }, a: tr("필드"), b: tr("값"))
            editBar {
                TextField(tr("필드"), text: $fieldInput).frame(width: 180)
                TextField(tr("값"), text: $valueInput)
                Button(tr("저장 (HSET)")) { run(["HSET", key, fieldInput, valueInput], tr("HSET %@ %@", key, fieldInput)) }
                    .disabled(fieldInput.isEmpty)
                Button(tr("선택 삭제 (HDEL)")) {
                    let fields = selection.compactMap { i in items.indices.contains(i) ? items[i].0 : nil }
                    run(["HDEL", key] + fields, tr("HDEL %@ %@개", key, "\(fields.count)"))
                }
                .disabled(selection.isEmpty)
            }
            .onChange(of: selection) {
                if selection.count == 1, let i = selection.first, items.indices.contains(i) {
                    fieldInput = items[i].0; valueInput = items[i].1
                }
            }
        case .list(let items, let total):
            table(items.enumerated().map { KVRow(id: $0.offset, a: String($0.offset), b: $0.element) }, a: "#", b: tr("값"), aWidth: 70)
            if items.count < total {
                Button(tr("더 불러오기 (%@ / %@)", "\(items.count)", "\(total)")) { Task { await ws.loadMoreList() } }.padding(4)
            }
            editBar {
                TextField(tr("값"), text: $valueInput)
                Button("LPUSH") { run(["LPUSH", key, valueInput], "LPUSH \(key)") }
                Button("RPUSH") { run(["RPUSH", key, valueInput], "RPUSH \(key)") }
                Button(tr("선택 행 바꾸기 (LSET)")) {
                    if let i = selection.first { run(["LSET", key, String(i), valueInput], "LSET \(key) \(i)") }
                }
                .disabled(selection.count != 1)
                Button(tr("선택 값 삭제 (LREM)")) {
                    if let i = selection.first, items.indices.contains(i) { run(["LREM", key, "1", items[i]], "LREM \(key)") }
                }
                .disabled(selection.count != 1)
            }
            .onChange(of: selection) {
                if selection.count == 1, let i = selection.first, items.indices.contains(i) { valueInput = items[i] }
            }
        case .set(let items):
            table(items.enumerated().map { KVRow(id: $0.offset, a: String($0.offset + 1), b: $0.element) }, a: "#", b: tr("멤버"), aWidth: 70)
            editBar {
                TextField(tr("멤버"), text: $valueInput)
                Button(tr("추가 (SADD)")) { run(["SADD", key, valueInput], "SADD \(key)") }.disabled(valueInput.isEmpty)
                Button(tr("선택 삭제 (SREM)")) {
                    let ms = selection.compactMap { items.indices.contains($0) ? items[$0] : nil }
                    run(["SREM", key] + ms, tr("SREM %@ %@개", key, "\(ms.count)"))
                }
                .disabled(selection.isEmpty)
            }
        case .zset(let items, let total):
            table(items.enumerated().map { KVRow(id: $0.offset, a: $0.element.0, b: $0.element.1) }, a: tr("멤버"), b: tr("점수 (높은 순)"))
            if items.count < total {
                Button(tr("더 불러오기 (%@ / %@)", "\(items.count)", "\(total)")) { Task { await ws.loadMoreZset() } }.padding(4)
            }
            editBar {
                TextField(tr("멤버"), text: $fieldInput)
                TextField(tr("점수"), text: $valueInput).frame(width: 120)
                Button(tr("저장 (ZADD)")) { run(["ZADD", key, valueInput, fieldInput], "ZADD \(key)") }
                    .disabled(fieldInput.isEmpty || Double(valueInput) == nil)
                Button(tr("선택 삭제 (ZREM)")) {
                    let ms = selection.compactMap { items.indices.contains($0) ? items[$0].0 : nil }
                    run(["ZREM", key] + ms, tr("ZREM %@ %@개", key, "\(ms.count)"))
                }
                .disabled(selection.isEmpty)
            }
            .onChange(of: selection) {
                if selection.count == 1, let i = selection.first, items.indices.contains(i) {
                    fieldInput = items[i].0; valueInput = items[i].1
                }
            }
        case .stream(let entries):
            StreamEntriesTable(entries: entries)
            HStack {
                Text(tr("최근 %@개", "\(entries.count)")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Streams 탭에서 열기 (소비자 그룹, 실시간 보기)")) { Task { await ws.openStream(key) } }
            }
            .buttonStyle(.hover)
            .padding(8)
        case .other(let t):
            Text(tr("%@ 타입은 콘솔에서 다뤄 주세요.", t)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func run(_ args: [String], _ label: String) {
        Task {
            error = await ws.apply(args, label: label)
            if error == nil { selection = [] }
        }
    }

    private func table(_ rows: [KVRow], a: String, b: String, aWidth: CGFloat? = nil) -> some View {
        Table(rows, selection: $selection) {
            TableColumn(a) { r in Text(r.a).textSelection(.enabled) }
                .width(min: aWidth ?? 120, ideal: aWidth ?? 220, max: aWidth.map { $0 * 2 } ?? 600)
            TableColumn(b) { r in Text(r.b).lineLimit(3).textSelection(.enabled) }
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            Button(tr("값 복사")) {
                Pasteboard.copy(rows.filter { ids.contains($0.id) }.map(\.b).joined(separator: "\n"))
            }
            Button(tr("두 칸 복사 (탭 구분)")) {
                Pasteboard.copy(rows.filter { ids.contains($0.id) }.map { "\($0.a)\t\($0.b)" }.joined(separator: "\n"))
            }
        }
    }

    private func editBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .textFieldStyle(.roundedBorder)
            .buttonStyle(.hover)
            .disabled(ws.readOnly)
            .padding(8)
            .background(.bar)
    }

    private func stringEditor(_ key: String, _ s: String) -> some View {
        let json = Self.prettyJSON(s)
        return VStack(spacing: 0) {
            if prettyJSON, let json {
                ScrollView {
                    Text(json).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            } else {
                TextEditor(text: $draft)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            HStack {
                if json != nil {
                    Toggle(tr("JSON 보기"), isOn: $prettyJSON).toggleStyle(.checkbox)
                }
                CopyButton(title: tr("복사")) { s }
                Spacer()
                if draft != s {
                    Text(tr("바뀜")).font(.caption).foregroundStyle(.orange)
                    Button(tr("되돌리기")) { draft = s }
                }
                Button(tr("저장 (SET, TTL 유지)")) {
                    run(["SET", key, draft, "KEEPTTL"], "SET \(key)")
                }
                .disabled(draft == s || ws.readOnly || prettyJSON)
                .keyboardShortcut("s", modifiers: .command)
            }
            .buttonStyle(.hover)
            .padding(8)
            .background(.bar)
        }
    }

    static func prettyJSON(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("{") || t.hasPrefix("["), let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }
}

struct StreamEntriesTable: View {
    let entries: [RedisStreamEntry]
    @State private var selection: Set<String> = []
    var onDelete: ((Set<String>) -> Void)? = nil

    var body: some View {
        Table(entries, selection: $selection) {
            TableColumn("ID") { e in Text(e.id).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                .width(min: 150, ideal: 190, max: 260)
            TableColumn(tr("시각")) { e in Text(Self.time(e.id)).foregroundStyle(.secondary) }
                .width(min: 120, ideal: 150, max: 200)
            TableColumn(tr("필드")) { e in
                Text(e.fields.map { "\($0.0)=\($0.1)" }.joined(separator: "  ")).lineLimit(2).textSelection(.enabled)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button(tr("ID 복사")) { Pasteboard.copy(ids.sorted().joined(separator: "\n")) }
            Button(tr("JSON 으로 복사")) {
                let rows = entries.filter { ids.contains($0.id) }.map { e -> [String: Any] in
                    ["id": e.id, "fields": Dictionary(e.fields, uniquingKeysWith: { a, _ in a })]
                }
                if let d = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                    Pasteboard.copy(String(decoding: d, as: UTF8.self))
                }
            }
            if let onDelete {
                Divider()
                Button(tr("삭제 (XDEL)"), role: .destructive) { onDelete(ids) }
            }
        }
    }

    /// 스트림 ID 앞부분(밀리초)을 시각으로
    static func time(_ id: String) -> String {
        guard let ms = Double(id.split(separator: "-").first ?? "") else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

// MARK: - 콘솔

struct RedisConsoleView: View {
    @Bindable var ws: RedisWorkspace
    @State private var selection: TextSelection?
    @State private var editorHeight: CGFloat = 160

    /// 선택 영역이 있으면 그 글, 없으면 전체
    private var textToRun: String {
        if let sel = selection, case .selection(let r) = sel.indices, !r.isEmpty,
           r.lowerBound >= ws.workbench.startIndex, r.upperBound <= ws.workbench.endIndex {
            return String(ws.workbench[r])
        }
        return ws.workbench
    }

    private var hasSelection: Bool {
        if let sel = selection, case .selection(let r) = sel.indices { return !r.isEmpty }
        return false
    }

    /// 커서가 있는 줄의 명령 안내
    private var hint: String? {
        var line = ws.workbench.components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if let sel = selection, case .selection(let r) = sel.indices, r.lowerBound <= ws.workbench.endIndex {
            let before = ws.workbench[..<r.lowerBound]
            let start = before.lastIndex(of: "\n").map { ws.workbench.index(after: $0) } ?? ws.workbench.startIndex
            let end = ws.workbench[r.lowerBound...].firstIndex(of: "\n") ?? ws.workbench.endIndex
            if start <= end { line = String(ws.workbench[start..<end]) }
        }
        let first = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard !first.isEmpty, !first.hasPrefix("//"), !first.hasPrefix("#") else { return nil }
        if let h = RedisCommands.hints[first.uppercased()] { return first.uppercased() + " " + h }
        let c = RedisCommands.complete(first)
        return c.isEmpty ? nil : c.prefix(8).joined(separator: "  ")
    }

    var body: some View {
        VStack(spacing: 0) {
            // 결과
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if ws.console.isEmpty {
                            Text(tr("아래 편집기에 명령을 한 줄에 하나씩 쓰고 ⌘↩ 또는 실행을 누르세요. 선택 영역이 있으면 그 줄만 실행해요. 결과는 여기에 쌓여요. 구독은 Pub/Sub 탭에서 해요."))
                                .foregroundStyle(.secondary).font(.callout)
                        }
                        ForEach(ws.console) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("db\(e.db)> ").foregroundStyle(.secondary) + Text(e.command).bold()
                                    Spacer()
                                    if e.millis > 0 { Text("\(e.millis)ms").font(.caption).foregroundStyle(.secondary) }
                                    Button { ws.workbench += (ws.workbench.hasSuffix("\n") || ws.workbench.isEmpty ? "" : "\n") + e.command + "\n" } label: {
                                        Image(systemName: "arrow.down.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(tr("편집기에 다시 넣기"))
                                }
                                Text(e.output)
                                    .foregroundStyle(e.isError ? .red : .primary)
                                    .textSelection(.enabled)
                            }
                            .font(.system(.callout, design: .monospaced))
                            .id(e.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: ws.console.count) {
                    if let last = ws.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))

            ResizeHandle(axis: .horizontal, size: $editorHeight, range: 80...500)

            // Workbench 편집기
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        let t = textToRun
                        Task { await ws.runScript(t) }
                    } label: {
                        Label(hasSelection ? tr("선택 실행") : tr("실행"), systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(ws.consoleRunning || RedisText.scriptLines(textToRun).isEmpty)
                    .help(tr("⌘↩ · 선택 영역이 있으면 그 줄만, 없으면 전체를 위에서부터 차례로 실행"))
                    if ws.consoleRunning { ProgressView().controlSize(.small) }
                    Text("db\(ws.db)").foregroundStyle(.secondary)
                    if let hint {
                        Text(hint).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        if ws.history.isEmpty { Text(tr("아직 실행한 명령이 없어요.")) }
                        ForEach(ws.history.suffix(30).reversed(), id: \.self) { h in
                            Button(h) { ws.workbench += (ws.workbench.hasSuffix("\n") || ws.workbench.isEmpty ? "" : "\n") + h + "\n" }
                        }
                    } label: { Image(systemName: "clock.arrow.circlepath") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(tr("이전 명령을 편집기에 넣기"))
                    Button(tr("결과 지우기")) { ws.console = [] }
                }
                .buttonStyle(.hover)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                TextEditor(text: $ws.workbench, selection: $selection)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(height: editorHeight)
        }
        .confirmationDialog(tr("위험할 수 있는 명령이에요"), isPresented: Binding(
            get: { ws.pendingDangerous != nil || ws.pendingScript != nil },
            set: { if !$0 { ws.pendingDangerous = nil; ws.pendingScript = nil } })) {
            Button(tr("실행"), role: .destructive) {
                if let lines = ws.pendingScript {
                    ws.pendingScript = nil
                    Task { await ws.runScript(lines.joined(separator: "\n"), confirmed: true) }
                } else if let args = ws.pendingDangerous {
                    ws.pendingDangerous = nil
                    Task { await ws.runConsole(RedisWorkspace.display(args), confirmed: true) }
                }
            }
        } message: {
            let danger = (ws.pendingScript ?? []).filter { RedisText.splitArgs($0).map(RedisCommands.isDangerous) ?? false }
            Text(tr("%@\n\n전체 데이터를 지우거나 서버를 멈추거나(KEYS 는 운영 서버를 잠시 멈출 수 있어요) 설정을 바꾸는 명령이에요. 정말 실행할까요?",
                    danger.isEmpty ? (ws.pendingDangerous.map(RedisWorkspace.display) ?? "") : danger.joined(separator: "\n")))
        }
    }
}

// MARK: - Pub/Sub

struct RedisPubSubView: View {
    @Bindable var ws: RedisWorkspace
    @State private var subInput = ""
    @State private var pubChannel = ""
    @State private var pubMessage = ""
    @State private var filter = ""
    @State private var error: String?

    private var shown: [RedisPubSubMessage] {
        let all = ws.messages.reversed()
        guard !filter.isEmpty else { return Array(all) }
        return all.filter { $0.channel.localizedCaseInsensitiveContains(filter) || $0.payload.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    TextField(tr("채널 또는 패턴 (쉼표로 여러 개, 예: news, evt:*)"), text: $subInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { subscribe() }
                    Button(tr("구독")) { subscribe() }.disabled(subInput.isEmpty)
                }
                .padding(8)
                if !(ws.channels.isEmpty && ws.patterns.isEmpty) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(ws.channels + ws.patterns, id: \.self) { c in
                                HStack(spacing: 4) {
                                    Text(c).font(.caption)
                                    Button { ws.unsubscribe(c) } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.borderless).font(.caption)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                            Button(tr("모두 해제")) { Task { await ws.unsubscribeAll() } }.font(.caption)
                        }
                        .padding(.horizontal, 8)
                    }
                    .padding(.bottom, 6)
                }
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField(tr("메시지 거르기"), text: $filter).textFieldStyle(.plain)
                    Toggle(tr("일시 정지"), isOn: $ws.pubsubPaused).toggleStyle(.checkbox)
                    Text(tr("%@건", "\(ws.messages.filter { $0.kind.hasSuffix("message") }.count)")).foregroundStyle(.secondary)
                    Button(tr("지우기")) { ws.messages = [] }
                }
                .buttonStyle(.hover)
                .font(.callout)
                .padding(8)
                Table(shown) {
                    TableColumn(tr("시각")) { m in Text(m.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))).foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 100, max: 130)
                    TableColumn(tr("채널")) { m in
                        VStack(alignment: .leading) {
                            Text(m.channel)
                            if let p = m.pattern { Text(p).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .width(min: 100, ideal: 160, max: 300)
                    TableColumn(tr("메시지")) { m in
                        Text(m.kind.hasSuffix("message") ? m.payload : "(\(m.kind) · \(m.payload))")
                            .foregroundStyle(m.kind.hasSuffix("message") ? .primary : .secondary)
                            .lineLimit(3).textSelection(.enabled)
                    }
                }
                .overlay {
                    if ws.messages.isEmpty {
                        Text(ws.subscriber == nil ? tr("채널을 구독하면 들어오는 메시지가 여기에 실시간으로 보여요.") : tr("메시지를 기다리는 중…"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 420)

            VStack(alignment: .leading, spacing: 10) {
                Text(tr("메시지 보내기 (PUBLISH)")).font(.headline)
                TextField(tr("채널"), text: $pubChannel).textFieldStyle(.roundedBorder)
                TextEditor(text: $pubMessage)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Spacer()
                    Button(tr("보내기")) {
                        Task { error = await ws.publish(channel: pubChannel, message: pubMessage) }
                    }
                    .disabled(pubChannel.isEmpty || ws.readOnly)
                }
                if ws.readOnly { Text(tr("읽기전용 접속이라 보낼 수 없어요.")).font(.caption).foregroundStyle(.orange) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Divider()
                HStack {
                    Text(tr("활성 채널")).font(.headline)
                    Spacer()
                    Button { Task { await ws.loadActiveChannels() } } label: { Image(systemName: "arrow.clockwise") }
                }
                List(ws.activeChannels, id: \.0) { c in
                    HStack {
                        Text(c.0).lineLimit(1)
                        Spacer()
                        Text(tr("구독자 %@", "\(c.1)")).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { pubChannel = c.0 }
                    .contextMenu { Button(tr("구독")) { Task { await ws.subscribe(c.0) } } }
                }
                .overlay { if ws.activeChannels.isEmpty { Text(tr("없음")).foregroundStyle(.secondary) } }
            }
            .buttonStyle(.hover)
            .padding(10)
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
        }
        .task { await ws.loadActiveChannels() }
    }

    private func subscribe() {
        let t = subInput
        subInput = ""
        Task { await ws.subscribe(t) }
    }
}

// MARK: - Streams

struct RedisStreamsView: View {
    @Bindable var ws: RedisWorkspace
    @State private var addFields = "field=value"
    @State private var newGroup = ""
    @State private var newGroupStart = "$"
    @State private var error: String?
    @State private var pendingSelection: Set<String> = []

    var body: some View {
        HSplitView {
            // 스트림 목록
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(tr("스트림")).font(.headline)
                    Spacer()
                    Button { Task { await ws.loadStreamKeys() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }
                .padding(8)
                List(ws.streamKeys, id: \.self, selection: Binding(get: { ws.stream }, set: { k in if let k { Task { await ws.openStream(k) } } })) { k in
                    Text(k).lineLimit(1).truncationMode(.middle).tag(k)
                }
                .overlay { if ws.streamKeys.isEmpty { Text(tr("스트림이 없어요.")).foregroundStyle(.secondary).font(.callout) } }
            }
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 320)

            if let key = ws.stream {
                VSplitView {
                    entriesPane(key).frame(minHeight: 200)
                    groupsPane(key).frame(minHeight: 160)
                }
                .frame(minWidth: 500)
            } else {
                Text(tr("왼쪽에서 스트림을 고르세요.")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if ws.streamKeys.isEmpty { await ws.loadStreamKeys() } }
    }

    private func entriesPane(_ key: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(key).font(.headline).lineLimit(1)
                ForEach(ws.streamInfo.filter { ["length", "groups", "last-generated-id"].contains($0.0) }, id: \.0) { kv in
                    Text("\(kv.0) \(kv.1)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: Binding(get: { ws.tailing }, set: { _ in ws.toggleTail() })) {
                    Label(tr("실시간 보기"), systemImage: ws.tailing ? "dot.radiowaves.left.and.right" : "pause")
                }
                .toggleStyle(.button)
                .tint(ws.tailing ? .green : nil)
                .help(tr("XREAD BLOCK 으로 새로 들어오는 항목을 위에 계속 붙여요 (별도 연결)"))
                Button { Task { await ws.reloadStream() } } label: { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.hover)
            .padding(8)
            StreamEntriesTable(entries: ws.streamEntries, onDelete: ws.readOnly ? nil : { ids in
                Task { error = await ws.streamWrite(["XDEL", key] + ids.sorted(), label: tr("XDEL %@ %@개", key, "\(ids.count)")) }
            })
            HStack(spacing: 8) {
                if ws.streamHasMore {
                    Button(tr("이전 항목 더 보기")) { Task { await ws.loadOlderStream() } }
                }
                Text(tr("%@개 표시 (최신순)", "\(ws.streamEntries.count)")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField(tr("field=value field2=value2"), text: $addFields)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Button(tr("추가 (XADD)")) {
                    guard let pairs = Self.parsePairs(addFields) else { error = tr("field=value 형식으로 넣어 주세요."); return }
                    Task { error = await ws.streamWrite(["XADD", key, "*"] + pairs.flatMap { [$0.0, $0.1] }, label: "XADD \(key)") }
                }
                .disabled(ws.readOnly)
            }
            .buttonStyle(.hover)
            .padding(8)
            .background(.bar)
            if let e = error ?? ws.streamError {
                Text(e).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.bottom, 4)
            }
        }
    }

    private func groupsPane(_ key: String) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tr("소비자 그룹")).font(.headline)
                    Spacer()
                }
                Table(ws.groups, selection: Binding(get: { Set(ws.group.map { [$0] } ?? []) },
                                                    set: { s in ws.group = s.first; Task { await ws.reloadGroup() } })) {
                    TableColumn(tr("그룹")) { g in Text(g.name) }
                    TableColumn(tr("소비자")) { g in Text("\(g.consumers)") }.width(50)
                    TableColumn(tr("대기")) { g in Text("\(g.pending)").foregroundStyle(g.pending > 0 ? .orange : .secondary) }.width(50)
                    TableColumn("Lag") { g in Text(g.lag.map(String.init) ?? "-") }.width(50)
                    TableColumn(tr("마지막 전달 ID")) { g in Text(g.lastDeliveredID).font(.system(.caption, design: .monospaced)) }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let g = ids.first, !ws.readOnly {
                        Button(tr("처음부터 다시 읽기 (SETID 0)")) {
                            Task { error = await ws.streamWrite(["XGROUP", "SETID", key, g, "0"], label: "XGROUP SETID \(key) \(g) 0") }
                        }
                        Button(tr("그룹 삭제 (DESTROY)"), role: .destructive) {
                            Task { error = await ws.streamWrite(["XGROUP", "DESTROY", key, g], label: "XGROUP DESTROY \(key) \(g)") }
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField(tr("새 그룹"), text: $newGroup).textFieldStyle(.roundedBorder)
                    Picker("", selection: $newGroupStart) {
                        Text(tr("새 항목부터 ($)")).tag("$")
                        Text(tr("처음부터 (0)")).tag("0")
                    }
                    .labelsHidden().fixedSize()
                    Button(tr("만들기")) {
                        Task {
                            error = await ws.streamWrite(["XGROUP", "CREATE", key, newGroup, newGroupStart], label: "XGROUP CREATE \(key) \(newGroup)")
                            if error == nil { newGroup = "" }
                        }
                    }
                    .disabled(newGroup.isEmpty || ws.readOnly)
                }
                .buttonStyle(.hover)
            }
            .padding(8)
            .frame(minWidth: 320)

            VStack(alignment: .leading, spacing: 6) {
                Text(ws.group.map { tr("%@ · 소비자 / 대기 중 (PEL)", $0) } ?? tr("그룹을 고르세요")).font(.headline)
                Table(ws.consumers) {
                    TableColumn(tr("소비자")) { c in Text(c.name) }
                    TableColumn(tr("대기")) { c in Text("\(c.pending)") }.width(50)
                    TableColumn(tr("유휴")) { c in Text(ttlText(c.idleMillis)) }.width(80)
                }
                .frame(minHeight: 70, maxHeight: 120)
                Table(ws.pending, selection: $pendingSelection) {
                    TableColumn("ID") { p in Text(p.id).font(.system(.caption, design: .monospaced)) }
                    TableColumn(tr("소비자")) { p in Text(p.consumer) }
                    TableColumn(tr("유휴")) { p in Text(ttlText(p.idleMillis)) }.width(80)
                    TableColumn(tr("전달 횟수")) { p in Text("\(p.deliveries)").foregroundStyle(p.deliveries > 3 ? .red : .primary) }.width(60)
                }
                HStack {
                    Spacer()
                    Button(tr("선택 항목 처리 완료 (XACK)")) {
                        guard let g = ws.group else { return }
                        Task {
                            error = await ws.streamWrite(["XACK", key, g] + pendingSelection.sorted(), label: tr("XACK %@ %@ %@개", key, g, "\(pendingSelection.count)"))
                            pendingSelection = []
                        }
                    }
                    .disabled(pendingSelection.isEmpty || ws.readOnly)
                }
                .buttonStyle(.hover)
            }
            .padding(8)
            .frame(minWidth: 320)
        }
    }

    /// "a=1 b=hello" → [(a, 1), (b, hello)]
    static func parsePairs(_ s: String) -> [(String, String)]? {
        guard let args = RedisText.splitArgs(s), !args.isEmpty else { return nil }
        var out: [(String, String)] = []
        for a in args {
            guard let i = a.firstIndex(of: "="), i != a.startIndex else { return nil }
            out.append((String(a[..<i]), String(a[a.index(after: i)...])))
        }
        return out
    }
}

// MARK: - 서버 정보

struct RedisInfoView: View {
    @Bindable var ws: RedisWorkspace
    @State private var filter = ""

    private static let highlights = ["redis_version", "redis_mode", "os", "uptime_in_days", "connected_clients", "used_memory_human",
                                     "maxmemory_human", "maxmemory_policy", "role", "connected_slaves", "total_commands_processed",
                                     "instantaneous_ops_per_sec", "keyspace_hits", "keyspace_misses", "expired_keys", "evicted_keys"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(Self.highlights.prefix(ws.nodes.count > 1 ? 6 : 8), id: \.self) { k in
                    if let v = value(k) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(k).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text(v).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        }
                        .fixedSize(horizontal: k != "os", vertical: false)
                        .padding(.trailing, 10)
                    }
                }
                Spacer()
                if ws.nodes.count > 1 {
                    Picker(tr("노드"), selection: Binding(get: { ws.infoNode ?? ws.nodes.first ?? "" },
                                                        set: { ws.infoNode = $0; Task { await ws.loadInfo() } })) {
                        ForEach(ws.nodes, id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                }
                TextField(tr("찾기"), text: $filter).textFieldStyle(.roundedBorder).frame(width: 160)
                Button { Task { await ws.loadInfo() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.hover)
            }
            .padding(10)
            Divider()
            List {
                ForEach(ws.info, id: \.0) { section in
                    let items = section.1.filter { filter.isEmpty || $0.0.localizedCaseInsensitiveContains(filter) || $0.1.localizedCaseInsensitiveContains(filter) }
                    if !items.isEmpty {
                        Section(section.0) {
                            ForEach(items, id: \.0) { kv in
                                HStack(alignment: .top) {
                                    Text(kv.0).foregroundStyle(Self.highlights.contains(kv.0) ? Color.accentColor : .primary)
                                        .frame(width: 260, alignment: .leading)
                                    Text(kv.1).textSelection(.enabled)
                                }
                                .font(.system(.callout, design: .monospaced))
                            }
                        }
                    }
                }
            }
        }
        .task { if ws.info.isEmpty { await ws.loadInfo() } }
    }

    private func value(_ key: String) -> String? {
        for s in ws.info { if let v = s.1.first(where: { $0.0 == key }) { return v.1 } }
        return nil
    }
}
