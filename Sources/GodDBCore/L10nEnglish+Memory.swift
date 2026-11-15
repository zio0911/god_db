import Foundation

// 메모리 안전 번역
extension L10nEnglish {
    static let memory: [String: String] = [
        "· 끝": "· end",
        "· 스크롤하면 더 불러와요": "· scroll to load more",
        "· 화면 최대 %@행 — 전체는 [내보내기]": "· up to %@ rows on screen — use Export for everything",
        "값이 너무 커서 앞부분만 불러온 칸이 있어 이 결과는 표에서 고칠 수 없어요. UPDATE 문으로 수정하세요.": "Some cells were too large and only their beginning was loaded, so this result can't be edited in the grid. Use an UPDATE statement.",
        "값이 커서 앞 1MB 만 보여요 (전체 %@). 이 화면에서는 편집할 수 없어요.": "The value is large, so only the first 1 MB is shown (total %@). It can't be edited here.",
        "다음 행 불러오기 실패": "Could not load more rows",
        "화면에는 %@행까지만 보여요. 전체 데이터는 [내보내기] 로 저장하세요.": "Only %@ rows are shown on screen. Use Export to save all data.",
    ]
}
