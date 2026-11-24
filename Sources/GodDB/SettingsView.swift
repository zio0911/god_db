import AppKit
import GodDBCore
import Observation
import SwiftUI

/// 앱 설정. 언어를 바꾸면 화면 전체를 다시 그린다.
@MainActor
@Observable
final class AppSettings {
    var language: AppLanguage {
        didSet { L10n.language = language }
    }

    /// 입력 중인 주소. 이 PC(localhost) 주소일 때만 저장한다 (다른 서버로 구조 · SQL · 샘플 값이 나가지 않게)
    var ollamaURL: String { didSet { if AISettings.isLocalURL(ollamaURL) { AISettings.url = ollamaURL } } }
    var tuningModel: String { didSet { AISettings.model = tuningModel } }
    var logFileEnabled: Bool { didSet { LogFile.enabled = logFileEnabled } }
    var logRetentionDays: Int { didSet { LogFile.retentionDays = logRetentionDays; LogFile.shared.cleanNow() } }
    /// 쿼리 히스토리 보관 일수 (0 = 영구). 바꾸면 바로 정리한다.
    var historyKeepDays: Int {
        didSet {
            QueryHistory.keepDays = historyKeepDays
            DispatchQueue.global(qos: .utility).async { QueryHistory.shared.applyRetentionNow() }
        }
    }
    var assistantEnabled: Bool { didSet { UserDefaults.standard.set(assistantEnabled, forKey: Self.assistantKey) } }
    static let assistantKey = "GodDB.assistant.enabled"

    init() {
        language = L10n.language
        ollamaURL = AISettings.url
        tuningModel = AISettings.model
        logFileEnabled = LogFile.enabled
        logRetentionDays = LogFile.retentionDays
        historyKeepDays = QueryHistory.keepDays
        assistantEnabled = UserDefaults.standard.object(forKey: Self.assistantKey) as? Bool ?? true
    }
}

/// 설정 창 (⌘,)
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(tr("일반"), systemImage: "gearshape") }
            AISettingsView()
                .tabItem { Label(tr("AI"), systemImage: "sparkles") }
            UpdateSettingsView()
                .tabItem { Label(tr("업데이트"), systemImage: "arrow.down.circle") }
            LicenseSettingsView()
                .tabItem { Label(tr("라이선스"), systemImage: "doc.text") }
        }
        .frame(width: 640, height: 520)
        // 언어가 바뀌면 설정 창도 새 언어로 다시 그린다.
        .id(settings.language)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppState.self) private var app
    @AppStorage(AppState.confirmDangerousKey) private var confirmDangerous = true
    @AppStorage(EditorLint.enabledKey) private var lintEnabled = true
    @AppStorage(EditorLint.serverKey) private var lintServer = true
    @AppStorage(AppState.prodIdleMinutesKey) private var prodIdleMinutes = 30
    @State private var versionTaps = 0
    @State private var showDotZero = false
    @State private var auditToolUnlocked = false
    @State private var tapWork: DispatchWorkItem?
    @AppStorage(AppState.queryTimeoutKey) private var queryTimeout = QueryTimeLimit.defaultSeconds

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(tr("언어"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(tr("바꾸면 바로 적용돼요. 메뉴 막대는 앱을 다시 시작해야 바뀌어요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.language == .system {
                    Text(tr("지금 시스템 언어: %@", L10n.resolved == .ko ? "한국어" : "English"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(tr("언어"))
            }
            Section {
                Picker(tr("실행 시간 제한"), selection: $queryTimeout) {
                    Text(tr("없음")).tag(0)
                    Text(tr("30초")).tag(30)
                    Text(tr("1분")).tag(60)
                    Text(tr("5분")).tag(300)
                    Text(tr("10분")).tag(600)
                    Text(tr("30분")).tag(1800)
                }
                Text(tr("시간을 넘기면 쿼리를 자동으로 취소해요. 실행 중에는 언제든 [취소] 또는 ⌘. 로 멈출 수 있어요. PostgreSQL · MySQL 은 서버에도 같은 제한을 걸어요 (다음 연결부터, MySQL 은 SELECT 만)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(tr("쿼리"))
            }
            Section {
                Toggle(tr("쿼리 오류에 빨간 밑줄"), isOn: $lintEnabled)
                Text(tr("없는 컬럼, 빠진 콤마, 닫히지 않은 괄호 · 따옴표, 키워드 오타를 입력하는 동안 표시해요. 밑줄에 마우스를 올리면 이유가 나와요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(tr("DB 에 검사 요청"), isOn: $lintServer)
                    .disabled(!lintEnabled)
                Text(tr("입력을 1초 멈추면 커서가 있는 구문을 DB 에 실행 없이 검사만 맡겨요 (MySQL · PostgreSQL PREPARE, SQL Server sp_describe_first_result_set). 실행 중이거나 PostgreSQL 트랜잭션이 열려 있으면 묻지 않아요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(tr("편집기"))
            }
            Section {
                Toggle(tr("위험한 명령 실행 전 확인"), isOn: $confirmDangerous)
                    .onChange(of: confirmDangerous) { _, on in
                        app.log(on ? .info : .warning, .app,
                                on ? tr("위험한 명령 실행 전 확인을 켰어요") : tr("위험한 명령 실행 전 확인을 껐어요"),
                                audit: AuditRecord(.settings, target: "GodDB",
                                                   result: on ? "위험한 명령 확인 켬" : "위험한 명령 확인 끔"))
                    }
                Text(tr("WHERE 없는 DELETE · UPDATE, TRUNCATE, DROP, Redis 의 FLUSHALL · FLUSHDB · KEYS 등을 실행하기 전에 한 번 더 물어봐요. 운영 접속에서 데이터를 바꾸는 확인은 이 설정과 관계없이 항상 떠요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(tr("운영 접속 자동 끊기"), selection: $prodIdleMinutes) {
                    Text(tr("끔")).tag(0)
                    ForEach(AppState.prodIdleChoices.filter { $0 > 0 }, id: \.self) { m in Text(tr("%@분", "\(m)")).tag(m) }
                }
                .onChange(of: prodIdleMinutes) { _, m in
                    app.log(.info, .app, m == 0 ? tr("운영 접속 자동 끊기를 껐어요") : tr("운영 접속 자동 끊기: %@분", "\(m)"),
                            audit: AuditRecord(.settings, target: "GodDB", result: m == 0 ? "운영 자동 끊기 끔" : "운영 자동 끊기 \(m)분"))
                }
                Text(tr("운영 접속을 이 시간 동안 쓰지 않으면 연결을 끊어요. 커밋하지 않은 변경이 있으면 끊지 않고 알려 줘요. 쿼리 탭은 남고, 다시 실행하면 다시 연결해요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(tr("안전"))
            }
            Section {
                Picker(tr("히스토리 보관 기간"), selection: $settings.historyKeepDays) {
                    Text(tr("7일")).tag(7)
                    Text(tr("30일")).tag(30)
                    Text(tr("90일")).tag(90)
                    Text(tr("영구 보관")).tag(0)
                }
                Text(settings.historyKeepDays == 0
                     ? tr("실행한 쿼리 기록을 지우지 않고 남겨요. 기록과 열어 둔 쿼리 탭 내용은 이 Mac 의 키체인 키로 암호화해서 저장해요.")
                     : tr("%@일이 지난 쿼리 기록은 자동으로 지워요. 기록과 열어 둔 쿼리 탭 내용은 이 Mac 의 키체인 키로 암호화해서 저장해요.", "\(settings.historyKeepDays)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(tr("히스토리"))
            }
            Section {
                Toggle(tr("로그 파일 남기기"), isOn: $settings.logFileEnabled)
                Picker(tr("보관 기간"), selection: $settings.logRetentionDays) {
                    Text(tr("영구 보관")).tag(0)
                    Text(tr("3개월 (90일)")).tag(90)
                    Text(tr("6개월 (180일)")).tag(180)
                    Text(tr("1년 (365일)")).tag(365)
                }
                .disabled(!settings.logFileEnabled)
                Text(settings.logRetentionDays == 0
                     ? tr("감사 로그(접속, 실행한 SQL, 데이터 변경, 오류)를 날짜별 파일로 남겨요. 조회 결과 행은 남기지 않아요. 파일은 지우지 않고 영구 보관해요.")
                     : tr("감사 로그를 날짜별 파일로 남기고, %@일이 지난 파일은 자동으로 지워요. 조회 결과 행은 남기지 않아요.", "\(settings.logRetentionDays)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(LogFile.shared.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button(tr("로그 폴더")) {
                        try? FileManager.default.createDirectory(at: LogFile.shared.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(LogFile.shared.directory)
                    }
                }
                if auditToolUnlocked {
                    AuditCheckRow()
                }
            } header: {
                Text(tr("로그"))
            }
            Section {
                Button { versionTapped() } label: {
                    HStack {
                        Text(tr("버전"))
                        Spacer()
                        Text((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") + (showDotZero ? ".0" : ""))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                LabeledContent(tr("소스 코드")) {
                    Link("github.com/zio0911/god_db", destination: URL(string: Licenses.goddbURL)!)
                }
            } header: {
                Text(tr("정보"))
            }
        }
        .formStyle(.grouped)
        .onAppear { versionTaps = 0; showDotZero = false; tapWork?.cancel() }
    }

    private func versionTapped() {
        if showDotZero {
            auditToolUnlocked = true
            showDotZero = false
            tapWork?.cancel()
            versionTaps = 0
            return
        }
        versionTaps += 1
        showDotZero = false
        tapWork?.cancel()
        guard versionTaps < 40 else { versionTaps = 0; return }
        // 누르기를 멈추고 2초 뒤 횟수가 맞으면 10초 동안만 보인다 (나눠서 눌러도 횟수는 이어진다)
        let work = DispatchWorkItem {
            guard (30..<40).contains(versionTaps) else { return }
            showDotZero = true
            let hide = DispatchWorkItem { showDotZero = false; versionTaps = 0 }
            tapWork = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: hide)
        }
        tapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

struct LicenseSettingsView: View {
    @State private var selection: String = "GodDB"

    private var items: [String] { ["GodDB"] + Licenses.thirdParty.map(\.name) }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section(tr("GodDB")) {
                    Text("GodDB").tag("GodDB")
                }
                Section(tr("오픈소스 %@개", "\(Licenses.thirdParty.count)")) {
                    ForEach(Licenses.thirdParty) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                            Text(item.license).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(item.name)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 210)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if selection == "GodDB" {
                        goddb
                    } else if let item = Licenses.thirdParty.first(where: { $0.name == selection }) {
                        detail(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    private var goddb: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("GodDB")).font(.title2.weight(.semibold))
            Text("MIT License · \(Licenses.goddbCopyright)").foregroundStyle(.secondary)
            Text(tr("GodDB는 오픈소스예요. MIT 라이선스에 따라 자유롭게 쓰고, 고치고, 배포할 수 있어요. 저작권 표시와 라이선스 문구만 함께 남겨 주세요."))
            Link(Licenses.goddbURL, destination: URL(string: Licenses.goddbURL)!)
            licenseText(Licenses.goddb)
        }
    }

    private func detail(_ item: ThirdPartyLicense) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.name).font(.title2.weight(.semibold))
            Text("\(item.license) · \(tr(item.version))").foregroundStyle(.secondary)
            Text(item.copyright)
            if !item.note.isEmpty {
                Text(tr(item.note)).font(.callout).foregroundStyle(.secondary)
            }
            Link(item.url, destination: URL(string: item.url)!)
            if let text = item.text {
                licenseText(text)
            } else {
                Text(tr("전체 라이선스 문구는 위 링크에서 볼 수 있어요."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func licenseText(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 설정 > AI: 로컬 Ollama 연결과 모델, AI 어시스턴트 켜기
struct AISettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var status: OllamaStatus?
    @State private var checking = false
    @State private var startError: String?
    /// [모델 확인] 결과 (nil = 아직 안 함)
    @State private var probe: ModelHealth?
    @State private var probing = false

    private var models: [OllamaModel] {
        if case .running(let m) = status { return m }
        return []
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(tr("AI 어시스턴트 사용"), isOn: $settings.assistantEnabled)
                Text(tr("끄면 도구 막대의 ✨ AI 어시스턴트 버튼과 오른쪽 패널이 사라져요."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField(tr("Ollama 주소"), text: $settings.ollamaURL)
                    .onSubmit { Task { await refresh() } }
                if !AISettings.isLocalURL(settings.ollamaURL) || !AISettings.isLocal {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(tr("AI 는 이 PC 의 Ollama 만 쓸 수 있어요. 다른 서버로는 구조 · SQL · 샘플 값이 나가므로 막아 두었어요. 이 주소는 저장되지 않아요."),
                              systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.red)
                        Button(tr("기본값(localhost)으로")) {
                            settings.ollamaURL = AISettings.defaultURL
                            AISettings.url = AISettings.defaultURL
                            Task { await refresh() }
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    statusLabel
                    Spacer()
                    if checking { ProgressView().controlSize(.small) }
                    Button(tr("다시 확인")) { Task { await refresh() } }
                }
                if status == .installedNotRunning {
                    Button(tr("Ollama 실행")) {
                        do {
                            try OllamaClient.start()
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                await refresh()
                            }
                        } catch {
                            startError = ErrorText.describe(error).message
                        }
                    }
                    if let startError { Text(startError).font(.caption).foregroundStyle(.red) }
                }
                if status == .notInstalled {
                    Link(tr("Ollama 내려받기 (ollama.com)"), destination: URL(string: "https://ollama.com/download")!)
                }
            } header: {
                Text("Ollama")
            }
            Section {
                Picker(tr("모델"), selection: $settings.tuningModel) {
                    Text(tr("자동 (추천 모델 먼저)")).tag("")
                    ForEach(models) { m in
                        Text("\(m.name)  ·  \(m.parameterSize)  ·  \(String(format: "%.1f", m.sizeGB))GB").tag(m.name)
                    }
                    if !settings.tuningModel.isEmpty && !models.contains(where: { $0.name == settings.tuningModel }) {
                        Text(settings.tuningModel).tag(settings.tuningModel)
                    }
                }
                HStack {
                    Button(tr("모델 확인")) { Task { await checkModel() } }
                        .disabled(probing || models.isEmpty)
                    if probing { ProgressView().controlSize(.small) }
                    if let probe, !probing {
                        if probe.isOK {
                            Label("OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label(probe.reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                                .textSelection(.enabled).lineLimit(3)
                        }
                    }
                }
                .font(.callout)
                Text(tr("추천: M5 Pro 메모리 48GB 이상이면 %@, 24GB 면 %@ 를 추천해요. 모델을 \"자동\"으로 두면 설치된 추천 모델을 먼저 써요.",
                        AISettings.defaultRecommendedModel, AISettings.smallMemoryModel))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach([AISettings.defaultRecommendedModel, AISettings.smallMemoryModel], id: \.self) { m in
                    HStack {
                        Text("ollama pull " + m).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button(tr("복사")) { Pasteboard.copy("ollama pull " + m) }.controlSize(.small)
                    }
                }
            } header: {
                Text(tr("모델"))
            }
            Section {
                Label(tr("보내는 것: 쿼리, 쿼리에 나온 테이블의 구조(DDL·인덱스), 예상 행 수, 실행 계획"), systemImage: "arrow.up.doc")
                Label(tr("보내지 않는 것: 실제 데이터 행, 비밀번호, 접속 정보"), systemImage: "lock")
                Label(tr("개선 SQL 과 인덱스는 자동으로 실행하지 않아요. 확인 후 직접 실행하세요."), systemImage: "hand.raised")
            } header: {
                Text(tr("보내는 정보"))
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .task {
            // AI 어시스턴트의 [‹모델› 로 바꾸기] 로 바뀐 모델을 반영
            if settings.tuningModel != AISettings.model { settings.tuningModel = AISettings.model }
            await refresh()
        }
        .onChange(of: settings.tuningModel) { probe = nil }
    }

    /// 고른 모델(자동이면 쓸 모델)에 아주 짧은 요청을 보내 답하는지 확인 (AI 데이터 찾기와 같은 확인, 기억한 결과는 새로)
    private func checkModel() async {
        guard let model = AISettings.effectiveModel(installed: models.map(\.name)) else { return }
        probing = true
        probe = await ModelProbe.check(model: model, client: AISettings.client, useCache: false)
        probing = false
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .running(let models):
            Label(tr("실행 중 · 모델 %@개", "\(models.count)"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .installedNotRunning:
            Label(tr("설치됐지만 꺼져 있어요"), systemImage: "pause.circle").foregroundStyle(.orange)
        case .notInstalled:
            Label(tr("설치되지 않았어요"), systemImage: "xmark.circle").foregroundStyle(.red)
        case nil:
            Label(tr("확인 중…"), systemImage: "hourglass").foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        checking = true
        status = await AISettings.client.status()
        checking = false
    }
}
