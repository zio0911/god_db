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

    init() {
        language = L10n.language
    }
}

/// 설정 창 (⌘,)
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(tr("일반"), systemImage: "gearshape") }
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
                Section(tr("갓디비")) {
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
            Text(tr("갓디비")).font(.title2.weight(.semibold))
            Text("MIT License · \(Licenses.goddbCopyright)").foregroundStyle(.secondary)
            Text(tr("갓디비는 오픈소스예요. MIT 라이선스에 따라 자유롭게 쓰고, 고치고, 배포할 수 있어요. 저작권 표시와 라이선스 문구만 함께 남겨 주세요."))
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
