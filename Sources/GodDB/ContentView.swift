import GodDBCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var logHeight: CGFloat = 220

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 520)
        } detail: {
            // VSplitView(NSSplitView) 를 쓰면 사이드바 경계 드래그가 꼬여서 직접 만든 경계선을 쓴다.
            GeometryReader { geo in
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Group {
                            switch app.mode {
                            case .query:
                                if let ws = app.selectedRedis {
                                    RedisWorkspaceView(ws: ws)
                                } else {
                                    QueryWorkspaceView()
                                }
                            case .compare: CompareView()
                            case .modeling: ModelingView()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        if app.assistant.visible {
                            ResizeHandle(axis: .vertical, size: Binding(get: { app.assistant.width }, set: { app.assistant.width = $0 }),
                                         range: 320...max(320, min(760, geo.size.width - 420)))
                            AssistantPanel()
                                .frame(width: min(app.assistant.width, max(320, geo.size.width - 420)))
                        }
                    }
                    .frame(maxHeight: .infinity)

                    if app.showLog {
                        let maxLog = max(120, geo.size.height - 260)
                        ResizeHandle(axis: .horizontal, size: $logHeight, range: 100...maxLog)
                        LogPanelView()
                            .frame(height: min(logHeight, maxLog))
                    }
                    Divider()
                    MainStatusBar()
                }
            }
            .frame(minWidth: 520)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionBadge()
            }
            ToolbarItem(placement: .principal) {
                // Redis 는 스키마가 없어서 스키마 비교를 쓸 수 없다
                let isRedis = app.selectedProfile?.kind == .redis
                Picker(tr("모드"), selection: Binding(get: { app.mode },
                                                     set: { if !(isRedis && $0 == .compare) { app.mode = $0 } })) {
                    Label(tr("쿼리"), systemImage: "terminal").tag(MainMode.query)
                    Label(tr("스키마 비교"), systemImage: "arrow.left.arrow.right")
                        .foregroundStyle(isRedis ? .tertiary : .primary)
                        .tag(MainMode.compare)
                    Label(tr("모델링"), systemImage: "square.3.layers.3d").tag(MainMode.modeling)
                }
                .help(isRedis ? tr("Redis 는 스키마 비교를 지원하지 않아요.") : tr("쿼리 / 스키마 비교 / 모델링"))
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { app.assistant.visible.toggle() }
                } label: {
                    Label(tr("AI 어시스턴트"), systemImage: "sparkles")
                        .foregroundStyle(app.assistant.visible ? Color.purple : Color.primary)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .help(tr("AI 어시스턴트 열기/닫기 (⇧⌘I) · 테이블 정보·특이사항·SQL 을 로컬 Ollama 와 대화"))
            }
        }
        .onChange(of: app.selectedProfileID) {
            if app.selectedProfile?.kind == .redis, app.mode == .compare { app.mode = .query }
        }
        .sheet(item: $app.editingProfile) { profile in
            ConnectionEditorView(profile: profile, isNew: app.editingIsNew)
        }
        .sheet(item: $app.alteringTable) { table in
            TableEditorView(table: table)
        }
        .sheet(item: $app.exportRequest) { request in
            ExportSheet(request: request, onCancel: { app.exportRequest = nil },
                        onContinue: { app.continueExport(request, $0) })
        }
        .sheet(item: $app.editApply) { request in
            EditApplySheet(request: request)
        }
        .sheet(item: $app.tableAction) { request in
            TableActionSheet(request: request)
        }
        .sheet(item: $app.tuningJob) { job in
            TuningSheet(job: job)
        }
        .sheet(item: $app.passwordPrompt) { prompt in
            PasswordPromptView(prompt: prompt)
        }
        .sheet(isPresented: $app.showExportConnections) {
            ExportConnectionsSheet()
        }
        .sheet(item: $app.importRequest) { request in
            ImportConnectionsSheet(request: request)
        }
        .sheet(item: $app.groupPrompt) { prompt in
            GroupPromptView(prompt: prompt)
        }
    }
}

struct ConnectionBadge: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            switch app.state {
            case .connected:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(app.selectedProfile?.name ?? "")
                if app.selectedProfile?.ssh != nil {
                    Text("SSH").font(.caption2).padding(.horizontal, 4)
                        .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
                if app.selectedProfile?.readOnly == true {
                    Text(tr("읽기전용")).font(.caption2).foregroundStyle(.red).padding(.horizontal, 4)
                        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            case .connecting:
                ProgressView().controlSize(.small)
                Text(tr("연결 중…"))
            case .failed:
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(tr("연결 실패"))
            case .disconnected:
                Circle().fill(.secondary).frame(width: 8, height: 8)
                Text(tr("연결 안 됨")).foregroundStyle(.secondary)
            }
            if app.connectedCount > 1 {
                Text(tr("· 열린 접속 %@개", "\(app.connectedCount)")).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

/// 비밀번호를 저장하지 않는 접속이거나, 저장된 비밀번호가 틀렸을 때 뜨는 입력창
struct PasswordPromptView: View {
    @Environment(AppState.self) private var app
    let prompt: PasswordPrompt
    @State private var password = ""
    @State private var save: Bool

    init(prompt: PasswordPrompt) {
        self.prompt = prompt
        _save = State(initialValue: prompt.profile.savePassword)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("%@ 비밀번호", "\(prompt.profile.name)"), systemImage: "key").font(.headline)
            Text("\(prompt.profile.username)@\(prompt.profile.host):\(String(prompt.profile.port))")
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            if let message = prompt.message {
                Text(message).foregroundStyle(.red).font(.callout)
            }
            SecureField(tr("비밀번호"), text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Toggle(tr("macOS 키체인에 비밀번호 저장"), isOn: $save)
            Text(save ? tr("다음부터는 묻지 않고 바로 연결해요.") : tr("앱을 끄기 전까지만 기억하고, 다음 실행 때 다시 물어봐요."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(tr("취소")) { app.passwordPrompt = nil }
                    .keyboardShortcut(.cancelAction)
                Button(tr("연결"), action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func submit() {
        app.submitPassword(password, save: save, for: prompt.profile)
    }
}
