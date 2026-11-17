import Foundation

// 실수 방지(확인 창) 번역
extension L10nEnglish {
    static let safety: [String: String] = [
        "'%@' 접속을 삭제할까요?": "Delete the connection '%@'?",
        "'%@' 접속의 저장된 비밀번호를 보려고 해요": "show the saved password for '%@'",
        "%@ 저장된 비밀번호 보기 (본인 확인)": "%@: saved password shown (owner verified)",
        "비밀번호 보기": "Show Password",
        "비밀번호 가리기": "Hide Password",
        "DROP (객체 삭제)": "DROP (removes the object)",
        "TRUNCATE (모든 행 삭제)": "TRUNCATE (deletes all rows)",
        "WHERE 없는 DELETE (모든 행 삭제)": "DELETE without WHERE (deletes all rows)",
        "WHERE 없는 UPDATE (모든 행 변경)": "UPDATE without WHERE (changes all rows)",
        "결과 표에서 고치고 적용하지 않은 %@건은 사라져요.": "%@ unapplied edits in the result grid will be lost.",
        "결과 표에서 고치고 적용하지 않은 %@건이 사라져요.": "%@ unapplied edits in the result grid will be lost.",
        "되돌리기 어려운 문장이 있어요": "This can't easily be undone",
        "바뀐 설정으로 다시 연결하기": "reconnecting with the new settings",
        "버리고 계속": "Discard and Continue",
        "선택 영역이 없어서 편집기의 모든 문장(%@개, 변경 문 %@개)을 위에서부터 실행해요. 일부만 실행하려면 그 부분을 선택하세요.": "Nothing is selected, so all statements in the editor (%@, including %@ that change data) run from the top. Select a part to run only that.",
        "적용하지 않은 편집이 있어요": "You have unapplied edits",
        "접속 정보와 저장된 비밀번호, 이 접속의 쿼리 탭 %@개가 함께 지워져요. 되돌릴 수 없어요.": "The connection, its saved password and its %@ query tabs will be removed. This can't be undone.",
        "접속 정보와 저장된 비밀번호가 지워져요. 되돌릴 수 없어요.": "The connection and its saved password will be removed. This can't be undone.",
        "접속을 삭제하기": "deleting the connection",
    ]
}
