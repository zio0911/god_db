import Foundation

// CSV 가져오기 번역
extension L10nEnglish {
    static let csvImport: [String: String] = [
        "%@ 에 %@행 가져옴": "%@: imported %@ rows",
        "%@행 · %@열": "%@ rows · %@ columns",
        "%@행 가져오기": "Import %@ Rows",
        "CSV 가져오기 → %@": "Import CSV → %@",
        "CSV 가져오기 실패 (모두 되돌림)": "CSV import failed (all rolled back)",
        "CSV 가져오기…": "Import CSV…",
        "가져올 CSV / TSV 파일을 고르세요": "Choose a CSV or TSV file to import",
        "건너뛰기": "Skip",
        "다른 파일…": "Other File…",
        "머리글이 컬럼 이름과 같으면 자동으로 맞춰요. 모든 행을 한 트랜잭션으로 넣고, 하나라도 실패하면 모두 되돌려요.": "Headers that match column names are mapped automatically. All rows go in one transaction; if any row fails, everything is rolled back.",
        "빈 칸은 NULL": "Empty cells as NULL",
        "세미콜론 ;": "Semicolon ;",
        "쉼표 ,": "Comma ,",
        "첫 줄은 머리글": "First row is header",
        "탭": "Tab",
        "파일 고르기…": "Choose File…",
    ]
}
