import Foundation

// 스키마 비교 · 연결 시간 제한 번역
extension L10nEnglish {
    static let compare: [String: String] = [
        "DB 서버가 %@초 안에 연결되지 않았어요. 주소 · 포트와 네트워크(VPN · SSH 터널)를 확인하세요.": "The DB server didn't connect within %@ seconds. Check the address, port and network (VPN, SSH tunnel).",
        "다시 시도": "Try Again",
        "복사 (%@개, ⌘C)": "Copy (%@ items, ⌘C)",
        "보정 SQL · %@개 선택": "Fix SQL · %@ selected",
        "선택한 %@개 SQL 복사": "Copy SQL for %@ Selected",
        "기준 접속 %@ 연결 실패": "Couldn't connect to source %@",
        "대상 접속 %@ 연결 실패": "Couldn't connect to target %@",
        "스키마 비교를 취소했어요.": "Schema comparison canceled.",
    ]
}
