import AppKit
import SwiftUI

@main
struct GodDBApp: App {
    @State private var app = AppState()

    init() {
        // `swift run` 으로 띄워도 Dock 아이콘과 메뉴가 있는 일반 앱으로 동작하게 한다.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("갓디비") {
            ContentView()
                .environment(app)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("새 쿼리 탭") { app.addTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("새 접속…") { app.newProfile() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("데이터베이스") {
                Button("스키마 새로고침") { Task { await app.refreshSchema() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("보고 있는 접속 끊기") {
                    if let id = app.selectedProfileID { Task { await app.disconnect(id) } }
                }
                Button("모든 접속 끊기") { Task { await app.disconnectAll() } }
            }
        }
    }
}
