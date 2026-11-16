import AppKit
import GodDBCore
import UniformTypeIdentifiers

/// 쿼리 탭 ↔ .sql 파일 (열기 ⇧⌘O · 저장 ⌘S · 다른 이름으로 저장 ⇧⌘S · 최근 파일 · 끌어 놓기)
extension AppState {
    static let recentFilesKey = "recentSQLFiles"
    static let sqlType = UTType(filenameExtension: "sql") ?? .plainText

    var recentSQLFiles: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.recentFilesKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func noteRecent(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: Self.recentFilesKey) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: Self.recentFilesKey)
    }

    func clearRecentSQLFiles() {
        UserDefaults.standard.removeObject(forKey: Self.recentFilesKey)
    }

    func openSQLFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.sqlType, .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openSQLFile(url) }
    }

    /// 보고 있는 접속의 새 탭으로 연다 (이미 연 파일이면 그 탭으로)
    func openSQLFile(_ url: URL) {
        if let open = tabs.first(where: { $0.fileURL == url }) {
            selectTab(open.id)
            return
        }
        let text: String
        do {
            var enc = String.Encoding.utf8
            text = try String(contentsOf: url, usedEncoding: &enc)
        } catch {
            logError(error, .app, context: tr("%@ 파일을 열지 못했어요", url.lastPathComponent))
            return
        }
        guard let id = addTab(text: text, title: url.lastPathComponent) else { return }
        update(id) {
            $0.fileURL = url
            $0.savedText = text
        }
        noteRecent(url)
        log(.info, .app, tr("%@ 파일을 열었어요", url.lastPathComponent))
    }

    /// 파일에 저장. 처음이거나 saveAs 면 저장 위치를 묻는다.
    func saveSelectedTab(saveAs: Bool = false) {
        guard let i = selectedTabIndex else { return }
        let tab = tabs[i]
        var url = tab.fileURL
        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.sqlType]
            panel.nameFieldStringValue = (tab.fileURL?.deletingPathExtension().lastPathComponent ?? tab.title) + ".sql"
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            url = picked
        }
        guard let url else { return }
        do {
            try tab.text.write(to: url, atomically: true, encoding: .utf8)
            update(tab.id) {
                $0.fileURL = url
                $0.savedText = tab.text
                $0.customTitle = url.lastPathComponent
            }
            noteRecent(url)
            log(.success, .app, tr("%@ 에 저장했어요", url.lastPathComponent))
        } catch {
            logError(error, .app, context: tr("%@ 파일을 저장하지 못했어요", url.lastPathComponent))
        }
    }

    /// 저장 메뉴를 쓸 수 있는지 (Redis 화면의 ⌘S 와 겹치지 않게 쿼리 탭일 때만)
    var canSaveQueryTab: Bool { mode == .query && selectedRedis == nil && selectedTabIndex != nil }
}
