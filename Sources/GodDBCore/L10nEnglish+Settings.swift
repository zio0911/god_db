import Foundation

// 설정 정리 번역
extension L10nEnglish {
    static let settings: [String: String] = [
        "1년 (365일)": "1 year (365 days)",
        "3개월 (90일)": "3 months (90 days)",
        "6개월 (180일)": "6 months (180 days)",
        "AI 어시스턴트 사용": "Use AI assistant",
        "감사 로그(접속, 실행한 SQL, 데이터 변경, 오류)를 날짜별 파일로 남겨요. 조회 결과 행은 남기지 않아요. 파일은 지우지 않고 영구 보관해요.": "Writes the audit log (connections, executed SQL, data changes, errors) to daily files. Result rows are not logged. Files are kept forever.",
        "감사 로그를 날짜별 파일로 남기고, %@일이 지난 파일은 자동으로 지워요. 조회 결과 행은 남기지 않아요.": "Writes the audit log to daily files and deletes files older than %@ days. Result rows are not logged.",
        "끄면 도구 막대의 ✨ AI 어시스턴트 버튼과 오른쪽 패널이 사라져요.": "When off, the ✨ AI assistant button and side panel are hidden.",
        "보관 기간": "Keep for",
        "영구 보관": "Forever",
        "쿼리 탭의 튜닝 버튼(⌥⌘T)을 누르면 쿼리·테이블 구조·인덱스·실행 계획을 로컬 Ollama 에 보내 개선 SQL 과 추천 인덱스를 받아요. 끄면 튜닝 버튼이 사라져요.": "The query tab's Tune button (⌥⌘T) sends the query, table structure, indexes and plan to local Ollama for an improved query and suggested indexes. When off, the Tune button is hidden.",
    ]
}
