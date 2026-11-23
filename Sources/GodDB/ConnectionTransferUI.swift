import AppKit
import GodDBCore
import SwiftUI
import UniformTypeIdentifiers

/// 가져오기 창 요청 (파일을 읽은 뒤)
struct ImportRequest: Identifiable {
    let id = UUID()
    let fileName: String
    let bundle: ConnectionBundle
    /// 접속별 안내 (DataGrip 에서 가져올 때)
    var notes: [UUID: [String]] = [:]
    /// 지원하지 않아 건너뛴 접속 이름 (DBeaver 에서 가져올 때)
    var skipped: [String] = []
}

extension AppState {
    /// 파일을 골라 읽고 가져오기 창을 연다. GodDB 파일과 DBeaver(.dbp · data-sources.json) 를 모두 받는다.
    func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "dbp") ?? .zip]
        panel.allowsMultipleSelection = false
        panel.message = tr("GodDB 에서 내보낸 접속 정보 파일(.json) 또는 DBeaver 파일(.dbp · data-sources.json)을 고르세요.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openImportFile(url)
    }

    /// DBeaver 파일을 골라 가져오기 창을 연다. DBeaver 작업 폴더가 있으면 거기서 시작한다.
    func chooseDBeaverFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "dbp") ?? .zip]
        panel.allowsMultipleSelection = false
        panel.message = tr("DBeaver 에서 내보낸 프로젝트 파일(.dbp) 또는 작업 폴더의 data-sources.json 을 고르세요.")
        let workspace = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DBeaverData/workspace6/General/.dbeaver")
        if FileManager.default.fileExists(atPath: workspace.path) { panel.directoryURL = workspace }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openImportFile(url)
    }

    func openImportFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "dbp" || DBeaverImport.looksLikeDBeaver(data) {
                let result = try DBeaverImport.parse(fileAt: url)
                let bundle = ConnectionBundle(exportedAt: Date(), app: "DBeaver", profiles: result.sources.map(\.profile), passwords: nil)
                importRequest = ImportRequest(fileName: url.lastPathComponent, bundle: bundle,
                                              notes: Dictionary(result.sources.map { ($0.profile.id, $0.notes) }, uniquingKeysWith: { a, _ in a }),
                                              skipped: result.skipped)
                return
            }
            let bundle = try ConnectionTransfer.parse(data)
            importRequest = ImportRequest(fileName: url.lastPathComponent, bundle: bundle)
        } catch {
            logError(error, .app, context: tr("접속 정보 가져오기 실패"))
            let alert = NSAlert()
            alert.messageText = tr("접속 정보 가져오기 실패")
            alert.informativeText = ErrorText.describe(error).message
            alert.runModal()
        }
    }

    /// 클립보드의 DataGrip 접속 정보를 읽어 가져오기 창을 연다.
    func pasteDataGrip(_ text: String? = nil) {
        let text = text ?? NSPasteboard.general.string(forType: .string) ?? ""
        do {
            let sources = try DataGripImport.parse(text)
            let bundle = ConnectionBundle(exportedAt: Date(), app: "DataGrip", profiles: sources.map(\.profile), passwords: nil)
            importRequest = ImportRequest(fileName: tr("DataGrip 클립보드"), bundle: bundle,
                                          notes: Dictionary(sources.map { ($0.profile.id, $0.notes) }, uniquingKeysWith: { a, _ in a }))
        } catch {
            logError(error, .app, context: tr("DataGrip 접속 정보 붙여넣기 실패"))
            let alert = NSAlert()
            alert.messageText = tr("DataGrip 접속 정보 붙여넣기 실패")
            alert.informativeText = ErrorText.describe(error).message
            alert.runModal()
        }
    }

    /// 고른 접속을 합친다. 비밀번호가 있으면 키체인에 넣는다.
    func importProfiles(_ incoming: [ConnectionProfile], passwords: [UUID: String], fileName: String) {
        profiles = ConnectionTransfer.merge(incoming, into: profiles)
        var saved = 0
        for p in incoming {
            guard let pw = passwords[p.id] else { continue }
            if p.savePassword {
                Keychain.setPassword(pw, for: p.id)
            } else {
                sessionPasswords[p.id] = pw
            }
            saved += 1
        }
        persist()
        log(.success, .app, tr("접속 정보 %@개 가져옴 · %@", "\(incoming.count)", fileName)
            + (saved > 0 ? tr(" · 비밀번호 %@개", "\(saved)") : ""),
            detail: incoming.map { "\($0.name) (\($0.typeTitle) \($0.host):\($0.port))" }.joined(separator: "\n"),
            audit: AuditRecord(.settings, result: "접속 정보 \(incoming.count)개 가져옴" + (saved > 0 ? " · 비밀번호 \(saved)개" : ""),
                               statement: fileName + " · " + incoming.map(\.name).joined(separator: ", ")))
    }

    /// 내보내기: 저장 위치를 고르고 파일을 쓴다.
    @discardableResult
    func exportProfiles(_ list: [ConnectionProfile], passphrase: String?) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "goddb-connections-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted))).json"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            var passwords: [UUID: String]? = nil
            if passphrase != nil {
                passwords = [:]
                for p in list {
                    if let pw = Keychain.password(for: p.id) ?? sessionPasswords[p.id] { passwords?[p.id] = pw }
                }
            }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            let data = try ConnectionTransfer.export(list, passwords: passwords, passphrase: passphrase, appVersion: version)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            log(.success, .app, tr("접속 정보 %@개 내보냄 · %@", "\(list.count)", url.lastPathComponent)
                + (passwords.map { tr(" · 비밀번호 %@개 (암호화)", "\($0.count)") } ?? ""),
                detail: url.path + "\n" + list.map(\.name).joined(separator: "\n"),
                audit: AuditRecord(.export, result: "접속 정보 \(list.count)개 내보냄" + (passwords.map { " · 비밀번호 \($0.count)개 (암호화)" } ?? ""),
                                   statement: url.path + " · " + list.map(\.name).joined(separator: ", ")))
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        } catch {
            logError(error, .app, context: tr("접속 정보 내보내기 실패"))
            let alert = NSAlert()
            alert.messageText = tr("접속 정보 내보내기 실패")
            alert.informativeText = ErrorText.describe(error).message
            alert.runModal()
            return false
        }
    }
}

/// 내보낼 접속과 비밀번호 포함 여부를 고르는 창
struct ExportConnectionsSheet: View {
    @Environment(AppState.self) private var app
    @State private var selected: Set<UUID> = []
    @State private var includePasswords = false
    @State private var passphrase = ""
    @State private var confirm = ""

    private var passphraseProblem: String? {
        guard includePasswords else { return nil }
        if passphrase.count < 8 { return tr("암호는 8자 이상으로 정해 주세요.") }
        if passphrase != confirm { return tr("암호 확인이 달라요.") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("접속 정보 내보내기"), systemImage: "square.and.arrow.up").font(.headline)
            Text(tr("고른 접속을 JSON 파일 하나로 저장해요. 다른 Mac 의 GodDB 에서 가져올 수 있어요."))
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(app.profiles) { p in
                    Toggle(isOn: Binding(get: { selected.contains(p.id) },
                                         set: { if $0 { selected.insert(p.id) } else { selected.remove(p.id) } })) {
                        HStack {
                            Text(p.name)
                            Text("\(p.typeTitle) · \(p.host):\(String(p.port))").foregroundStyle(.secondary)
                            if p.ssh != nil { Text("SSH").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(minHeight: 160)
            HStack {
                Button(tr("모두 선택")) { selected = Set(app.profiles.map(\.id)) }
                Button(tr("모두 해제")) { selected = [] }
                Spacer()
                Text(tr("%@개 선택", "\(selected.count)")).foregroundStyle(.secondary)
            }
            .buttonStyle(.hover)

            Toggle(tr("비밀번호 포함 (암호로 잠금)"), isOn: $includePasswords).toggleStyle(.checkbox)
            if includePasswords {
                VStack(alignment: .leading, spacing: 6) {
                    PasswordField(title: tr("암호 (8자 이상)"), text: $passphrase)
                    PasswordField(title: tr("암호 확인"), text: $confirm)
                    Text(tr("가져올 때 이 암호가 필요해요. 암호는 파일에 저장되지 않으니 따로 전달하세요."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let problem = passphraseProblem, !passphrase.isEmpty {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.leading, 20)
            } else {
                Text(tr("비밀번호는 넣지 않아요. 가져온 쪽에서 처음 연결할 때 입력해요."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(tr("SSH 개인키 파일은 넣지 않고 경로만 넣어요. 받는 Mac 에도 같은 경로에 키가 있어야 해요."))
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(tr("취소")) { app.showExportConnections = false }
                    .keyboardShortcut(.cancelAction)
                Button(tr("내보내기…")) {
                    let list = app.profiles.filter { selected.contains($0.id) }
                    if app.exportProfiles(list, passphrase: includePasswords ? passphrase : nil) {
                        app.showExportConnections = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || passphraseProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .onAppear { selected = Set(app.profiles.map(\.id)) }
    }
}

/// 가져올 접속을 고르는 창
struct ImportConnectionsSheet: View {
    @Environment(AppState.self) private var app
    let request: ImportRequest
    @State private var selected: Set<UUID> = []
    @State private var passphrase = ""
    @State private var error: String?

    var body: some View {
        let bundle = request.bundle
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("접속 정보 가져오기"), systemImage: "square.and.arrow.down").font(.headline)
            Text("\(request.fileName) · \(bundle.app) · \(bundle.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout).foregroundStyle(.secondary)
            if !request.skipped.isEmpty {
                Label(tr("지원하지 않는 접속 %@개는 건너뛰었어요: %@", "\(request.skipped.count)", request.skipped.joined(separator: ", ")),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .lineLimit(3)
            }
            List {
                ForEach(bundle.profiles) { p in
                    Toggle(isOn: Binding(get: { selected.contains(p.id) },
                                         set: { if $0 { selected.insert(p.id) } else { selected.remove(p.id) } })) {
                        HStack(alignment: .top) {
                            ImportRowDetails(profile: p, notes: request.notes[p.id] ?? [])
                            Spacer()
                            switch ConnectionTransfer.action(for: p, existing: app.profiles) {
                            case .add:
                                Text(tr("새로 추가")).font(.caption).foregroundStyle(.green)
                            case .replace(let name):
                                Text(tr("이미 있음 → 덮어씀 (%@)", name)).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(minHeight: 180)
            HStack {
                Button(tr("모두 선택")) { selected = Set(bundle.profiles.map(\.id)) }
                Button(tr("모두 해제")) { selected = [] }
                Spacer()
                Text(tr("%@개 선택", "\(selected.count)")).foregroundStyle(.secondary)
            }
            .buttonStyle(.hover)

            if bundle.hasPasswords {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("비밀번호가 암호로 잠겨 들어 있어요. 내보낼 때 정한 암호를 넣으면 함께 가져와요."))
                        .font(.caption).foregroundStyle(.secondary)
                    PasswordField(title: tr("암호 (비우면 비밀번호 없이 가져옴)"), text: $passphrase)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(tr("취소")) { app.importRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button(tr("가져오기")) { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
        .onAppear {
            // 새 접속은 기본 선택, 이미 있는 접속은 덮어쓰지 않도록 기본 해제
            selected = Set(request.bundle.profiles.filter {
                ConnectionTransfer.action(for: $0, existing: app.profiles) == .add
            }.map(\.id))
        }
    }

    private func runImport() {
        var passwords: [UUID: String] = [:]
        if request.bundle.hasPasswords, !passphrase.isEmpty {
            do {
                passwords = try ConnectionTransfer.passwords(in: request.bundle, passphrase: passphrase)
            } catch {
                self.error = ErrorText.describe(error).message
                return
            }
        }
        let list = request.bundle.profiles.filter { selected.contains($0.id) }
        app.importProfiles(list, passwords: passwords, fileName: request.fileName)
        app.importRequest = nil
    }
}

/// 가져오기 창의 접속 한 줄 (그룹 › 이름 · 주소, SSH, 안내)
private struct ImportRowDetails: View {
    let profile: ConnectionProfile
    let notes: [String]

    var body: some View {
        let p = profile
        let address = "\(p.typeTitle) · \(p.host):\(String(p.port))" + (p.database.isEmpty ? "" : " / " + p.database)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if !p.group.isEmpty { Text(p.group + " ›").foregroundStyle(.tertiary) }
                Text(p.name)
                Text(address).foregroundStyle(.secondary)
            }
            if let ssh = p.ssh, !ssh.host.isEmpty {
                let user = ssh.username.isEmpty ? "" : ssh.username + "@"
                Text("SSH " + user + ssh.host + ":" + String(ssh.port))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(notes, id: \.self) { n in
                let plain = n == tr("비밀번호는 처음 연결할 때 입력해요.")
                Text(n).font(.caption).foregroundStyle(plain ? Color.secondary : Color.orange)
            }
        }
    }
}
