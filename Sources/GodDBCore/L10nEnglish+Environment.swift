import Foundation

// 접속 환경(개발 · 스테이징 · 운영) 번역
extension L10nEnglish {
    static let environment: [String: String] = [
        "개발": "Dev",
        "스테이징": "Staging",
        "운영": "Prod",
        "운영 접속 · %@": "Production · %@",
        "운영 접속에서 데이터를 바꿔요": "This changes data on a production connection",
        "운영 접속은 사이드바 · 탭에 빨간색으로 표시하고, 데이터를 바꾸는 문장을 실행하기 전에 항상 확인해요.": "Production connections are marked red in the sidebar and tabs, and you're always asked before running statements that change data.",
        "운영 접속이에요. 데이터를 바꾸는 문장 %@개를 실행해요.": "This is a production connection. %@ statements that change data will run.",
        "운영 접속이에요. 적용하면 운영 데이터가 바뀌어요.": "This is a production connection. Applying changes production data.",
        "표시 안 함": "None",
        "환경": "Environment",
    ]
}
