import Foundation

/// 영어 번역표 (키 = 소스의 한국어 문장). base 는 생성 파일, extra 는 직접 추가한 문장.
enum L10nEnglish {
    static let table: [String: String] = base.merging(extra) { _, new in new }

    static let extra: [String: String] = [
        "앱": "App",
        // 설정 화면
        "1.33.3 (갓디비 패치)": "1.33.3 (GodDB patch)",
        "1.5 (Homebrew, 별도 설치)": "1.5 (Homebrew, installed separately)",
        "라이선스": "Licenses",
        "언어": "Language",
        "바꾸면 바로 적용돼요. 메뉴 막대는 앱을 다시 시작해야 바뀌어요.": "Applies right away. The menu bar may update after restarting the app.",
        "지금 시스템 언어: %@": "Current system language: %@",
        "버전": "Version",
        "소스 코드": "Source code",
        "정보": "About",
        "오픈소스 %@개": "%@ open source packages",
        "갓디비는 오픈소스예요. MIT 라이선스에 따라 자유롭게 쓰고, 고치고, 배포할 수 있어요. 저작권 표시와 라이선스 문구만 함께 남겨 주세요.": "GodDB is open source. Under the MIT License you can use, modify and distribute it freely — just keep the copyright notice and license text.",
        "전체 라이선스 문구는 위 링크에서 볼 수 있어요.": "The full license text is available at the link above.",
        "MySQL 드라이버": "MySQL driver",
        "PostgreSQL 드라이버 — 결과를 텍스트 형식으로 받도록 1줄 수정 (Vendor/postgres-nio/GODDB_PATCH.md)": "PostgreSQL driver — one-line change to receive results in text format (Vendor/postgres-nio/GODDB_PATCH.md)",
        "NIOSSL 에는 BoringSSL(OpenSSL/ISC 계열 라이선스)이 포함돼요.": "NIOSSL includes BoringSSL (OpenSSL/ISC-style licenses).",
        "SQL Server 드라이버. 갓디비에 포함되지 않고 brew install freetds 로 설치한 라이브러리를 실행 시 동적으로 연결해요.": "SQL Server driver. Not bundled with GodDB — the library installed with brew install freetds is linked dynamically at runtime.",
    ]
}
