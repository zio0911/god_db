import AppKit
import GodDBCore
import SwiftUI

@main
struct GodDBApp: App {
    @State private var app = AppState()
    @State private var settings = AppSettings()

    init() {
        // `swift run` 으로 띄워도 Dock 아이콘과 메뉴가 있는 일반 앱으로 동작하게 한다.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup(tr("갓디비")) {
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
            CommandGroup(after: .newItem) {
                Button(tr("새 쿼리 탭")) { app.addTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button(tr("새 접속…")) { app.newProfile() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu(tr("데이터베이스")) {
                Button(tr("스키마 새로고침")) { Task { await app.refreshSchema() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(tr("보고 있는 접속 끊기")) {
                    if let id = app.selectedProfileID { Task { await app.disconnect(id) } }
                }
                Button(tr("모든 접속 끊기")) { Task { await app.disconnectAll() } }
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}
