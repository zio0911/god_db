import Foundation

/// 쿼리 실행 시간 제한 (설정 > 일반 > 쿼리). 기본 30분, 0 이면 없음 (#198). AI 가 만든 큰 쿼리 등 오래 도는 정상 작업을 감안
/// 앱이 시간을 재서 취소하고, PostgreSQL · MySQL 은 연결할 때 서버 세션에도 같은 제한을 건다
/// (앱이 멈추거나 연결이 끊겨도 서버에서 쿼리가 계속 돌지 않게).
public enum QueryTimeLimit {
    public static let key = "queryTimeoutSeconds"
    public static let defaultSeconds = 1800

    /// 설정 값 (초). 한 번도 바꾸지 않았으면 기본 30분
    public static var seconds: Int {
        (UserDefaults.standard.object(forKey: key) as? Int) ?? defaultSeconds
    }
}
