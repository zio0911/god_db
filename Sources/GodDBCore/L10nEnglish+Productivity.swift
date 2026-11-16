import Foundation

// 1.3 생산성 기능 번역 (쿼리 취소, 히스토리, 접속 환경, 결과 복사, 편집기, 파일, 빠른 찾기, 가져오기)
extension L10nEnglish {
    static let productivity: [String: String] = [
        // 쿼리 취소 · 실행 시간 제한
        "10분": "10 min",
        "1분": "1 min",
        "30분": "30 min",
        "30초": "30 sec",
        "5분": "5 min",
        "시간을 넘기면 쿼리를 자동으로 취소해요. 실행 중에는 언제든 [취소] 또는 ⌘. 로 멈출 수 있어요.": "Queries that run longer are cancelled automatically. You can always stop a running query with [Cancel] or ⌘.",
        "실행 시간 제한": "Time Limit",
        "실행 시간 제한 %@초를 넘어 취소해요.": "Cancelling: the %@ second time limit was exceeded.",
        "실행 중… %@초": "Running… %@ s",
        "실행 중인 쿼리 멈추기 (⌘.)": "Stop the running query (⌘.)",
        "쿼리 취소 실패": "Could not cancel the query",
        "쿼리 취소를 요청했어요.": "Asked the server to cancel the query.",
        "쿼리 취소를 요청했어요. SQL Server 는 세션을 다시 연결해요 (열린 트랜잭션은 롤백돼요).": "Asked the server to cancel the query. SQL Server reconnects the session (any open transaction is rolled back).",
        "쿼리를 취소했어요.": "The query was cancelled.",
    ]
}
