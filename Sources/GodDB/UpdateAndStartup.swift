import AppKit
import GodDBCore
import Observation
import Sparkle
import SwiftUI

// MARK: - 자동 업데이트 (Sparkle)

/// 업데이트 방식 (설정 > 업데이트)
enum UpdateMode: String, CaseIterable, Identifiable {
    /// 받아서 자동으로 설치 (다음 실행부터 새 버전)
    case automatic
    /// 확인만 하고 "새 버전이 있습니다" 창으로 알림 (기본)
    case notify
    /// 확인하지 않음 (메뉴 "업데이트 확인…" 으로만)
    case manual

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return tr("자동 업데이트 (받아서 설치)")
        case .notify: return tr("확인하고 알림 (설치는 직접)")
        case .manual: return tr("수동 (메뉴에서 확인할 때만)")
        }
    }

    static let key = "GodDB.update.mode"
    static var current: UpdateMode {
        get { UserDefaults.standard.string(forKey: key).flatMap(UpdateMode.init(rawValue:)) ?? .notify }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Sparkle 업데이트. 서버 없이 GitHub 릴리스에 첨부한 appcast.xml 을 읽는다 (Info.plist SUFeedURL).
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    private var controller: SPUStandardUpdaterController?
    weak var app: AppState?

    /// 개발 실행(swift run, 번들 아님)에서는 끈다
    var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && !LogFile.suspended }

    func start() {
        guard available, controller == nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        apply(UpdateMode.current)
        do { try c.updater.start() } catch {
            app?.logError(error, .app, context: tr("자동 업데이트 시작 실패"))
        }
    }

    func apply(_ mode: UpdateMode) {
        UpdateMode.current = mode
        guard let u = controller?.updater else { return }
        u.automaticallyChecksForUpdates = mode != .manual
        u.automaticallyDownloadsUpdates = mode == .automatic
    }

    /// 메뉴 "업데이트 확인…"
    func checkNow() {
        if controller == nil { start() }
        controller?.checkForUpdates(nil)
    }

    /// 시작할 때 조용히 확인 (설정이 수동이면 안 함)
    /// 시작할 때 조용히 확인 (설정이 수동이면 안 함). 업데이터는 시작 직후 잠깐 확인할 수 없는 상태라
    /// 준비될 때까지(최대 10초) 기다렸다가 확인한다. 새 버전이 있으면 업데이트 창이 뜬다.
    func checkInBackground() {
        guard UpdateMode.current != .manual else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<40 {
                if let u = self?.controller?.updater, u.canCheckForUpdates, !u.sessionInProgress {
                    u.checkForUpdatesInBackground()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? available }

    // MARK: SPUUpdaterDelegate

    /// 자동 업데이트 모드: 새 버전을 다 받았을 때. 조용히 종료 때 설치하는 대신 지금 다시 시작할지 묻는다.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let install = immediateInstallHandler
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.app?.log(.info, .app, tr("새 버전 %@ 을 받았어요. 종료할 때 설치돼요.", version))
                let alert = NSAlert()
                alert.messageText = tr("GodDB %@ 을 받았어요", version)
                alert.informativeText = tr("지금 다시 시작해서 설치할까요? 나중에 하면 앱을 종료할 때 설치돼요.")
                alert.addButton(withTitle: tr("지금 다시 시작"))
                alert.addButton(withTitle: tr("종료할 때 설치"))
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { install() }
            }
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let from = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let to = item.displayVersionString
        MainActor.assumeIsolated {
            app?.log(.info, .app, tr("업데이트 설치 · %@ → %@", from, to),
                     audit: AuditRecord(.settings, result: "업데이트 설치 \(from) → \(to)"))
            LogFile.shared.flush()
        }
    }
}

// MARK: - 시작 화면 (준비 중 진행 막대)

@MainActor
@Observable
final class StartupState {
    struct Step: Identifiable {
        let id = UUID()
        let title: String
        var done = false
        var note: String?
    }

    var steps: [Step] = []
    var current = ""
    var finished = false
    var progress: Double {
        steps.isEmpty ? 0 : Double(steps.filter(\.done).count) / Double(steps.count)
    }

    /// 앱을 켤 때 한 번. 오래 걸릴 수 있는 일(네트워크·Ollama·업데이트)은 시간 제한을 두고, 실패해도 앱은 열린다.
    func run(app: AppState) async {
        guard !finished, steps.isEmpty else { return }
        let started = Date()
        let plan: [(String, () async -> String?)] = [
            (tr("설정과 접속 목록 불러오는 중"), {
                tr("접속 %@개", "\(app.profiles.count)")
            }),
            (tr("PC · 네트워크 정보 확인 중 (감사 로그)"), {
                await app.logStartup()
                return nil
            }),
            (tr("AI(Ollama) 연결 확인 중"), {
                let assistantOn = UserDefaults.standard.object(forKey: AppSettings.assistantKey) as? Bool ?? true
                guard assistantOn else { return tr("꺼짐") }
                let status = await Self.withTimeout(2.5) { await AISettings.client.status() }
                switch status {
                case .running(let models)?: return tr("모델 %@개", "\(models.count)")
                case .installedNotRunning?: return tr("실행 안 됨")
                case .notInstalled?: return tr("설치 안 됨")
                case nil: return tr("응답 없음")
                }
            }),
            (tr("모델 · 대화 기록 정리 중"), {
                await Task.detached(priority: .utility) { DiagramChatStore.shared.pruneAll() }.value
                app.modeling.loadIfNeeded()
                return nil
            }),
            (tr("업데이트 확인 중"), {
                let u = UpdateController.shared
                u.app = app
                u.start()
                guard u.available else { return tr("개발 실행") }
                guard UpdateMode.current != .manual else { return tr("수동") }
                u.checkInBackground()
                return nil
            }),
        ]
        steps = plan.map { Step(title: $0.0) }
        for (i, item) in plan.enumerated() {
            current = item.0
            let stepStart = Date()
            let note = await item.1()
            // 단계가 순서대로 진행되는 게 보이도록 단계마다 최소 0.15초
            let took = Date().timeIntervalSince(stepStart)
            if took < 0.15 { try? await Task.sleep(for: .seconds(0.15 - took)) }
            withAnimation(.easeOut(duration: 0.15)) {
                steps[i].done = true
                steps[i].note = note
            }
        }
        _ = started
        try? await Task.sleep(for: .seconds(0.2))   // 마지막 체크가 보이도록 잠깐
        withAnimation(.easeInOut(duration: 0.35)) { finished = true }
        app.showReleaseNotesIfUpdated()
    }

    static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// 시작 화면: 아이콘 + 진행 막대 + 지금 하는 일
struct SplashView: View {
    let startup: StartupState

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 96, height: 96)
                VStack(spacing: 4) {
                    Text("GodDB").font(.largeTitle.weight(.bold))
                    Text(version).font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: startup.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 320)
                    Text(startup.current.isEmpty ? tr("준비 중…") : startup.current + "…")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(width: 320, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(startup.steps) { s in
                            HStack(spacing: 6) {
                                Image(systemName: s.done ? "checkmark.circle.fill" : "circle.dotted")
                                    .foregroundStyle(s.done ? Color.green : Color.secondary)
                                Text(s.title).foregroundStyle(s.done ? .secondary : .primary)
                                if let n = s.note { Text("· \(n)").foregroundStyle(.tertiary) }
                            }
                            .font(.caption)
                        }
                    }
                    .frame(width: 320, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - 릴리스 노트

extension AppState {
    static var releaseNotes: [ReleaseNotes.Entry] {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return ReleaseNotes.released(appGuide?.releaseNotes ?? [], upTo: current)
    }

    /// 새 버전을 처음 켰으면 그 사이 변경 내용을 한 번 보여준다
    func showReleaseNotesIfUpdated() {
        let key = "GodDB.lastSeenVersion"
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let last = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(current, forKey: key)
        guard let last, last != current, current != "dev",
              !ReleaseNotes.between(Self.releaseNotes, after: last, upTo: current).isEmpty else { return }
        releaseNotesSince = last
        showReleaseNotes = true
    }

    /// 앱 시작 감사 로그 (PC·IP 정보)
    func logStartup() async {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let (identity, summary) = await Task.detached(priority: .utility) { (ClientInfo.identity, ClientInfo.summary()) }.value
        log(.info, .app, tr("GodDB %@ 시작 · 사용자 %@", version, identity), detail: summary,
            audit: AuditRecord(.appStart, result: "GodDB \(version)",
                               statement: summary.components(separatedBy: "\n").joined(separator: " · ")))
    }
}

/// 새로운 기능 (버전별 변경 내용)
struct ReleaseNotesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    var body: some View {
        let all = AppState.releaseNotes
        let since = app.releaseNotesSince
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(since == nil ? tr("새로운 기능") : tr("%@ 로 업데이트됐어요", version), systemImage: "sparkles")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(tr("AI 에게 물어보기")) {
                    dismiss()
                    app.assistant.visible = true
                    let q = since.map { tr("%@ 에서 %@ 로 바뀐 점을 정리해줘", $0, version) } ?? tr("최근 버전들에서 바뀐 점을 정리해줘")
                    app.askAssistant(q)
                }
                .help(tr("AI 어시스턴트가 변경 이력을 보고 버전별 차이를 설명해요"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(all) { e in
                        let isNew = since.map { ReleaseNotes.compare(e.version, $0) == .orderedDescending } ?? false
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(e.version).font(.headline)
                                if e.version == version {
                                    Text(tr("지금 버전")).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                } else if isNew {
                                    Text("NEW").font(.caption.bold()).foregroundStyle(.orange)
                                }
                            }
                            ForEach(Array(e.lines.enumerated()), id: \.offset) { _, line in
                                Text((try? AttributedString(markdown: line.hasPrefix("- ") ? "• " + line.dropFirst(2) : line))
                                     ?? AttributedString(line))
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isNew || e.version == version ? Color.accentColor.opacity(0.06) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack {
                Spacer()
                Button(tr("닫기")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }
}

/// 설정 > 업데이트
struct UpdateSettingsView: View {
    @State private var mode = UpdateMode.current

    var body: some View {
        Form {
            Section {
                Picker(tr("업데이트 방식"), selection: $mode) {
                    ForEach(UpdateMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: mode) { UpdateController.shared.apply(mode) }
                Text(tr("새 버전은 GitHub 릴리스에서 받아요. 설치 파일은 Apple 공증과 업데이트 서명을 모두 확인한 뒤에만 설치돼요."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(tr("지금 업데이트 확인…")) { UpdateController.shared.checkNow() }
                    Button(tr("새로운 기능 보기")) { AppState.shared?.releaseNotesSince = nil; AppState.shared?.showReleaseNotes = true }
                }
            }
        }
        .formStyle(.grouped)
    }
}
