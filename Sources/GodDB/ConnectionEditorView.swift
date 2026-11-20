import GodDBCore
import SwiftUI

struct ConnectionEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State var profile: ConnectionProfile
    let isNew: Bool

    @State private var password = ""
    @State private var passwordChanged = false
    @State private var useSSH = false
    @State private var ssh = SSHConfig()
    @State private var testing = false
    @State private var testMessage: (ok: Bool, text: String)?
    @State private var hasSavedPassword = false
    /// 칸에 들어 있는 값이 아직 저장된 비밀번호에서 온 것인지 (칸을 한 번 완전히 비우면 false).
    /// 한 글자만 지우고 보기를 눌러 본인 확인을 건너뛰지 못하게 한다.
    @State private var showsSavedPassword = false
    /// 연결 테스트에서 만난 인증서 · SSH 호스트 키 확인 창 (F9-3 · F9-4)
    @State private var securityPrompt: EditorSecurityPrompt?

    init(profile: ConnectionProfile, isNew: Bool) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
        _useSSH = State(initialValue: profile.ssh != nil)
        _ssh = State(initialValue: profile.ssh ?? SSHConfig())
        let saved = Keychain.password(for: profile.id)
        _password = State(initialValue: saved ?? "")
        _hasSavedPassword = State(initialValue: saved != nil)
        _showsSavedPassword = State(initialValue: saved != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(tr("일반")) {
                    Picker(tr("DB 종류"), selection: Binding(
                        get: { profile.kind },
                        set: { kind in
                            // 포트가 이전 종류의 기본값이면 새 종류의 기본값으로 바꾼다.
                            if profile.port == profile.kind.defaultPort { profile.port = kind.defaultPort }
                            profile.kind = kind
                        }
                    )) {
                        ForEach(DatabaseKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField(tr("이름"), text: $profile.name)
                    HStack {
                        TextField(tr("그룹"), text: $profile.group, prompt: Text(tr("비우면 그룹 없음")))
                        if !app.profileGroups.isEmpty {
                            Menu {
                                ForEach(app.profileGroups, id: \.self) { g in Button(g) { profile.group = g } }
                                Divider()
                                Button(tr("그룹 없음")) { profile.group = "" }
                            } label: { Image(systemName: "folder") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help(tr("기존 그룹에서 고르기"))
                        }
                    }
                    Toggle(profile.kind == .redis ? tr("읽기전용 (조회 명령만 허용)") : tr("읽기전용 (SELECT / SHOW / DESC / EXPLAIN 만 허용)"), isOn: $profile.readOnly)
                    Picker(tr("환경"), selection: $profile.environment) {
                        ForEach(ConnectionEnvironment.allCases) { Text($0.title).tag($0) }
                    }
                    if profile.environment == .production {
                        Text(tr("운영 접속은 사이드바 · 탭에 빨간색으로 표시하고, 데이터를 바꾸는 문장을 실행하기 전에 항상 확인해요."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if profile.readOnly && profile.kind == .mssql {
                        // SQL Server 는 세션 읽기전용이 없어 서버에서 강제할 수 없다 (MySQL · PostgreSQL 은 세션 READ ONLY 로 이중 차단)
                        Label(tr("SQL Server 는 앱에서만 막아요(서버에서 강제되지 않음). 운영 DB 는 읽기 권한만 있는 DB 계정을 쓰세요."),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if profile.kind == .mssql {
                        // FreeTDS(DB-Library) 는 인증서 · 지문 확인을 할 수 없어 암호화만 강제한다 (F9-3)
                        Label(tr("SQL Server 는 암호화만 하고 서버 인증서는 확인하지 못해요. 외부망에서는 SSH 터널이나 VPN 을 쓰세요."),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section(profile.kind.title) {
                    if profile.kind == .redis {
                        Picker(tr("방식"), selection: Binding(get: { profile.redisMode }, set: { mode in
                            // 센티널 기본 포트 26379 ↔ 6379
                            if mode == .sentinel, profile.port == 6379 { profile.port = 26379 }
                            if mode != .sentinel, profile.port == 26379 { profile.port = 6379 }
                            profile.redisMode = mode
                        })) {
                            ForEach(RedisMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(redisModeHelp).font(.caption).foregroundStyle(.secondary)
                    }
                    TextField(profile.kind == .redis && profile.redisMode == .sentinel ? tr("센티널 호스트") : tr("호스트"),
                              text: $profile.host,
                              prompt: Text(profile.kind == .redis && profile.redisMode == .sentinel ? "s1:26379, s2:26379" : "xxx.rds.amazonaws.com"))
                    TextField(tr("포트"), value: $profile.port, format: .number.grouping(.never))
                    if profile.kind == .redis && profile.redisMode == .sentinel {
                        TextField(tr("마스터 이름"), text: $profile.sentinelMaster, prompt: Text("mymaster"))
                    }
                    TextField(profile.kind == .redis ? tr("ACL 사용자 (선택)") : tr("사용자"), text: $profile.username,
                              prompt: profile.kind == .redis ? Text(tr("비우면 비밀번호만으로 AUTH")) : nil)
                    PasswordField(title: tr("비밀번호"), text: $password,
                                  needsAuthentication: showsSavedPassword,
                                  authenticationReason: tr("'%@' 접속의 저장된 비밀번호를 보려고 해요", "\(profile.name)"),
                                  onAuthenticatedReveal: {
                                      app.log(.info, .app, tr("%@ 저장된 비밀번호 보기 (본인 확인)", "\(profile.name)"),
                                              audit: AuditRecord(.settings, target: profile.name, result: "저장된 비밀번호 보기"))
                                  })
                        .onChange(of: password) {
                            passwordChanged = true
                            if password.isEmpty { showsSavedPassword = false }
                        }
                    Toggle(tr("비밀번호 저장 (macOS 키체인)"), isOn: $profile.savePassword)
                    if profile.savePassword {
                        HStack(spacing: 6) {
                            Image(systemName: hasSavedPassword ? "checkmark.seal.fill" : "seal")
                                .foregroundStyle(hasSavedPassword ? .green : .secondary)
                            Text(hasSavedPassword ? tr("키체인에 저장된 비밀번호가 있어요.") : tr("저장된 비밀번호가 없어요. 입력 후 저장하면 키체인에 보관돼요."))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if hasSavedPassword {
                                Button(tr("저장된 비밀번호 지우기")) {
                                    Keychain.deletePassword(for: profile.id)
                                    password = ""
                                    hasSavedPassword = false
                                    showsSavedPassword = false
                                }
                                .controlSize(.small)
                            }
                        }
                    } else {
                        Text(tr("연결할 때마다 비밀번호를 물어봐요. (앱 실행 중에는 기억)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    switch profile.kind {
                    case .postgres:
                        TextField(tr("접속 DB"), text: $profile.database, prompt: Text(tr("비우면 postgres")))
                        Text(tr("PostgreSQL 은 DB 마다 따로 접속해요. 사이드바에서는 이 DB 의 스키마를 골라요."))
                            .font(.caption).foregroundStyle(.secondary)
                    case .mssql:
                        TextField(tr("기본 DB"), text: $profile.database, prompt: Text(tr("비우면 첫 번째 사용자 DB")))
                    case .mysql:
                        TextField(tr("기본 DB"), text: $profile.database, prompt: Text(tr("비우면 첫 번째 DB")))
                    case .redis where profile.redisMode == .cluster:
                        EmptyView()
                    case .redis:
                        TextField(tr("DB 번호"), text: $profile.database, prompt: Text("0"))
                        Text(tr("0~15 (서버 설정에 따라 다름). 연결한 뒤 사이드바에서 바꿀 수 있어요. ElastiCache 전송 중 암호화를 쓰면 TLS 를 켜세요."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(tr("TLS 사용"), isOn: $profile.useTLS)
                    if profile.useTLS && profile.kind != .mssql {
                        tlsVerifyRows
                    }
                }
                Section {
                    Toggle(tr("SSH 바스티온 경유"), isOn: $useSSH)
                    if useSSH {
                        TextField(tr("바스티온 호스트"), text: $ssh.host)
                        TextField(tr("SSH 포트"), value: $ssh.port, format: .number.grouping(.never))
                        TextField(tr("SSH 사용자"), text: $ssh.username)
                        HStack {
                            TextField(tr("키 파일"), text: $ssh.keyPath, prompt: Text(tr("~/.ssh/bastion.pem (비우면 ssh-agent)")))
                            Button(tr("선택…")) { pickKey() }
                        }
                    }
                } header: {
                    Text(tr("SSH 터널"))
                } footer: {
                    if useSSH {
                        Text(tr("Mac의 /usr/bin/ssh 로 터널을 열어요. 키 파일 인증만 지원해요."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if let msg = testMessage {
                Text(msg.text)
                    .font(.callout)
                    .foregroundStyle(msg.ok ? .green : .red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()
            HStack {
                Button(tr("연결 테스트")) { Task { await test() } }
                    .disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("취소")) { app.editingProfile = nil }
                    .keyboardShortcut(.cancelAction)
                Button(tr("저장")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.name.isEmpty || profile.host.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 540, height: 700)
        .sheet(item: $securityPrompt) { item in
            SecurityPromptView(prompt: item.prompt, profileName: draft.name,
                               onCancel: { securityPrompt = nil },
                               onAccept: { acceptSecurityPrompt(item.prompt) })
        }
    }

    /// 연결 테스트 중 확인 창에서 [신뢰] · [지우기]: 고정 지문은 편집 중인 값에 넣고(저장할 때 감사 로그), 다시 테스트
    private func acceptSecurityPrompt(_ prompt: SecurityPrompt) {
        securityPrompt = nil
        switch app.applySecurityAccept(prompt, profileName: draft.name) {
        case .set(let pin): profile.tlsPinSHA256 = pin
        case .clear: profile.tlsPinSHA256 = nil
        case .none: break
        }
        Task { await test() }
    }

    /// "서버 인증서 확인" 과 고정한 인증서 (F9-3)
    @ViewBuilder private var tlsVerifyRows: some View {
        Toggle(tr("서버 인증서 확인"), isOn: $profile.tlsVerify)
        if !profile.tlsVerify {
            Text(tr("인증서를 확인하지 않으면 중간에서 가로채도 알 수 없어요. 암호화만 해요."))
                .font(.caption).foregroundStyle(.orange)
        } else if useSSH {
            Text(tr("SSH 터널 안쪽은 127.0.0.1 이라 이름은 확인하지 않고, 고정한 인증서가 있으면 지문만 확인해요."))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(tr("시스템 신뢰 저장소로 인증서와 호스트 이름을 확인해요. 사설 인증서면 처음 연결할 때 지문을 보여 주고 고정할지 물어봐요."))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let pin = profile.tlsPinSHA256, !pin.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "pin.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("고정한 인증서")).font(.caption).foregroundStyle(.secondary)
                    Text(pin).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(tr("저장된 인증서 지우기")) { profile.tlsPinSHA256 = nil }
                    .controlSize(.small)
            }
        }
    }

    private var draft: ConnectionProfile {
        var p = profile
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        p.host = p.host.trimmingCharacters(in: .whitespaces)
        p.ssh = useSSH ? ssh : nil
        return p
    }

    private var redisModeHelp: String {
        switch profile.redisMode {
        case .standalone:
            return tr("서버 하나에 접속해요. 서버가 Cluster 면 자동으로 Cluster 로 동작해요.")
        case .cluster:
            return tr("노드 하나(또는 ElastiCache 구성 엔드포인트)만 적으면 나머지 노드를 찾아 키마다 맞는 노드로 보내요. MOVED/ASK 는 자동 처리. DB 는 0 만 써요. SSH 를 쓰면 노드마다 터널을 열어요.")
        case .sentinel:
            return tr("센티널 주소(쉼표로 여러 개)와 마스터 이름을 넣으면 현재 마스터를 찾아 접속해요. 장애 조치 뒤에는 다시 연결하면 새 마스터로 붙어요.")
        }
    }

    private func save() {
        app.saveProfile(draft, password: (isNew || passwordChanged) ? password : nil)
    }

    private func test() async {
        testing = true
        testMessage = nil
        defer { testing = false }
        do {
            if draft.kind == .redis {
                let session = try await RedisSession.connect(profile: draft, password: password)
                var version = (try? await session.info("server").first?.1.first { $0.0 == "redis_version" }?.1).map { "Redis \($0)" } ?? "Redis"
                version += " · " + (await session.tlsStatus).text
                await session.close()
                testMessage = (true, tr("연결 성공 · %@", "\(version)"))
                app.log(.success, .connection, tr("%@ 연결 테스트 성공 · %@", "\(draft.name)", "\(version)"))
                return
            }
            let session = try await DBSession.connect(profile: draft, password: password)
            // 연결은 이미 성공. 버전 조회가 안 되더라도(권한 등) 실패로 보지 않는다.
            let version = ((try? await session.serverVersion()) ?? draft.kind.title) + " · " + (await session.tlsStatus).text
            await session.close()
            testMessage = (true, tr("연결 성공 · %@", "\(version)"))
            app.log(.success, .connection, tr("%@ 연결 테스트 성공 · %@", "\(draft.name)", "\(version)"))
        } catch {
            testMessage = (false, app.logError(error, .connection, context: tr("%@ 연결 테스트 실패", "\(draft.name)")))
            securityPrompt = SecurityPrompt.from(error).map(EditorSecurityPrompt.init)
        }
    }

    private func pickKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            ssh.keyPath = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }
}

/// 접속 편집 안의 확인 창 (sheet(item:) 용)
private struct EditorSecurityPrompt: Identifiable {
    let id = UUID()
    let prompt: SecurityPrompt
}
