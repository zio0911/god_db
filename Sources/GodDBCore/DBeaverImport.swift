import CommonCrypto
import CryptoKit
import Foundation

/// DBeaver 접속 정보를 읽는다.
///   - 프로젝트 내보내기 파일 (.dbp, ZIP: projects/<프로젝트>/.dbeaver/data-sources*.json)
///   - 작업 폴더의 data-sources.json (같은 폴더의 credentials-config.json 도 함께)
/// DBeaver 는 사용자 이름을 비밀번호와 함께 credentials-config.json 에 암호화해 둔다.
/// 여기서는 그 파일에서 **사용자 이름만** 꺼내고 비밀번호는 버린다 (돌려주지도, 남기지도 않는다).
public enum DBeaverImport {
    public struct Source: Equatable, Sendable {
        public var profile: ConnectionProfile
        /// 사용자에게 알려줄 점 (사용자 이름 없음, SSH 방식 등)
        public var notes: [String]
    }

    public struct Result: Equatable, Sendable {
        public var sources: [Source]
        /// 지원하지 않아 건너뛴 접속 이름
        public var skipped: [String]
    }

    public enum ParseError: LocalizedError, Equatable {
        case notDBeaver
        case noConnections
        case nothingSupported([String])

        public var errorDescription: String? {
            switch self {
            case .notDBeaver:
                return tr("DBeaver 접속 정보 파일이 아니에요. (DBeaver: 파일 > 내보내기 > DBeaver > 프로젝트 로 만든 .dbp, 또는 작업 폴더의 data-sources.json)")
            case .noConnections: return tr("DBeaver 파일에 접속이 없어요.")
            case .nothingSupported(let names): return tr("지원하지 않는 DB 예요: %@", names.joined(separator: ", "))
            }
        }
    }

    // MARK: - 진입점

    /// 파일을 읽는다. data-sources.json 이면 같은 폴더의 credentials-config.json 도 읽는다.
    public static func parse(fileAt url: URL) throws -> Result {
        let data = try Data(contentsOf: url)
        if ZipReader.isZip(data) { return try parse(data) }
        let creds = try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("credentials-config.json"))
        return try parse(data, credentials: creds)
    }

    /// .dbp(ZIP) 또는 data-sources.json 내용을 읽는다.
    public static func parse(_ data: Data, credentials: Data? = nil) throws -> Result {
        var projects: [Project] = []
        if ZipReader.isZip(data) {
            projects = try projectsInArchive(data)
        } else {
            guard let ds = dataSources(data) else { throw ParseError.notDBeaver }
            projects = [Project(name: "", dataSources: [ds], users: credentials.map(users(inCredentials:)) ?? [:])]
        }
        let multi = projects.filter { $0.dataSources.contains { !$0.connections.isEmpty } }.count > 1
        var sources: [Source] = []
        var skipped: [String] = []
        var total = 0
        for project in projects {
            for ds in project.dataSources {
                for (id, conn) in ds.connections {
                    total += 1
                    var folder = ds.folderPath(conn["folder"] as? String)
                    if multi { folder = folder.isEmpty ? project.name : project.name + "/" + folder }
                    if let s = source(id: id, conn: conn, group: folder, users: project.users[id]) {
                        sources.append(s)
                    } else {
                        skipped.append(conn["name"] as? String ?? id)
                    }
                }
            }
        }
        guard total > 0 else { throw ParseError.noConnections }
        guard !sources.isEmpty else { throw ParseError.nothingSupported(skipped.sorted()) }
        sources.sort { ($0.profile.group, $0.profile.name) < ($1.profile.group, $1.profile.name) }
        return Result(sources: sources, skipped: skipped.sorted())
    }

    /// data-sources.json 처럼 보이는지 (최상위 "connections" 안에 "provider" 가 있는 객체)
    public static func looksLikeDBeaver(_ data: Data) -> Bool {
        if ZipReader.isZip(data) { return true }
        return dataSources(data) != nil
    }

    // MARK: - 파일 구조

    struct DataSources {
        var connections: [String: [String: Any]]
        var folders: [String: [String: Any]]

        /// 폴더 키 → "상위/하위" 경로. 새 DBeaver 는 키가 이미 전체 경로, 옛 DBeaver 는 parent 를 따라간다.
        func folderPath(_ key: String?) -> String {
            guard let key, !key.isEmpty else { return "" }
            var parts = [key]
            var seen: Set<String> = [key]
            var cur = key
            while !cur.contains("/"), let parent = folders[cur]?["parent"] as? String, !parent.isEmpty, !seen.contains(parent) {
                parts.insert(parent, at: 0)
                seen.insert(parent)
                cur = parent
            }
            return parts.joined(separator: "/")
        }
    }

    struct Project {
        var name: String
        var dataSources: [DataSources]
        /// 접속 id → (DB 사용자, SSH 사용자)
        var users: [String: Users]
    }

    struct Users: Equatable {
        var database: String?
        var ssh: String?
    }

    static func dataSources(_ data: Data) -> DataSources? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conns = obj["connections"] as? [String: Any] else { return nil }
        var connections: [String: [String: Any]] = [:]
        for (k, v) in conns {
            guard let c = v as? [String: Any], c["provider"] is String else { return nil }
            connections[k] = c
        }
        let folders = (obj["folders"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
        return DataSources(connections: connections, folders: folders)
    }

    static func projectsInArchive(_ data: Data) throws -> [Project] {
        let files: [String: Data]
        do {
            files = try ZipReader.read(data) { path in
                let name = (path as NSString).lastPathComponent
                return path.contains("/.dbeaver/") && (name == "credentials-config.json"
                    || (name.hasPrefix("data-sources") && name.hasSuffix(".json")))
            }
        } catch {
            throw ParseError.notDBeaver
        }
        // projects/<이름>/.dbeaver/<파일>
        var byProject: [String: (ds: [DataSources], creds: Data?)] = [:]
        for (path, content) in files.sorted(by: { $0.key < $1.key }) {
            guard let r = path.range(of: "/.dbeaver/") else { continue }
            let dir = String(path[..<r.lowerBound])
            let name = (path as NSString).lastPathComponent
            var entry = byProject[dir] ?? ([], nil)
            if name == "credentials-config.json" {
                entry.creds = content
            } else if let ds = dataSources(content) {
                entry.ds.append(ds)
            }
            byProject[dir] = entry
        }
        guard !byProject.isEmpty else { throw ParseError.notDBeaver }
        return byProject.sorted { $0.key < $1.key }.map { dir, e in
            Project(name: (dir as NSString).lastPathComponent, dataSources: e.ds,
                    users: e.creds.map(users(inCredentials:)) ?? [:])
        }
    }

    // MARK: - 접속 하나

    static func kind(provider: String, driver: String) -> DatabaseKind? {
        switch provider.lowercased() {
        case "mysql", "mariadb": return .mysql
        case "postgresql": return .postgres
        case "sqlserver", "mssql": return .mssql
        default: return nil
        }
    }

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func source(id: String, conn: [String: Any], group: String, users: Users?) -> Source? {
        guard let kind = kind(provider: conn["provider"] as? String ?? "", driver: conn["driver"] as? String ?? "") else {
            return nil
        }
        let cfg = conn["configuration"] as? [String: Any] ?? [:]
        let url = string(cfg["url"]) ?? ""
        var p = ConnectionProfile(id: stableID(id), kind: kind, name: conn["name"] as? String ?? id, port: kind.defaultPort)
        p.useTLS = false
        p.host = string(cfg["host"])?.trimmingCharacters(in: .whitespaces) ?? ""
        if let port = string(cfg["port"]).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) { p.port = port }
        p.database = string(cfg["database"]) ?? ""
        // 주소(URL) 방식으로 만든 접속은 URL 에서 읽는다
        if p.host.isEmpty, let fromURL = DataGripImport.profile(fromJDBC: url) {
            p.host = fromURL.host
            p.port = fromURL.port
            if p.database.isEmpty { p.database = fromURL.database }
        }
        guard !p.host.isEmpty else { return nil }
        p.readOnly = conn["read-only"] as? Bool ?? false
        p.group = group
        p.username = users?.database ?? string(cfg["user"]) ?? ""

        var notes: [String] = []
        let handlers = cfg["handlers"] as? [String: Any] ?? [:]

        // TLS: SSL 설정이 켜져 있으면 사용, 서버 인증서 확인을 끈 설정이면 확인 안 함
        let props = cfg["provider-properties"] as? [String: Any] ?? [:]
        for (hid, h) in handlers {
            guard let h = h as? [String: Any], h["enabled"] as? Bool == true, hid.lowercased().contains("ssl") else { continue }
            p.useTLS = true
            let hp = (h["properties"] as? [String: Any] ?? [:]).merging(props) { a, _ in a }
            for (k, v) in hp {
                let key = k.lowercased(), value = (string(v) ?? "").lowercased()
                if key.hasSuffix("sslmode") {
                    if value == "disable" { p.useTLS = false }
                    if ["allow", "prefer", "require"].contains(value) { p.tlsVerify = false }
                }
                if key.contains("verify") && value == "false" { p.tlsVerify = false }
                if key.contains("trustservercertificate") && value == "true" { p.tlsVerify = false }
            }
        }
        if !handlers.keys.contains(where: { $0.lowercased().contains("ssl") }) {
            let u = url.lowercased()
            if ["usessl=true", "sslmode=require", "sslmode=verify", "ssl=true", "encrypt=true"].contains(where: u.contains) {
                p.useTLS = true
            }
        }

        // SSH 터널
        if let h = handlers["ssh_tunnel"] as? [String: Any], h["enabled"] as? Bool == true {
            let sp = h["properties"] as? [String: Any] ?? [:]
            var ssh = SSHConfig(host: string(sp["host"]) ?? "", port: string(sp["port"]).flatMap { Int($0) } ?? 22,
                                username: users?.ssh ?? string(h["user"]) ?? string(sp["user"]) ?? "", keyPath: "")
            switch (string(sp["authType"]) ?? "").uppercased() {
            case "PUBLIC_KEY":
                ssh.keyPath = string(sp["keyPath"]) ?? ""
            case "PASSWORD":
                notes.append(tr("SSH 비밀번호 방식이에요. GodDB 는 키 파일이나 ssh-agent 로 연결하니 접속 편집에서 키를 지정해 주세요."))
            default:
                break  // AGENT: 키 파일 없이 ssh-agent
            }
            if (string(sp["jumpServer.count"]).flatMap { Int($0) } ?? 0) > 0 {
                notes.append(tr("SSH 점프 서버 설정은 가져오지 않았어요."))
            }
            if ssh.username.isEmpty { notes.append(tr("SSH 사용자 이름이 없어요. 접속 편집에서 넣어 주세요.")) }
            p.ssh = ssh
        }
        if handlers.contains(where: { k, v in k.lowercased().contains("proxy") && (v as? [String: Any])?["enabled"] as? Bool == true }) {
            notes.append(tr("프록시 설정은 가져오지 않았어요."))
        }
        if p.username.isEmpty { notes.append(tr("사용자 이름이 없어요. 접속 편집에서 넣어 주세요.")) }
        notes.append(tr("비밀번호는 처음 연결할 때 입력해요."))
        return Source(profile: p, notes: notes)
    }

    /// DBeaver 접속 id → 늘 같은 UUID (다시 가져오면 같은 접속으로 인식)
    static func stableID(_ id: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(("dbeaver:" + id).utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50  // 버전 5 모양
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    // MARK: - credentials-config.json (사용자 이름만)

    /// DBeaver 가 credentials-config.json 을 잠그는 데 쓰는 고정 키 (DBeaver 소스에 공개된 값)
    static let credentialsKey: [UInt8] = [0xBA, 0xBB, 0x4A, 0x9F, 0x77, 0x4A, 0xB8, 0x53,
                                          0xC9, 0x6C, 0x2D, 0x65, 0x3D, 0xFE, 0x54, 0x4A]

    /// 접속 id → 사용자 이름. 비밀번호 등 다른 값은 꺼내지 않고, 푼 내용은 바로 지운다.
    /// 풀 수 없으면 빈 결과 (사용자 이름 없이 가져온다).
    static func users(inCredentials data: Data) -> [String: Users] {
        guard data.count > 16, (data.count - 16) % 16 == 0 else { return [:] }
        let iv = [UInt8](data.prefix(16))
        let cipher = [UInt8](data.dropFirst(16))
        var plain = [UInt8](repeating: 0, count: cipher.count + 16)
        defer { plain.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        var n = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             credentialsKey, credentialsKey.count, iv, cipher, cipher.count, &plain, plain.count, &n)
        guard status == kCCSuccess else { return [:] }
        // 사용자 이름만 읽는 모양으로 디코딩 (password 등 다른 필드는 무시)
        struct Section: Decodable { var user: String? }
        struct Loose: Decodable {
            var section: Section?
            init(from decoder: any Decoder) throws { section = try? Section(from: decoder) }
        }
        let decoded = plain.withUnsafeMutableBytes { buf in
            // 복사본을 만들지 않고 읽는다 (위 defer 에서 지운다)
            try? JSONDecoder().decode([String: [String: Loose]].self,
                                      from: Data(bytesNoCopy: buf.baseAddress!, count: n, deallocator: .none))
        }
        guard let obj = decoded else { return [:] }
        var out: [String: Users] = [:]
        for (id, sections) in obj {
            let db = sections["#connection"]?.section?.user
            let ssh = sections["network/ssh_tunnel"]?.section?.user
            if db != nil || ssh != nil { out[id] = Users(database: db, ssh: ssh) }
        }
        return out
    }
}
