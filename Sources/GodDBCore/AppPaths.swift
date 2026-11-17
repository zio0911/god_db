import Foundation

/// 앱 데이터 위치. 화면 자동 테스트(GODDB_UI_TEST=1)에서는 임시 폴더를 써서 실제 접속 목록 · 탭 · 기록을 건드리지 않는다.
public enum AppPaths {
    private static let env = ProcessInfo.processInfo.environment

    /// scripts/ui-test.sh 로 띄운 화면 자동 테스트 실행인지
    public static let uiTest = env["GODDB_UI_TEST"] == "1"

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
