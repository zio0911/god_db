import Foundation

/// 사용자 세션과 따로 잠깐 여는 연결 (AI 데이터 찾기 샘플 조회 · F7). `DBSession.sideConnection()` 으로 만든다.
/// - 처음 조회할 때 연결하고, 같은 찾기 안에서는 다시 쓴다. 다 쓰면 `close()`.
/// - 조회가 제한 시간을 넘으면 그 연결의 서버 세션을 취소(KILL 등)하고 연결을 버린다. 다음 조회는 새로 연결한다.
///   사용자 세션은 건드리지 않으므로 SQL Server(FreeTDS, 연결 하나) 에서도 메인 세션이 망가지지 않는다.
public actor SideConnection {
    public struct TimedOut: LocalizedError, Sendable {
        public let seconds: Int
        public init(seconds: Int) { self.seconds = seconds }
        public var errorDescription: String? { tr("시간 초과 (%@초)", "\(seconds)") }
    }

    let kind: DatabaseKind
    let dialect: any SQLDialect
    let endpoint: DriverEndpoint
    let readOnly: Bool
    /// 사용자 세션이 보던 DB(MySQL · SQL Server) 또는 스키마(PostgreSQL)
    let container: String
    let connectTimeout: Double
    private var driver: (any DBDriver)?
    private var sessionID: Int?

    init(kind: DatabaseKind, dialect: any SQLDialect, endpoint: DriverEndpoint, readOnly: Bool, container: String,
         connectTimeout: Double) {
        self.kind = kind
        self.dialect = dialect
        self.endpoint = endpoint
        self.readOnly = readOnly
        self.container = container
        self.connectTimeout = connectTimeout
    }

    /// 미리 연결해 본다 (실패하면 앱이 사용자 세션으로 조회하도록)
    public func connect() async throws { _ = try await open() }

    private func open() async throws -> any DBDriver {
        if let driver, driver.isOpen { return driver }
        let kind = kind, endpoint = endpoint, dialect = dialect, readOnly = readOnly, container = container
        let opened = try await ConnectDeadline.run(seconds: connectTimeout, late: { await $0.driver.close() }) {
            let o = try await DBSession.prepareDriver(kind, endpoint, dialect: dialect, readOnly: readOnly)
            if !container.isEmpty {
                do { _ = try await o.driver.query(dialect.useSQL(container)) } catch {
                    await o.driver.close()
                    throw error
                }
            }
            return o
        }
        driver = opened.driver
        sessionID = opened.sessionID
        return opened.driver
    }

    /// 조회 하나. 제한 시간을 넘으면 `TimedOut` 을 던지고 그 연결을 정리한다 (기다리지 않는다).
    public func query(_ sql: String, timeout: Double) async throws -> (columns: [String], rows: [[String?]]) {
        let d = try await open()
        do {
            return try await ConnectDeadline.run(seconds: timeout) { try await d.query(sql) }
        } catch is DBConnectTimeoutError {
            abandon()
            throw TimedOut(seconds: Int(timeout.rounded()))
        } catch {
            if !d.isOpen { abandon() }
            throw error
        }
    }

    /// 지금 연결을 버린다: 서버에 취소를 보내고(다른 연결로) 닫는다. 뒤에서 하므로 기다리지 않는다.
    private func abandon() {
        guard let d = driver else { return }
        let id = sessionID
        driver = nil
        sessionID = nil
        let kind = kind, endpoint = endpoint, dialect = dialect
        Task.detached {
            if let id {
                if let other = try? await ConnectDeadline.run(seconds: 10, late: { await $0.close() }, {
                    try await DBSession.makeDriver(kind, endpoint)
                }) {
                    _ = try? await other.query(dialect.cancelSQL(sessionID: id))
                    await other.close()
                }
            }
            await d.close()
        }
    }

    public func close() async {
        await driver?.close()
        driver = nil
        sessionID = nil
    }
}
