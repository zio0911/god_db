import Foundation

// Amazon Redshift 번역
extension L10nEnglish {
    static let redshift: [String: String] = [
        "Redshift 는 기본 키를 강제하지 않아 같은 키의 행이 여러 개일 수 있어서, 결과 표에서 고치지 않아요. UPDATE 문으로 수정하세요.": "Redshift doesn't enforce primary keys, so several rows can share a key. Results can't be edited in the grid; use an UPDATE statement.",
    ]
}
