import Foundation
import MySQLNIO
import NIOSSL
import PostgresNIO

/// DB 와 실제로 통신하는 부분. 모든 값은 문자열(NULL 은 nil)로 돌려준다.
public protocol DBDriver: AnyObject, Sendable {
    /// SQL 을 실행하고 첫 번째 결과 집합을 돌려준다. 결과가 없으면 빈 배열.
    func query(_ sql: String) async throws -> (columns: [String], rows: [[String?]])
    func close() async
    var isOpen: Bool { get }
}

/// 드라이버가 연결할 때 필요한 값 (SSH 터널을 거쳤다면 host/port 는 로컬 주소)
public struct DriverEndpoint: Sendable {
    public var host: String
    public var port: Int
    /// TLS SNI 에 쓸 원래 호스트명 (IP 이거나 터널이면 nil)
    public var serverName: String?
    public var username: String
    public var password: String?
    public var database: String
    public var useTLS: Bool
}

enum HostResolver {
    /// getaddrinfo 로 모든 숫자 주소를 구한다. IPv4 먼저 (로컬 Docker 등은 IPv4 만 여는 경우가 많음)
    static func addresses(host: String, port: Int) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return [host] }
        defer { freeaddrinfo(result) }
        var v4: [String] = [], v6: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let sa = info.pointee.ai_addr,
               getnameinfo(sa, info.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buf)
                if Int32(sa.pointee.sa_family) == AF_INET { v4.append(ip) } else { v6.append(ip) }
            }
            cursor = info.pointee.ai_next
        }
        var seen = Set<String>()
        let all = (v4 + v6).filter { seen.insert($0).inserted }
        return all.isEmpty ? [host] : all
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// 소켓 연결 단계 오류인지 (다음 주소로 넘어가도 되는지)
    static func isSocketError(_ error: any Error) -> Bool {
        if error is IOError || error is ChannelError { return true }
        if let pg = error as? PSQLError, pg.code == .connectionError { return true }
        return false
    }

    /// 주소를 차례로 시도한다.
    static func tryEach<T>(_ host: String, port: Int, _ body: (String) async throws -> T) async throws -> T {
        var lastError: (any Error)?
        for address in addresses(host: host, port: port) {
            do { return try await body(address) } catch {
                lastError = error
                guard isSocketError(error) else { throw error }
            }
        }
        throw lastError ?? DBError.notConnected
    }

    static func insecureTLS() -> TLSConfiguration {
        var config = TLSConfiguration.makeClientConfiguration()
        // 터널 경유 시 호스트명이 127.0.0.1 이 되어 인증서 검증이 불가하므로 암호화만 사용한다.
        config.certificateVerification = .none
        return config
    }
}

// MARK: - MySQL

final class MySQLDriver: DBDriver, @unchecked Sendable {
    private let connection: MySQLConnection

    private init(_ connection: MySQLConnection) { self.connection = connection }

    static func connect(_ e: DriverEndpoint) async throws -> MySQLDriver {
        let conn = try await HostResolver.tryEach(e.host, port: e.port) { ip in
            try await MySQLConnection.connect(
                to: try SocketAddress(ipAddress: ip, port: e.port),
                username: e.username,
                database: e.database,
                password: e.password,
                tlsConfiguration: e.useTLS ? HostResolver.insecureTLS() : nil,
                // SNI 에는 도메인만 쓸 수 있다.
                serverHostname: e.serverName,
                on: MultiThreadedEventLoopGroup.singleton.any()
            ).get()
        }
        return MySQLDriver(conn)
    }

    var isOpen: Bool { !connection.isClosed }

    func query(_ sql: String) async throws -> (columns: [String], rows: [[String?]]) {
        guard isOpen else { throw DBError.notConnected }
        let result = try await connection.simpleQuery(sql).get()
        guard let first = result.first else { return ([], []) }
        // binary/varbinary/BLOB 은 바이트 그대로 오므로 글자로 읽으면 깨진다 → 0x16진수로 보여준다
        let binary = first.columnDefinitions.map(Self.isBinary)
        return (first.columnDefinitions.map(\.name),
                result.map { row in
                    row.values.enumerated().map { i, b in
                        guard let b else { return nil }
                        return binary[i] ? BinaryText.hex(b.readableBytesView) : String(buffer: b)
                    }
                })
    }

    /// 문자열·BLOB 계열이면서 문자셋이 binary(63)인 컬럼 (숫자 컬럼도 63 이라 타입을 함께 본다)
    static func isBinary(_ def: MySQLProtocol.ColumnDefinition41) -> Bool {
        guard def.characterSet == .binary else { return false }
        let types: [MySQLProtocol.DataType] = [.varchar, .varString, .string, .tinyBlob, .mediumBlob,
                                               .longBlob, .blob, .geometry, .bit]
        return types.contains(def.columnType)
    }

    func close() async { try? await connection.close().get() }

    deinit {
        let c = connection
        if !c.isClosed { c.close().whenComplete { _ in _ = c } }
    }
}

// MARK: - PostgreSQL

final class PostgresDriver: DBDriver, @unchecked Sendable {
    private let connection: PostgresConnection

    private init(_ connection: PostgresConnection) { self.connection = connection }

    static func connect(_ e: DriverEndpoint) async throws -> PostgresDriver {
        let tls: PostgresConnection.Configuration.TLS
        if e.useTLS {
            tls = .prefer(try NIOSSLContext(configuration: HostResolver.insecureTLS()))
        } else {
            tls = .disable
        }
        let conn = try await HostResolver.tryEach(e.host, port: e.port) { ip in
            var config = PostgresConnection.Configuration(
                host: ip, port: e.port, username: e.username, password: e.password,
                database: e.database.isEmpty ? "postgres" : e.database, tls: tls)
            if let name = e.serverName { config.options.tlsServerName = name }
            return try await PostgresConnection.connect(
                on: MultiThreadedEventLoopGroup.singleton.any(),
                configuration: config, id: 1, logger: Logger(label: "goddb.postgres")
            ).get()
        }
        return PostgresDriver(conn)
    }

    var isOpen: Bool { !connection.isClosed }

    /// 값은 텍스트 형식으로 온다 (Vendor 패치). 확장 프로토콜은 한 번에 한 문장만 되므로 나눠서 실행하고,
    /// 결과 컬럼이 있는 마지막 문장의 결과를 돌려준다.
    func query(_ sql: String) async throws -> (columns: [String], rows: [[String?]]) {
        guard isOpen else { throw DBError.notConnected }
        let statements = SQLText.statements(in: sql).map(\.sql)
        var last: (columns: [String], rows: [[String?]]) = ([], [])
        for statement in statements.isEmpty ? [sql] : statements {
            let rows = try await connection.simpleQuery(statement).get()
            guard let first = rows.first else { continue }
            last = (first.map(\.columnName), rows.map { row in
                row.map { cell in
                    cell.bytes.map { b in
                        let s = String(buffer: b)
                        // bytea 는 텍스트 형식에서 \x… 로 온다 → 다른 DB 와 같게 0x… 로
                        return cell.dataType == .bytea && s.hasPrefix("\\x") ? "0x" + s.dropFirst(2).uppercased() : s
                    }
                }
            })
        }
        return last
    }

    func close() async { try? await connection.close() }

    /// close() 없이 버려져도 연결을 정리한다. (닫힐 때까지 연결 객체를 붙잡아 둠)
    deinit {
        let c = connection
        if !c.isClosed { c.close().whenComplete { _ in _ = c } }
    }
}
