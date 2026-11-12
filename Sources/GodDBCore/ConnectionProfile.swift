import Foundation

/// 지원하는 DB 종류
public enum DatabaseKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case mysql
    case postgres
    case mssql
    case redis

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mysql: return "MySQL"
        case .postgres: return "PostgreSQL"
        case .mssql: return "SQL Server"
        case .redis: return "Redis"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .mysql: return 3306
        case .postgres: return 5432
        case .mssql: return 1433
        case .redis: return 6379
        }
    }

    /// 사이드바 DB 선택 드롭다운이 의미하는 것
    public var containerTitle: String {
        self == .postgres ? tr("스키마") : "DB"
    }

    /// SQL DB 인지 (Redis 는 아님)
    public var isSQL: Bool { self != .redis }
}

/// 저장되는 접속 정보. 비밀번호는 여기 담지 않고 키체인에 따로 보관한다.
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: DatabaseKind
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var database: String
    public var useTLS: Bool
    public var readOnly: Bool
    public var ssh: SSHConfig?
    /// true 면 비밀번호를 키체인에 저장, false 면 연결할 때마다 묻는다.
    public var savePassword: Bool

    public init(
        id: UUID = UUID(),
        kind: DatabaseKind = .mysql,
        name: String = tr("새 접속"),
        host: String = "",
        port: Int = 3306,
        username: String = "",
        database: String = "",
        useTLS: Bool = true,
        readOnly: Bool = false,
        ssh: SSHConfig? = nil,
        savePassword: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.database = database
        self.useTLS = useTLS
        self.readOnly = readOnly
        self.ssh = ssh
        self.savePassword = savePassword
    }

    // 예전 버전 profiles.json (savePassword 없음) 도 읽을 수 있게 직접 디코딩
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(DatabaseKind.self, forKey: .kind) ?? .mysql
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        useTLS = try c.decodeIfPresent(Bool.self, forKey: .useTLS) ?? true
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        ssh = try c.decodeIfPresent(SSHConfig.self, forKey: .ssh)
        savePassword = try c.decodeIfPresent(Bool.self, forKey: .savePassword) ?? true
    }
}

public struct SSHConfig: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    /// 개인키 파일 경로. 비어 있으면 ssh-agent / ~/.ssh/config 설정을 따른다.
    public var keyPath: String

    public init(host: String = "", port: Int = 22, username: String = "ec2-user", keyPath: String = "") {
        self.host = host
        self.port = port
        self.username = username
        self.keyPath = keyPath
    }
}

/// 접속 목록을 ~/Library/Application Support/GodDB/profiles.json 에 저장한다.
public struct ProfileStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appendingPathComponent("GodDB/profiles.json")
        }
    }

    public func load() -> [ConnectionProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ConnectionProfile].self, from: data)) ?? []
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
}
