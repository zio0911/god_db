import Foundation

/// 앱 데이터 위치. 화면 자동 테스트(GODDB_UI_TEST=1)에서는 임시 폴더를 써서 실제 접속 목록 · 탭 · 기록을 건드리지 않는다.
public enum AppPaths {
    private static let env = ProcessInfo.processInfo.environment

    /// 화면 자동 테스트 복사본의 번들 ID (scripts/ui-test.sh 가 바꿔서 서명한다)
    public static let uiTestBundleID = "local.goddb.app.uitest"

    /// scripts/ui-test.sh 로 띄운 화면 자동 테스트 실행인지.
    /// 환경변수만으로는 켜지지 않는다 — 정식 앱을 GODDB_UI_TEST=1 로 띄워 감사 로그를 끄거나
    /// 데이터 폴더 · 비밀번호를 바꾸지 못하게, 테스트 복사본 번들 ID 일 때만 (#197)
    public static let uiTest = isUITest(env: env, bundleID: Bundle.main.bundleIdentifier)

    static func isUITest(env: [String: String], bundleID: String?) -> Bool {
        env["GODDB_UI_TEST"] == "1" && bundleID == uiTestBundleID
    }

    /// ~/Library/Application Support/GodDB (테스트면 GODDB_DATA_DIR)
    public static let dataDirectory: URL = {
        if uiTest, let dir = env["GODDB_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GodDB", isDirectory: true)
    }()

    /// 테스트 실행에서만: 로컬 Docker 테스트 DB 비밀번호 (키체인을 쓰지 않음)
    public static var uiTestPassword: String? { uiTest ? env["GODDB_UI_TEST_PASSWORD"] : nil }
}
