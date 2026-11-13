import Foundation

// 결과 내보내기 번역
extension L10nEnglish {
    static let export: [String: String] = [
        "%@ 내보내는 중 %@ / %@행": "Exporting %@ · %@ / %@ rows",
        "%@ 내보내는 중 %@행": "Exporting %@ · %@ rows",
        "%@ 저장 · Excel 시트 최대 행 수를 넘어 %@행까지만 저장했어요 · %@": "Saved %@ · exceeded the Excel sheet row limit, saved the first %@ rows · %@",
        "%@ 저장 · 보이는 행 %@행 · %@": "Saved %@ · %@ visible rows · %@",
        "%@ 저장 · 전체 %@행인데 %@행을 저장했어요. 조회 중 데이터가 바뀌었거나 정렬 기준이 없어 생긴 차이일 수 있어요 · %@": "Saved %@ · the query has %@ rows but %@ were saved. Data may have changed during export, or there is no sort key · %@",
        "%@ 저장 · 전체 데이터 %@행 (COUNT 와 일치) · %@초 · %@": "Saved %@ · all %@ rows (matches COUNT) · %@s · %@",
        "Confluence · Jira · 슬랙에 붙여 넣기 좋은 표. 큰 결과에는 맞지 않아요.": "A table for pasting into Confluence, Jira or Slack. Not suited to large results.",
        "Excel 파일을 만들지 못했어요: %@": "Could not create the Excel file: %@",
        "INSERT 문 하나에 100행씩. 값은 모두 문자열 리터럴로 써요 (NULL 은 NULL).": "100 rows per INSERT statement. Values are written as string literals (NULL stays NULL).",
        "결과를 파일로 저장: CSV · TSV · Excel · JSON · SQL INSERT · Markdown (보이는 행 또는 쿼리 전체 데이터)": "Save the result to a file: CSV · TSV · Excel · JSON · SQL INSERT · Markdown (visible rows or the whole query result)",
        "내보내기": "Export",
        "내보내기 실패": "Export failed",
        "내보내기: 정렬 기준이 없어 페이지 사이에 행이 빠지거나 겹칠 수 있어요": "Export: no sort key, rows may be missed or repeated between pages",
        "내보내기를 취소했어요 (파일 삭제)": "Export cancelled (file deleted)",
        "대상 테이블": "Target table",
        "시트 하나에 최대 1,048,575행. 넘으면 그 앞까지만 저장하고 알려줘요. 숫자로 바꿔도 값이 그대로인 것만 숫자 셀로 써요 (앞자리 0 은 문자).": "Up to 1,048,575 rows per sheet; beyond that only the first rows are saved and you are told. Only values that stay identical as numbers become number cells (leading zeros stay text).",
        "정렬 기준(ORDER BY 또는 결과에 포함된 기본 키)이 없어 페이지 사이에 행이 빠지거나 겹칠 수 있어요. ORDER BY 를 넣고 다시 실행하는 걸 권장해요.": "No sort key (ORDER BY or a primary key in the result), so rows may be missed or repeated between pages. Adding ORDER BY and re-running is recommended.",
        "쿼리 전체 결과 (전체 %@행, 페이지 단위로 다시 조회)": "Whole query result (%@ rows, fetched again page by page)",
        "쿼리 전체 결과 (페이지 단위로 다시 조회)": "Whole query result (fetched again page by page)",
        "파일을 쓸 수 없어요: %@": "Cannot write the file: %@",
        "행마다 {컬럼: 값} 객체. NULL 은 null.": "One {column: value} object per row. NULL becomes null.",
        "형식": "Format",
        "화면에 보이는 페이지가 아니라 쿼리의 전체 데이터를 5,000행씩 나눠 조회하며 파일에 바로 써요. 시작 전에 COUNT 로 전체 행 수를 확인하고, 끝나면 저장한 행 수와 맞춰 봐요.": "Not just the visible page: the whole query result is fetched 5,000 rows at a time and written straight to the file. The total is checked with COUNT first and compared with the saved row count at the end.",
    ]
}
