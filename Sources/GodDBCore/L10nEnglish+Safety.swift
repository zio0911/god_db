import Foundation

// 실수 방지(확인 창) 번역
extension L10nEnglish {
    static let safety: [String: String] = [
        "'%@' 접속을 삭제할까요?": "Delete the connection '%@'?",
        "위험한 명령 실행 전 확인": "Confirm before dangerous statements",
        "위험한 명령 실행 전 확인을 켰어요": "Turned on confirmation before dangerous statements",
        "위험한 명령 실행 전 확인을 껐어요": "Turned off confirmation before dangerous statements",
        "WHERE 없는 DELETE · UPDATE, TRUNCATE, DROP, Redis 의 FLUSHALL · FLUSHDB · KEYS 등을 실행하기 전에 한 번 더 물어봐요. 운영 접속에서 데이터를 바꾸는 확인은 이 설정과 관계없이 항상 떠요.": "Asks once more before DELETE or UPDATE without WHERE, TRUNCATE, DROP, and Redis FLUSHALL, FLUSHDB, KEYS and similar. The confirmation for changing data on production connections always appears regardless of this setting.",
        "안전": "Safety",
        "Redis 서버가 %@초 안에 응답하지 않았어요. 주소 · 포트 · TLS 설정과 네트워크(SSH 터널)를 확인하세요.": "The Redis server didn't respond within %@ seconds. Check the address, port, TLS setting and network (SSH tunnel).",
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
