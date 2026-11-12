import Foundation
import MySQLNIO
import PostgresNIO

/// 상태창(로그 패널)에 쌓이는 항목.
public struct LogEntry: Identifiable, Sendable, Hashable {
    public enum Level: String, Sendable { case info, success, warning, error }
    public enum Source: String, Sendable {
        case connection = "접속"
        case query = "쿼리"
        case schema = "스키마"
        case compare = "비교"
        case app = "앱"

        /// 화면 표시용 이름 (현재 언어)
        public var title: String { tr(rawValue) }
    }

    public let id = UUID()
    public let date: Date
    public let level: Level
    public let source: Source
    public let message: String
    /// 원본 오류, 실행한 SQL 등 자세한 내용
    public let detail: String?
    /// 해결 방법 안내
    public let hint: String?

    public init(date: Date = Date(), level: Level, source: Source, message: String,
                detail: String? = nil, hint: String? = nil) {
        self.date = date
        self.level = level
        self.source = source
        self.message = message
        self.detail = detail
        self.hint = hint
    }

    /// 복사용 전체 텍스트
    public var fullText: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var parts = ["[\(f.string(from: date))] [\(source.title)] \(message)"]
        if let hint { parts.append(tr("해결 방법: %@", "\(hint)")) }
        if let detail { parts.append(detail) }
        return parts.joined(separator: "\n")
    }
}

/// 오류를 사람이 읽을 수 있는 한국어 메시지 + 해결 힌트로 바꾼다.
public enum ErrorText {
    public struct Described: Sendable {
        public let message: String
        public let hint: String?
        public let raw: String
    }

    public static func describe(_ error: any Error) -> Described {
        let raw = rawText(error)

        if let mysql = error as? MySQLError {
            switch mysql {
            case .server(let packet):
                return .init(message: "[\(packet.errorCode.rawValue)] \(packet.errorMessage)",
                             hint: serverHint(code: Int(packet.errorCode.rawValue), message: packet.errorMessage), raw: raw)
            case .invalidSyntax(let m):
                return .init(message: tr("SQL 문법 오류: %@", "\(m)"), hint: tr("커서 위치의 구문만 실행돼요. 세미콜론(;)으로 구문을 구분했는지 확인해 주세요."), raw: raw)
            case .duplicateEntry(let m):
                return .init(message: tr("중복 키: %@", "\(m)"), hint: nil, raw: raw)
            case .closed:
                return .init(message: tr("DB 연결이 끊어졌어요."), hint: tr("사이드바에서 접속을 다시 눌러 재연결해 주세요."), raw: raw)
            case .secureConnectionRequired:
                return .init(message: tr("이 계정은 TLS 연결이 필요해요."), hint: tr("접속 편집에서 'TLS 사용'을 켜 주세요."), raw: raw)
            default:
                return .init(message: mysql.message, hint: nil, raw: raw)
            }
        }

        if let pg = error as? PSQLError {
            if let info = pg.serverInfo, let message = info[.message] {
                let state = info[.sqlState] ?? ""
                var text = "[\(state)] \(message)"
                if let detail = info[.detail] { text += "\n\(detail)" }
                return .init(message: text, hint: postgresHint(state) ?? info[.hint], raw: raw)
            }
            if pg.code == .connectionError, let underlying = pg.underlying {
                return describe(underlying)
            }
            return .init(message: tr("PostgreSQL 오류: %@", "\(pg.code)"), hint: nil, raw: raw)
        }
        if let ms = error as? MSSQLError {
            return .init(message: "[\(ms.number)] \(ms.message)", hint: mssqlHint(ms.number), raw: raw)
        }
        if let e = error as? SSHTunnelError {
            let d = e.errorDescription ?? raw
            if case .timeout = e {
                return .init(message: d, hint: tr("바스티온까지 네트워크가 닿는지(VPN), SSH 포트가 맞는지 확인해 주세요."), raw: raw)
            }
            return .init(message: d, hint: sshHint(d), raw: raw)
        }
        if let e = error as? DBError {
            return .init(message: e.errorDescription ?? raw, hint: nil, raw: raw)
        }
        if let io = error as? IOError {
            return describeErrno(io.errnoCode, raw: raw)
        }
        if let ch = error as? ChannelError, case .connectTimeout = ch {
            return describeErrno(ETIMEDOUT, raw: raw)
        }

        let lower = raw.lowercased()
        if lower.contains("connection refused") || lower.contains("econnrefused") {
            return .init(message: tr("서버가 연결을 거부했어요."), hint: tr("호스트와 포트가 맞는지, DB 서버가 켜져 있는지 확인해 주세요. 사내망/VPN이 필요한 서버일 수도 있어요."), raw: raw)
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return .init(message: tr("연결 시간이 초과됐어요."), hint: tr("네트워크(VPN) 연결이나 보안 그룹에서 이 IP가 허용돼 있는지 확인해 주세요."), raw: raw)
        }
        if lower.contains("nodename nor servname") || lower.contains("unknown host") || lower.contains("resolve") {
            return .init(message: tr("호스트 이름을 찾을 수 없어요."), hint: tr("호스트 주소 오타를 확인해 주세요. 사내 도메인이면 VPN이 필요할 수 있어요."), raw: raw)
        }
        if lower.contains("nioss") || lower.contains("ssl") || lower.contains("tls") || lower.contains("handshake") {
            return .init(message: tr("TLS 연결에 실패했어요."), hint: tr("서버가 TLS를 지원하지 않으면 접속 편집에서 'TLS 사용'을 꺼 보세요."), raw: raw)
        }
        if let local = error as? LocalizedError, let d = local.errorDescription {
            return .init(message: d, hint: nil, raw: raw)
        }
        return .init(message: raw, hint: nil, raw: raw)
    }

    /// 사용자/비밀번호 인증 실패(1045) 여부
    public static func isAuthFailure(_ error: any Error) -> Bool {
        if case .server(let packet) = error as? MySQLError { return packet.errorCode.rawValue == 1045 }
        if let pg = error as? PSQLError, pg.serverInfo?[.sqlState] == "28P01" { return true }
        if let ms = error as? MSSQLError, ms.number == 18456 { return true }
        return false
    }

    static func postgresHint(_ state: String) -> String? {
        switch state {
        case "28P01", "28000": return tr("사용자 이름 또는 비밀번호가 틀렸어요. 접속 편집에서 비밀번호를 다시 입력해 주세요.")
        case "3D000": return tr("접속 설정의 DB 이름이 서버에 없어요. (PostgreSQL 은 DB 마다 따로 접속해요)")
        case "3F000": return tr("스키마가 없어요. 사이드바에서 스키마를 다시 골라 주세요.")
        case "42P01": return tr("테이블이 없어요. 사이드바에서 선택된 스키마가 맞는지 확인해 주세요.")
        case "42703": return tr("컬럼 이름이 틀렸어요. PostgreSQL 은 따옴표 없는 이름을 소문자로 바꿔요.")
        case "42601": return tr("SQL 문법 오류예요. PostgreSQL 은 식별자에 백틱(`) 대신 큰따옴표(\")를 써요.")
        case "42501": return tr("권한이 없어요. DBA에게 권한을 요청해 주세요.")
        case "25006": return tr("읽기전용 접속이라 서버가 변경을 거부했어요.")
        case "57014": return tr("쿼리가 취소됐어요 (시간 초과 등).")
        default: return nil
        }
    }

    static func mssqlHint(_ number: Int) -> String? {
        switch number {
        case 18456: return tr("사용자 이름 또는 비밀번호가 틀렸어요. SQL Server 인증(sa 등) 계정인지도 확인해 주세요.")
        case 4060: return tr("접속 설정의 기본 DB 를 열 수 없어요. 이름과 권한을 확인해 주세요.")
        case 208: return tr("개체(테이블/뷰)가 없어요. 사이드바에서 DB 가 맞는지, 스키마(dbo 등)를 붙였는지 확인해 주세요.")
        case 207: return tr("컬럼 이름이 틀렸어요.")
        case 102, 156: return tr("SQL 문법 오류예요. SQL Server 는 LIMIT 대신 TOP, 식별자는 [대괄호]를 써요.")
        case 229, 230, 262: return tr("권한이 없어요. DBA에게 권한을 요청해 주세요.")
        case 20009, 20002: return tr("서버에 연결할 수 없어요. 호스트/포트, VPN, 방화벽(1433)을 확인해 주세요.")
        case 20017, 20047: return tr("연결이 끊겼어요. TLS 설정이 서버와 맞지 않으면 접속 편집에서 'TLS 사용'을 바꿔 보세요.")
        default: return nil
        }
    }

    static func describeErrno(_ code: Int32, raw: String) -> Described {
        switch code {
        case ECONNREFUSED:
            return .init(message: tr("서버가 연결을 거부했어요. (포트가 닫혀 있음)"),
                         hint: tr("호스트와 포트가 맞는지, DB 서버(또는 Docker 컨테이너)가 켜져 있는지 확인해 주세요."), raw: raw)
        case ETIMEDOUT:
            return .init(message: tr("연결 시간이 초과됐어요."),
                         hint: tr("VPN 연결 여부와, 보안 그룹/방화벽에서 이 PC가 허용돼 있는지 확인해 주세요."), raw: raw)
        case EHOSTUNREACH, ENETUNREACH:
            return .init(message: tr("서버까지 네트워크 경로가 없어요."),
                         hint: tr("VPN 연결을 확인해 주세요. 사내망 IP라면 시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 GodDB를 허용해야 할 수 있어요."), raw: raw)
        case EPERM, EACCES:
            return .init(message: tr("운영체제가 네트워크 연결을 막았어요."),
                         hint: tr("시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 GodDB를 허용하거나, 회사 보안 프로그램(방화벽)을 확인해 주세요."), raw: raw)
        default:
            return .init(message: tr("네트워크 오류 (errno %@: %@)", "\(code)", "\(String(cString: strerror(code)))"), hint: nil, raw: raw)
        }
    }

    static func rawText(_ error: any Error) -> String {
        let described = String(describing: error)
        let localized = (error as? LocalizedError)?.errorDescription
        if let localized, localized != described { return "\(localized)\n(\(described))" }
        return described
    }

    static func serverHint(code: Int, message: String) -> String? {
        switch code {
        case 1045: return tr("사용자 이름 또는 비밀번호가 틀렸어요. 접속 편집에서 비밀번호를 다시 입력해 주세요.")
        case 1044, 1142, 1143: return tr("이 계정에 해당 DB/테이블 권한이 없어요. DBA에게 권한을 요청해 주세요.")
        case 1049: return tr("DB 이름이 없어요. 접속 편집의 '기본 DB'를 확인해 주세요.")
        case 1146: return tr("테이블이 없어요. 사이드바에서 현재 선택된 DB가 맞는지 확인해 주세요.")
        case 1054: return tr("컬럼 이름이 틀렸어요. 사이드바에서 테이블을 펼쳐 컬럼명을 확인해 주세요.")
        case 1064: return tr("SQL 문법 오류예요. 오류 위치('near ...') 앞부분을 확인해 주세요.")
        case 1792: return tr("읽기전용 접속이라 서버가 변경을 거부했어요.")
        case 2013, 2006: return tr("쿼리 도중 연결이 끊겼어요. 다시 연결해 주세요.")
        case 3024: return tr("쿼리 실행 시간 제한을 넘었어요. 조건을 좁히거나 LIMIT을 줄여 주세요.")
        default: return nil
        }
    }

    static func sshHint(_ message: String) -> String? {
        let m = message.lowercased()
        if m.contains("permission denied") {
            return tr("SSH 키 파일 또는 SSH 사용자 이름이 맞는지 확인해 주세요. 키 파일 권한은 600 이어야 해요 (chmod 600 키파일).")
        }
        if m.contains("host key verification failed") || m.contains("remote host identification has changed") {
            return tr("바스티온의 호스트 키가 바뀌었어요. ~/.ssh/known_hosts 에서 해당 호스트 줄을 지운 뒤 다시 시도해 주세요.")
        }
        if m.contains("could not resolve hostname") {
            return tr("바스티온 호스트 주소를 확인해 주세요.")
        }
        if m.contains("unprotected private key") || m.contains("bad permissions") {
            return tr("키 파일 권한이 너무 열려 있어요. 터미널에서 chmod 600 키파일 을 실행해 주세요.")
        }
        return nil
    }
}
