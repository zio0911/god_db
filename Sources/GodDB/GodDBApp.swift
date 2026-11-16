import AppKit
import GodDBCore
import SwiftUI

@main
struct GodDBApp: App {
    @NSApplicationDelegateAdaptor(GodDBAppDelegate.self) private var appDelegate
    @State private var app = AppState()
    @State private var settings = AppSettings()

    init() {
        // 감사 로그 검사: GodDB --verify-audit [폴더] → 결과를 출력하고 문제가 있으면 종료 코드 1
        if let i = CommandLine.arguments.firstIndex(of: "--verify-audit") {
            let dir = CommandLine.arguments.count > i + 1 ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : LogFile.shared.directory
            let reports = AuditChain.verify(directory: dir)
            reports.forEach { print(AuditChain.describe($0)) }
            let bad = reports.contains { if case .broken = $0.status { return true }; if case .unlinked = $0.status { return true }; return false }
            exit(bad ? 1 : 0)
        }
        // 개발용: GodDB --render-diagram-sample <out.png> → 샘플 ER 다이어그램을 그려 저장하고 종료
        if let i = CommandLine.arguments.firstIndex(of: "--render-diagram-sample"), CommandLine.arguments.count > i + 1 {
            let mode = CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : "physical"
            DiagramSample.render(to: CommandLine.arguments[i + 1], mode: mode)
            exit(0)
        }
        // 개발용: GodDB --render-redis-sample <폴더> <포트> <비밀번호> → Redis 화면 탭별 PNG
        if let i = CommandLine.arguments.firstIndex(of: "--render-redis-sample"), CommandLine.arguments.count > i + 3 {
            let a = CommandLine.arguments
            RedisSample.render(dir: a[i + 1], port: Int(a[i + 2]) ?? 6379, password: a[i + 3], app: app)
            exit(0)
        }
        // 개발용: GodDB --render-modeling-sample <폴더> → 모델링·테이블 수정·AI 패널·접속 그룹 PNG
        if let i = CommandLine.arguments.firstIndex(of: "--render-modeling-sample"), CommandLine.arguments.count > i + 1 {
            ModelingSample.render(dir: CommandLine.arguments[i + 1], app: app)
            exit(0)
        }
        // `swift run` 으로 띄워도 Dock 아이콘과 메뉴가 있는 일반 앱으로 동작하게 한다.
        NSApplication.shared.setActivationPolicy(.regular)
        // 실행 중 Dock·⌘Tab 아이콘을 직접 지정한다. (macOS 아이콘 캐시가 예전 등록을 쓰거나,
        // swift run 처럼 .app 번들 없이 실행해도 아이콘이 보이게)
        let candidates = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.icns"),
        ]
        if let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup(tr("GodDB")) {
            ContentView()
                .environment(app)
                .environment(settings)
                .frame(minWidth: 980, minHeight: 620)
                // 언어를 바꾸면 화면 전체를 새 언어로 다시 그린다. (접속·탭 상태는 AppState 에 있어 유지됨)
                .id(settings.language)
        }

        .windowToolbarStyle(.unified)
        .commands {
            // 언어 설정을 읽어 두면 메뉴도 언어가 바뀔 때 다시 만들어진다.
            let _ = settings.language
            // 새 창(⌘N) 대신: 메인 창은 하나만 (같은 상태를 보여 주는 두 번째 창이 생기지 않게)
            CommandGroup(replacing: .newItem) {
                Button(tr("새 쿼리 탭")) { app.addTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button(tr("새 접속…")) { app.newProfile() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button(tr("SQL 파일 열기…")) { app.openSQLFilePanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Menu(tr("최근 SQL 파일")) {
                    ForEach(app.recentSQLFiles, id: \.self) { url in
                        Button(url.lastPathComponent) { app.openSQLFile(url) }
                    }
                    Divider()
                    Button(tr("목록 지우기")) { app.clearRecentSQLFiles() }
                }
                Button(tr("저장")) { app.saveSelectedTab() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!app.canSaveQueryTab)
                Button(tr("다른 이름으로 저장…")) { app.saveSelectedTab(saveAs: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!app.canSaveQueryTab)
            }
            CommandGroup(after: .appInfo) {
                Button(tr("업데이트 확인…")) { UpdateController.shared.checkNow() }
            }
            CommandGroup(after: .help) {
                Button(tr("새로운 기능")) { app.releaseNotesSince = nil; app.showReleaseNotes = true }
                Button(tr("문제 보고…")) { app.showProblemReport = true }
            }
            CommandMenu(tr("데이터베이스")) {
                Button(tr("스키마 새로고침")) { Task { await app.refreshSchema() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(tr("보고 있는 접속 끊기")) {
                    if let id = app.selectedProfileID { Task { await app.disconnect(id) } }
                }
                Button(tr("모든 접속 끊기")) { Task { await app.disconnectAll() } }
                Divider()
                Button(tr("객체 빠른 찾기…")) { app.showQuickOpen = true }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(app.state != .connected || app.selectedProfile?.kind == .redis)
                Button(tr("쿼리 히스토리…")) { app.showHistory = true }
                    .keyboardShortcut("y", modifiers: .command)
            }
        }

        // 새로운 기능 (버전별 변경 내용)
        Window(tr("새로운 기능"), id: "release-notes") {
            ReleaseNotesView()
                .environment(app)
                .environment(settings)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // ER 다이어그램 창 (여러 개 열 수 있음)
        WindowGroup(tr("ER 다이어그램"), id: "diagram", for: UUID.self) { $id in
            DiagramWindow(id: id)
                .environment(app)
                .environment(settings)
                .id(settings.language)
        }
        .defaultSize(width: 1100, height: 760)

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}
