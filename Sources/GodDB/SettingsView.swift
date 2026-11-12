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

    var tuningEnabled: Bool { didSet { TuningSettings.enabled = tuningEnabled } }
    var ollamaURL: String { didSet { TuningSettings.url = ollamaURL } }
    var tuningModel: String { didSet { TuningSettings.model = tuningModel } }
    var logFileEnabled: Bool { didSet { LogFile.enabled = logFileEnabled } }

    init() {
        language = L10n.language
        tuningEnabled = TuningSettings.enabled
        ollamaURL = TuningSettings.url
        tuningModel = TuningSettings.model
        logFileEnabled = LogFile.enabled
    }
}

/// 설정 창 (⌘,)
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(tr("일반"), systemImage: "gearshape") }
            TuningSettingsView()
                .tabItem { Label(tr("쿼리 튜닝"), systemImage: "sparkles") }
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
                Toggle(tr("로그 파일 남기기"), isOn: $settings.logFileEnabled)
                Text(tr("상태창에 나오는 기록(접속, 실행한 SQL, 데이터 변경, 오류)을 날짜별 파일로 남겨요. 조회 결과 행은 남기지 않아요. %@일 지난 파일은 지워요.", "\(LogFile.shared.keepDays)"))
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
            } header: {
                Text(tr("로그"))
            }
            Section {
                LabeledContent(tr("버전"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                LabeledContent(tr("소스 코드")) {
                    Link("github.com/zio0911/god_db", destination: URL(string: Licenses.goddbURL)!)
                }
            } header: {
                Text(tr("정보"))
            }
        }
        .formStyle(.grouped)
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

/// 설정 > 쿼리 튜닝: 로컬 Ollama 연결과 모델
struct TuningSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var status: OllamaStatus?
    @State private var checking = false
    @State private var startError: String?

    private var models: [OllamaModel] {
        if case .running(let m) = status { return m }
        return []
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(tr("쿼리 튜닝 사용"), isOn: $settings.tuningEnabled)
                Text(tr("쿼리 탭의 튜닝 버튼(⌥⌘T)을 누르면 쿼리·테이블 구조·인덱스·실행 계획을 로컬 Ollama 에 보내 개선 SQL 과 추천 인덱스를 받아요."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField(tr("Ollama 주소"), text: $settings.ollamaURL)
                    .onSubmit { Task { await refresh() } }
                if !TuningSettings.isLocal {
                    Label(tr("이 Mac 밖의 주소예요. 쿼리와 테이블 구조가 그 서버로 전송돼요."), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
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
                    Text(tr("자동 (첫 번째 모델)")).tag("")
                    ForEach(models) { m in
                        Text("\(m.name)  ·  \(m.parameterSize)  ·  \(String(format: "%.1f", m.sizeGB))GB").tag(m.name)
                    }
                    if !settings.tuningModel.isEmpty && !models.contains(where: { $0.name == settings.tuningModel }) {
                        Text(settings.tuningModel).tag(settings.tuningModel)
                    }
                }
                Text(tr("추천: %@ (코드·SQL 에 강하고 한국어도 잘 알아들어요). 메모리가 넉넉하면 큰 모델일수록 정확해요.",
                        TuningSettings.recommendedModels.joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("ollama pull qwen2.5-coder:14b").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button(tr("복사")) { Pasteboard.copy("ollama pull qwen2.5-coder:14b") }.controlSize(.small)
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
        .task { await refresh() }
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
        status = await TuningSettings.client.status()
        checking = false
    }
}
