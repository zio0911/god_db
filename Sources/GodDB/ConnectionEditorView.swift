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

    init(profile: ConnectionProfile, isNew: Bool) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
        _useSSH = State(initialValue: profile.ssh != nil)
        _ssh = State(initialValue: profile.ssh ?? SSHConfig())
        let saved = Keychain.password(for: profile.id)
        _password = State(initialValue: saved ?? "")
        _hasSavedPassword = State(initialValue: saved != nil)
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
                    Toggle(profile.kind == .redis ? tr("읽기전용 (조회 명령만 허용)") : tr("읽기전용 (SELECT / SHOW / DESC / EXPLAIN 만 허용)"), isOn: $profile.readOnly)
                    if profile.readOnly && profile.kind == .mssql {
                        Text(tr("SQL Server 는 세션 단위 읽기전용 설정이 없어서 앱에서만 막아요. 운영 DB 는 읽기 전용 계정을 쓰는 걸 권장해요."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(profile.kind.title) {
                    TextField(tr("호스트"), text: $profile.host, prompt: Text("xxx.rds.amazonaws.com"))
                    TextField(tr("포트"), value: $profile.port, format: .number.grouping(.never))
                    TextField(profile.kind == .redis ? tr("ACL 사용자 (선택)") : tr("사용자"), text: $profile.username,
                              prompt: profile.kind == .redis ? Text(tr("비우면 비밀번호만으로 AUTH")) : nil)
                    SecureField(tr("비밀번호"), text: $password)
                        .onChange(of: password) { passwordChanged = true }
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
                    case .redis:
                        TextField(tr("DB 번호"), text: $profile.database, prompt: Text("0"))
                        Text(tr("0~15 (서버 설정에 따라 다름). 연결한 뒤 사이드바에서 바꿀 수 있어요. ElastiCache 전송 중 암호화를 쓰면 TLS 를 켜세요."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(tr("TLS 사용"), isOn: $profile.useTLS)
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
    }

    private var draft: ConnectionProfile {
        var p = profile
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        p.host = p.host.trimmingCharacters(in: .whitespaces)
        p.ssh = useSSH ? ssh : nil
        return p
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
                let version = (try? await session.info("server").first?.1.first { $0.0 == "redis_version" }?.1).map { "Redis \($0)" } ?? "Redis"
                await session.close()
                testMessage = (true, tr("연결 성공 · %@", "\(version)"))
                app.log(.success, .connection, tr("%@ 연결 테스트 성공 · %@", "\(draft.name)", "\(version)"))
                return
            }
            let session = try await DBSession.connect(profile: draft, password: password)
            // 연결은 이미 성공. 버전 조회가 안 되더라도(권한 등) 실패로 보지 않는다.
            let version = (try? await session.serverVersion()) ?? draft.kind.title
            await session.close()
            testMessage = (true, tr("연결 성공 · %@", "\(version)"))
            app.log(.success, .connection, tr("%@ 연결 테스트 성공 · %@", "\(draft.name)", "\(version)"))
        } catch {
            testMessage = (false, app.logError(error, .connection, context: tr("%@ 연결 테스트 실패", "\(draft.name)")))
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
