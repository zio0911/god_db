import Foundation

// 쿼리 히스토리 · 탭 자동 저장 번역
extension L10nEnglish {
    static let history: [String: String] = [
        "%@ 접속이 연결되어 있지 않아 SQL 을 클립보드에 복사했어요.": "%@ isn't connected, so the SQL was copied to the clipboard.",
        "SQL · DB 검색 (여러 단어는 모두 포함)": "Search SQL or database (all words must match)",
        "기록 지우기…": "Clear History…",
        "되돌릴 수 없어요. 감사 로그는 지우지 않아요.": "This can't be undone. The audit log is not affected.",
        "실행한 쿼리 다시 찾기 (⌘Y)": "Find queries you ran (⌘Y)",
        "아직 실행한 쿼리가 없어요": "No queries yet",
        "이 접속만": "This connection only",
        "찾는 쿼리가 없어요": "No matching queries",
        "최근 %@건 · 두 번 누르면 편집기에 넣어요": "%@ recent · double-click to put it in the editor",
        "쿼리 히스토리…": "Query History…",
        "쿼리 히스토리를 모두 지울까요?": "Clear all query history?",
        "히스토리": "History",
        "편집기에 넣기": "Put in Editor",
        "SQL 복사": "Copy SQL",
        "지우기": "Clear",
        "히스토리 보관 기간": "Keep History",
        "7일": "7 days",
        "30일": "30 days",
        "90일": "90 days",
        "실행한 쿼리 기록을 지우지 않고 남겨요. 기록과 열어 둔 쿼리 탭 내용은 이 Mac 의 키체인 키로 암호화해서 저장해요.":
            "Query history is kept forever. History and open query tabs are encrypted with a key in this Mac's keychain.",
        "%@일이 지난 쿼리 기록은 자동으로 지워요. 기록과 열어 둔 쿼리 탭 내용은 이 Mac 의 키체인 키로 암호화해서 저장해요.":
            "Query history older than %@ days is deleted automatically. History and open query tabs are encrypted with a key in this Mac's keychain.",
    ]
}
