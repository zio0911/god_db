import Foundation

/// DataGrip 에서 "복사"한 접속 정보(#DataSourceSettings# … <data-source …>)를 읽는다.
/// 비밀번호는 DataGrip 이 따로 보관하므로 들어 있지 않다. SSH 는 설정 id 만 있어 직접 입력해야 한다.
public enum DataGripImport {
    public struct Source: Equatable, Sendable {
        public var profile: ConnectionProfile
        /// 사용자에게 알려줄 점 (SSH 직접 입력 필요, 지원하지 않는 DB 등)
        public var notes: [String]
    }

    public enum ParseError: LocalizedError, Equatable {
        case notDataGrip
        case nothingSupported([String])

        public var errorDescription: String? {
            switch self {
            case .notDataGrip: return tr("DataGrip 에서 복사한 접속 정보가 아니에요. (DataGrip: 데이터 소스 우클릭 > SQL 스크립트 > 복사가 아니라, 데이터 소스를 고르고 ⌘C)")
            case .nothingSupported(let names): return tr("지원하지 않는 DB 예요: %@", names.joined(separator: ", "))
            }
        }
    }

    public static func looksLikeDataGrip(_ text: String) -> Bool {
        text.contains("<data-source") && (text.contains("#DataSourceSettings#") || text.contains("jdbc-url"))
    }

    public static func parse(_ text: String) throws -> [Source] {
        guard looksLikeDataGrip(text) else { throw ParseError.notDataGrip }
        // #BEGIN# 과 #END# 사이 (여러 개일 수 있다), 없으면 <data-source> 부분만
        var xml = ""
        if let regex = try? NSRegularExpression(pattern: "<data-source[\\s\\S]*?</data-source>") {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                xml += ns.substring(with: m.range) + "\n"
            }
        }
        guard !xml.isEmpty, let doc = try? XMLDocument(xmlString: "<root>\(xml)</root>", options: []) else {
            throw ParseError.notDataGrip
        }
        var out: [Source] = []
        var unsupported: [String] = []
        for node in (try? doc.nodes(forXPath: "//data-source")) ?? [] {
            guard let el = node as? XMLElement else { continue }
            let name = el.attribute(forName: "name")?.stringValue ?? "DataGrip"
            let url = child(el, "jdbc-url") ?? ""
            let user = child(el, "user-name") ?? ""
            guard var p = profile(fromJDBC: url) else {
                unsupported.append(name)
                continue
            }
            p.name = name
            p.username = user
            if let uuid = el.attribute(forName: "uuid")?.stringValue.flatMap(UUID.init(uuidString:)) { p.id = uuid }
            var notes: [String] = []
            if child(el, "ssh-properties/enabled") == "true" {
                notes.append(tr("SSH 터널 사용 — DataGrip 복사본에는 SSH 정보가 없어서 접속 편집에서 바스티온을 직접 넣어 주세요."))
                // SSH 를 켜 두고 호스트만 비워 둔다 (편집 화면에서 채우도록)
                p.ssh = SSHConfig(host: "", port: 22, username: "ec2-user", keyPath: "")
            }
            notes.append(tr("비밀번호는 처음 연결할 때 입력해요."))
            out.append(Source(profile: p, notes: notes))
        }
        if out.isEmpty {
            if unsupported.isEmpty { throw ParseError.notDataGrip }
            throw ParseError.nothingSupported(unsupported)
        }
        return out
    }

    static func child(_ el: XMLElement, _ path: String) -> String? {
        (try? el.nodes(forXPath: path))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// JDBC URL → 접속 정보 (호스트, 포트, DB, TLS)
    public static func profile(fromJDBC url: String) -> ConnectionProfile? {
        let lower = url.lowercased()
        var p = ConnectionProfile()
        var rest: Substring
        if lower.hasPrefix("jdbc:mysql://") || lower.hasPrefix("jdbc:mariadb://") || lower.hasPrefix("jdbc:mysql:aws://") {
            p.kind = .mysql
            rest = url[url.range(of: "://")!.upperBound...]
        } else if lower.hasPrefix("jdbc:postgresql://") {
            p.kind = .postgres
            rest = url[url.range(of: "://")!.upperBound...]
        } else if lower.hasPrefix("jdbc:sqlserver://") || lower.hasPrefix("jdbc:jtds:sqlserver://") {
            p.kind = .mssql
            rest = url[url.range(of: "://")!.upperBound...]
        } else if lower.hasPrefix("jdbc:redis://") || lower.hasPrefix("jdbc:rediss://") || lower.hasPrefix("redis://") || lower.hasPrefix("rediss://") {
            p.kind = .redis
            p.useTLS = lower.contains("rediss://")
            rest = url[url.range(of: "://")!.upperBound...]
        } else {
            return nil
        }
        p.port = p.kind.defaultPort

        // 쿼리 / 속성
        var params: [String: String] = [:]
        func addParams(_ s: Substring, sep: Character) {
            for kv in s.split(separator: sep) {
                let parts = kv.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { params[parts[0].lowercased()] = String(parts[1]) }
            }
        }
        if p.kind == .mssql {
            // host[\instance][:port][;prop=value…]
            let pieces = rest.split(separator: ";", maxSplits: 1)
            rest = pieces.first ?? ""
            if pieces.count > 1 { addParams(pieces[1], sep: ";") }
            p.database = params["database"] ?? params["databasename"] ?? ""
        } else {
            if let q = rest.firstIndex(of: "?") {
                addParams(rest[rest.index(after: q)...], sep: "&")
                rest = rest[..<q]
            }
            if let slash = rest.firstIndex(of: "/") {
                p.database = String(rest[rest.index(after: slash)...]).removingPercentEncoding ?? ""
                rest = rest[..<slash]
            }
        }
        // user:pass@host (redis) — 비밀번호는 쓰지 않는다
        if let at = rest.lastIndex(of: "@") {
            let userInfo = rest[..<at]
            let u = userInfo.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            if !u.isEmpty { p.username = u }
            rest = rest[rest.index(after: at)...]
        }
        // 호스트[:포트] (IPv6 [::1]:port, SQL Server host\instance)
        var hostPort = String(rest)
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            p.host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            hostPort = String(hostPort[hostPort.index(after: close)...])
            if hostPort.hasPrefix(":"), let port = Int(hostPort.dropFirst()) { p.port = port }
        } else {
            let parts = hostPort.split(separator: ":", maxSplits: 1)
            p.host = parts.first.map(String.init) ?? ""
            if parts.count > 1, let port = Int(parts[1]) { p.port = port }
        }
        if p.kind == .mssql, let bs = p.host.firstIndex(of: "\\") { p.host = String(p.host[..<bs]) }
        if p.kind == .mssql, let port = params["portnumber"].flatMap(Int.init) { p.port = port }
        if p.kind == .redis, p.database.isEmpty { p.database = params["database"] ?? "0" }
        guard !p.host.isEmpty else { return nil }

        // TLS
        switch p.kind {
        case .mysql:
            if let v = params["usessl"] ?? params["sslmode"].map({ $0.lowercased() == "disabled" ? "false" : "true" }) {
                p.useTLS = v.lowercased() != "false"
            }
        case .postgres:
            if let v = params["sslmode"]?.lowercased() { p.useTLS = v != "disable" }
            if let v = params["ssl"]?.lowercased() { p.useTLS = v == "true" }
        case .mssql:
            if let v = params["encrypt"]?.lowercased() { p.useTLS = v == "true" || v == "strict" || v == "mandatory" }
        case .redis:
            if let v = params["ssl"]?.lowercased() { p.useTLS = v == "true" }
        }
        return p
    }
}
