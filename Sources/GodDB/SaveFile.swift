import AppKit
import GodDBCore

/// 사용자가 고른 위치에 파일을 쓴다. 실패하면 알림 창으로 알리고 상태창에도 남긴다.
@MainActor
enum SaveFile {
    static func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            AppState.shared?.log(.success, .app, tr("%@ 에 저장했어요", url.lastPathComponent))
        } catch {
            AppState.shared?.logError(error, .app, context: tr("%@ 파일을 저장하지 못했어요", url.lastPathComponent))
            let alert = NSAlert(error: error)
            alert.messageText = tr("%@ 파일을 저장하지 못했어요", url.lastPathComponent)
            alert.runModal()
        }
    }
}
