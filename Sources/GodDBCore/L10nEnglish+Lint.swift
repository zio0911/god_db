import Foundation

// 쿼리 편집기 빨간 밑줄 번역
extension L10nEnglish {
    static let lint: [String: String] = [
        "%@ 의 오타 같아요.": "Looks like a typo for %@.",
        "%@ 테이블에 %@ 컬럼이 없어요.": "Table %@ has no column %@.",
        "DB 검사: %@": "DB check: %@",
        "DB 에 검사 요청": "Ask the DB to check",
        "닫는 괄호가 없어요.": "Missing closing parenthesis.",
        "닫히지 않은 따옴표예요.": "Unclosed quote.",
        "닫히지 않은 주석이에요.": "Unclosed comment.",
        "비슷한 컬럼: %@": "Similar column: %@",
        "앞 항목과 사이에 콤마가 빠진 것 같아요.": "Looks like a comma is missing before this item.",
        "없는 컬럼, 빠진 콤마, 닫히지 않은 괄호 · 따옴표, 키워드 오타를 입력하는 동안 표시해요. 밑줄에 마우스를 올리면 이유가 나와요.": "Marks unknown columns, missing commas, unclosed parentheses or quotes, and keyword typos as you type. Hover over the underline to see why.",
        "여는 괄호가 없어요.": "Missing opening parenthesis.",
        "입력을 1초 멈추면 커서가 있는 구문을 DB 에 실행 없이 검사만 맡겨요 (MySQL · PostgreSQL PREPARE, SQL Server sp_describe_first_result_set). 실행 중이거나 PostgreSQL 트랜잭션이 열려 있으면 묻지 않아요.": "When you pause typing for a second, the statement at the cursor is sent to the DB to be checked without running it (MySQL and PostgreSQL PREPARE, SQL Server sp_describe_first_result_set). Skipped while a query is running or a PostgreSQL transaction is open.",
        "콤마 뒤에 항목이 없어요.": "Nothing after this comma.",
        "콤마 앞에 항목이 없어요.": "Nothing before this comma.",
        "콤마가 두 번 있어요.": "Duplicate comma.",
        "쿼리 오류에 빨간 밑줄": "Underline query errors in red",
    ]
}
