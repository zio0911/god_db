import Foundation

// DBeaver 접속 정보 가져오기 번역
extension L10nEnglish {
    static let dbeaverImport: [String: String] = [
        "DBeaver 접속 정보 가져오기…": "Import DBeaver Connections…",
        "DBeaver 접속 정보 파일이 아니에요. (DBeaver: 파일 > 내보내기 > DBeaver > 프로젝트 로 만든 .dbp, 또는 작업 폴더의 data-sources.json)": "This is not a DBeaver connection file. (Use a .dbp made with File > Export > DBeaver > Project in DBeaver, or data-sources.json from the workspace folder.)",
        "DBeaver 파일에 접속이 없어요.": "The DBeaver file has no connections.",
        "DBeaver 에서 내보낸 프로젝트 파일(.dbp) 또는 작업 폴더의 data-sources.json 을 고르세요.": "Choose a project file (.dbp) exported from DBeaver, or data-sources.json in the DBeaver workspace folder.",
        "GodDB 에서 내보낸 접속 정보 파일(.json) 또는 DBeaver 파일(.dbp · data-sources.json)을 고르세요.": "Choose a connection file (.json) exported from GodDB, or a DBeaver file (.dbp or data-sources.json).",
        "SSH 비밀번호 방식이에요. GodDB 는 키 파일이나 ssh-agent 로 연결하니 접속 편집에서 키를 지정해 주세요.": "Uses SSH password authentication. GodDB connects with a key file or ssh-agent, so set a key in the connection editor.",
        "SSH 사용자 이름이 없어요. 접속 편집에서 넣어 주세요.": "No SSH user name. Enter it in the connection editor.",
        "SSH 점프 서버 설정은 가져오지 않았어요.": "SSH jump server settings were not imported.",
        "가져오기 · 내보내기": "Import · Export",
        "사용자 이름이 없어요. 접속 편집에서 넣어 주세요.": "No user name. Enter it in the connection editor.",
        "지원하지 않는 접속 %@개는 건너뛰었어요: %@": "Skipped %@ unsupported connections: %@",
        "프록시 설정은 가져오지 않았어요.": "Proxy settings were not imported.",
            "DBeaver 에 저장된 비밀번호도 가져와 키체인에 넣어요.": "The password saved in DBeaver is imported into the Keychain too.",
]
}
