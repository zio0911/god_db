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
                    Group {
                        switch app.mode {
                        case .query: QueryWorkspaceView()
                        case .compare: CompareView()
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
                Picker("모드", selection: $app.mode) {
                    Label("쿼리", systemImage: "terminal").tag(MainMode.query)
                    Label("스키마 비교", systemImage: "arrow.left.arrow.right").tag(MainMode.compare)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
            }
        }
        .sheet(item: $app.editingProfile) { profile in
            ConnectionEditorView(profile: profile, isNew: app.editingIsNew)
        }
        .sheet(item: $app.alteringTable) { table in
            TableEditorView(table: table)
        }
        .sheet(item: $app.passwordPrompt) { prompt in
            PasswordPromptView(prompt: prompt)
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
                    Text("읽기전용").font(.caption2).foregroundStyle(.red).padding(.horizontal, 4)
                        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            case .connecting:
                ProgressView().controlSize(.small)
                Text("연결 중…")
            case .failed:
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("연결 실패")
            case .disconnected:
                Circle().fill(.secondary).frame(width: 8, height: 8)
                Text("연결 안 됨").foregroundStyle(.secondary)
            }
            if app.connectedCount > 1 {
                Text("· 열린 접속 \(app.connectedCount)개").foregroundStyle(.secondary)
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
            Label("\(prompt.profile.name) 비밀번호", systemImage: "key").font(.headline)
            Text("\(prompt.profile.username)@\(prompt.profile.host):\(String(prompt.profile.port))")
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            if let message = prompt.message {
                Text(message).foregroundStyle(.red).font(.callout)
            }
            SecureField("비밀번호", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Toggle("macOS 키체인에 비밀번호 저장", isOn: $save)
            Text(save ? "다음부터는 묻지 않고 바로 연결해요." : "앱을 끄기 전까지만 기억하고, 다음 실행 때 다시 물어봐요.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { app.passwordPrompt = nil }
                    .keyboardShortcut(.cancelAction)
                Button("연결", action: submit)
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
