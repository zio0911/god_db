import Foundation

public enum DBError: LocalizedError {
    case readOnlyBlocked
    case notConnected
    case transactionOpen
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .readOnlyBlocked: return tr("읽기전용 접속이라 이 쿼리는 실행할 수 없어요. (SELECT / SHOW / DESC / EXPLAIN 만 허용)")
        case .notConnected: return tr("DB 연결이 끊어졌어요. 다시 연결해 주세요.")
        case .transactionOpen: return tr("커밋하지 않은 트랜잭션이 있어요. 먼저 커밋하거나 롤백해 주세요.")
        case .cancelled: return tr("쿼리를 취소했어요.")
        }
    }
}

/// 접속 하나 (필요하면 SSH 터널 포함). DB 종류에 맞는 드라이버와 문법(Dialect)을 쓴다. 쿼리는 순차 실행된다.
public actor DBSession {
    public nonisolated let profile: ConnectionProfile
    public nonisolated let dialect: any SQLDialect
    private var tunnel: SSHTunnel?
    private var driver: (any DBDriver)?
    /// 다시 연결 · 취소용 연결에 쓰는 주소 (터널을 거쳤다면 로컬 주소)
    private var endpoint: DriverEndpoint?
    /// 서버 쪽 세션 번호 (MySQL CONNECTION_ID, PostgreSQL pid, SQL Server SPID)
    private var serverSessionID: Int?
    /// 실행 중인 문장 수 / 취소 요청 여부
    private var running = 0
    private var cancelRequested = false
    /// 현재 선택된 DB(MySQL/SQL Server) 또는 스키마(PostgreSQL)
    public private(set) var current: String = ""
    /// 연결의 TLS 상태 (상태창 한 줄 — F9-3)
    public private(set) var tlsStatus: TLSStatus = .off

    // MARK: 트랜잭션 (자동 커밋 / 수동 커밋)
    /// 자동 커밋. 끄면 쓰기 문장을 실행할 때 트랜잭션을 열고, 커밋/롤백할 때까지 반영하지 않는다.
    public private(set) var autoCommit = true
    /// 열린 트랜잭션이 있는지
    public private(set) var inTransaction = false
    /// 마지막으로 이 접속을 쓴 시각 (쿼리 · 페이지 · 내보내기 · 스키마 읽기 모두 raw 를 거친다) — 운영 접속 자동 끊기에 쓴다
    public private(set) var lastActivity = Date()
    /// 열린 트랜잭션 안에서 실행한 쓰기 문장 수
    public private(set) var pendingChanges = 0

    public struct TransactionState: Sendable, Equatable {
        public var autoCommit: Bool
        public var open: Bool
        public var changes: Int

        public init(autoCommit: Bool = true, open: Bool = false, changes: Int = 0) {
            self.autoCommit = autoCommit
            self.open = open
            self.changes = changes
        }
    }
    public var transactionState: TransactionState {
        TransactionState(autoCommit: autoCommit, open: inTransaction, changes: pendingChanges)
    }

    public init(profile: ConnectionProfile) {
        self.profile = profile
        self.dialect = Dialects.of(profile.kind)
    }

    public static func connect(profile: ConnectionProfile, password: String?) async throws -> DBSession {
        let session = DBSession(profile: profile)
        try await session.open(password: password)
        return session
    }

    private func open(password: String?) async throws {
        var host = profile.host
        var port = profile.port
        if let ssh = profile.ssh {
            let t = try SSHTunnel(config: ssh, remoteHost: profile.host, remotePort: profile.port)
            try await t.start()
            tunnel = t
            host = "127.0.0.1"
            port = t.localPort
        }
        let endpoint = DriverEndpoint(
            host: host, port: port,
            serverName: (profile.ssh == nil && !HostResolver.isIPAddress(profile.host)) ? profile.host : nil,
            username: profile.username, password: password,
            database: profile.database, useTLS: profile.useTLS,
            tls: TLSPolicy.of(profile))
        self.endpoint = endpoint
        do {
            try await openDriver(endpoint)
        } catch {
            await driver?.close()
            driver = nil
            tunnel?.stop()
            tunnel = nil
            throw error
        }
    }

    private static func makeDriver(_ kind: DatabaseKind, _ endpoint: DriverEndpoint) async throws -> any DBDriver {
        switch kind {
        case .mysql: try await MySQLDriver.connect(endpoint)
        case .postgres: try await PostgresDriver.connect(endpoint)
        case .mssql: try await MSSQLDriver.connect(endpoint)
        case .redis: throw DBError.notConnected  // Redis 는 RedisSession 을 쓴다
        }
    }

    private func openDriver(_ endpoint: DriverEndpoint) async throws {
        let d = try await Self.makeDriver(profile.kind, endpoint)
        driver = d
        tlsStatus = profile.kind == .mssql ? (endpoint.useTLS ? .encryptOnly : .off) : d.tlsStatus
        if let sql = dialect.sessionSetupSQL { _ = try? await d.query(sql) }
        if profile.readOnly, let sql = dialect.readOnlySessionSQL {
            // 서버 측에서도 변경을 거부하도록 세션을 읽기전용으로 설정
            _ = try await d.query(sql)
        }
        serverSessionID = try? await d.query(dialect.sessionIDSQL).rows.first?.first.flatMap { $0.flatMap { Int($0) } }
    }

    /// 실행 중인 쿼리가 있는지
    public var isRunning: Bool { running > 0 }

    /// 실행 중인 쿼리를 멈춘다. 별도 연결을 잠깐 열어 서버에 취소를 보낸다.
    /// 실행 중이던 호출은 DBError.cancelled 로 끝난다. 실행 중이 아니면 false.
    @discardableResult
    public func cancelRunning() async throws -> Bool {
        guard running > 0, let endpoint, let id = serverSessionID else { return false }
        cancelRequested = true
        let other = try await Self.makeDriver(profile.kind, endpoint)
        defer { Task { await other.close() } }
        _ = try await other.query(dialect.cancelSQL(sessionID: id))
        return true
    }

    /// SQL Server 는 취소하면 세션이 끊기므로 다시 연결하고 보던 DB 로 돌아간다. 열린 트랜잭션은 서버가 롤백했다.
    private func reopenAfterKill() async {
        await driver?.close()
        driver = nil
        inTransaction = false
        pendingChanges = 0
        guard let endpoint else { return }
        do {
            try await openDriver(endpoint)
            if !current.isEmpty { _ = try? await driver?.query(dialect.useSQL(current)) }
        } catch {
            driver = nil
        }
    }

    public func close() async {
        await driver?.close()
        driver = nil
        tunnel?.stop()
        tunnel = nil
    }

    public var isConnected: Bool { driver?.isOpen ?? false }

    // MARK: - 쿼리

    /// 사용자 쿼리 실행. 읽기전용 접속이면 쓰기 쿼리를 차단한다.
    /// - Parameters:
    ///   - limit: 페이지 크기 (0 이면 전부). SELECT 는 이 크기로 페이지 단위로 가져온다.
    ///   - page: 0부터 시작하는 페이지 번호
    ///   - sort: DB 에서 정렬할 컬럼 (원래 쿼리를 감싸 ORDER BY)
    /// 결과 표에 담을 한 칸의 최대 글자 수 (긴 TEXT/BLOB 로 메모리가 넘치지 않게). 내보내기는 자르지 않는다.
    public static let maxCellCharacters = 1_000_000

    public func execute(_ sql: String, limit: Int, page: Int = 0, sort: ResultSort? = nil,
                        capCells: Bool = true) async throws -> QueryResult {
        if profile.readOnly && !SQLText.isReadOnly(sql) { throw DBError.readOnlyBlocked }
        try await beginIfNeeded(for: sql)
        let source = sort.flatMap { dialect.sortedSQL(sql, sort: $0) } ?? sql
        let paged = dialect.pagedSQL(source, limit: limit, offset: max(0, page) * limit)
        let started = Date()
        var (columns, rows) = try await raw(paged?.sql ?? source)
        let elapsed = Date().timeIntervalSince(started)
        var hasMore = false
        if let paged {
            if paged.skip > 0 { rows = Array(rows.dropFirst(paged.skip)) }
            hasMore = rows.count > limit
            if hasMore { rows = Array(rows.prefix(limit)) }
        }
        let kw = SQLText.firstKeyword(sql)
        let message: String? = columns.isEmpty
            ? (["SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "WITH"].contains(kw) ? tr("결과 없음") : tr("실행 완료"))
            : nil
        if kw == "USE" { current = (try? await currentContainer()) ?? current }
        var truncated = 0
        if capCells {
            let cap = Self.maxCellCharacters
            for r in rows.indices {
                for c in rows[r].indices {
                    if let v = rows[r][c], v.utf8.count > cap, v.count > cap {
                        rows[r][c] = String(v.prefix(cap)) + "…"
                        truncated += 1
                    }
                }
            }
        }
        var result = QueryResult(columns: columns, rows: rows, elapsed: elapsed, message: message)
        result.truncatedCells = truncated
        if paged != nil {
            result.page = max(0, page)
            result.pageSize = limit
            result.hasMore = hasMore
        }
        if source != sql { result.serverSort = sort }
        noteExecuted(sql)
        return result
    }

    /// 수동 커밋 모드에서 쓰기 문장이면 먼저 트랜잭션을 연다
    private func beginIfNeeded(for sql: String) async throws {
        guard !autoCommit, !inTransaction else { return }
        let kw = SQLText.firstKeyword(SQLText.stripComments(sql))
        guard !SQLText.isReadOnly(sql), !Self.transactionControl.contains(kw) else { return }
        // MySQL 의 DDL 은 어차피 자동 커밋되므로 트랜잭션을 열지 않는다
        if dialect.kind == .mysql, Self.ddl.contains(kw) { return }
        _ = try await raw(dialect.beginSQL)
        inTransaction = true
        pendingChanges = 0
    }

    private static let transactionControl: Set<String> = ["BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "SET", "USE"]
    private static let ddl: Set<String> = ["CREATE", "ALTER", "DROP", "RENAME", "TRUNCATE"]

    /// 실행 뒤 트랜잭션 상태 갱신 (사용자가 직접 COMMIT/ROLLBACK/BEGIN 을 쓴 경우, MySQL DDL 의 암묵적 커밋)
    private func noteExecuted(_ sql: String) {
        let kw = SQLText.firstKeyword(SQLText.stripComments(sql))
        switch kw {
        case "COMMIT", "ROLLBACK", "END":
            if !sql.uppercased().contains("TO SAVEPOINT") { inTransaction = false; pendingChanges = 0 }
        case "BEGIN", "START":
            if dialect.kind != .mssql || sql.uppercased().contains("TRAN") { inTransaction = true; pendingChanges = 0 }
        default:
            if dialect.kind == .mysql, Self.ddl.contains(kw) {
                inTransaction = false; pendingChanges = 0
            } else if inTransaction, !SQLText.isReadOnly(sql) {
                pendingChanges += 1
            }
        }
    }

    /// 자동 커밋 켜기/끄기. 열린 트랜잭션이 있으면 먼저 커밋/롤백해야 한다.
    public func setAutoCommit(_ on: Bool) throws {
        if on && inTransaction { throw DBError.transactionOpen }
        autoCommit = on
    }

    /// 열린 트랜잭션 커밋. 커밋한 변경 수를 돌려준다.
    @discardableResult
    public func commit() async throws -> Int {
        let n = pendingChanges
        _ = try await raw(dialect.commitSQL)
        inTransaction = false
        pendingChanges = 0
        return n
    }

    /// 열린 트랜잭션 롤백. 되돌린 변경 수를 돌려준다.
    @discardableResult
    public func rollback() async throws -> Int {
        let n = pendingChanges
        _ = try await raw(dialect.rollbackSQL)
        inTransaction = false
        pendingChanges = 0
        return n
    }

    /// 쿼리 결과의 전체 행 수 (SELECT 만)
    public func count(_ sql: String) async throws -> Int? {
        guard let countSQL = dialect.countSQL(sql) else { return nil }
        return try await raw(countSQL).rows.first?.first.flatMap { $0.flatMap { Int($0) } }
    }

    /// 실행 계획. 트리 형태 텍스트가 있으면 함께 돌려준다.
    public func explain(_ sql: String) async throws -> (result: QueryResult, tree: String?) {
        let steps = dialect.explain(sql)
        let started = Date()
        for s in steps.before { _ = try await raw(s) }
        let main: (columns: [String], rows: [[String?]])
        do {
            main = try await raw(steps.main)
        } catch {
            for s in steps.after { _ = try? await raw(s) }
            throw error
        }
        for s in steps.after { _ = try await raw(s) }
        let result = QueryResult(columns: main.columns, rows: main.rows, elapsed: Date().timeIntervalSince(started))
        var tree: String? = nil
        if let treeSQL = steps.treeSQL {
            tree = try? await raw(treeSQL).rows.first?.first ?? nil
        } else if let col = steps.treeColumn, let i = main.columns.firstIndex(of: col) {
            tree = main.rows.compactMap { $0[i] }.joined(separator: "\n")
        }
        return (result, tree)
    }

    /// 모든 값을 문자열로 받는다.
    public func raw(_ sql: String) async throws -> (columns: [String], rows: [[String?]]) {
        guard let driver, driver.isOpen else { throw DBError.notConnected }
        running += 1
        lastActivity = Date()
        defer { running -= 1; lastActivity = Date() }
        do {
            let r = try await driver.query(sql)
            // MySQL 은 KILL QUERY 로 멈춘 SLEEP 등이 오류 없이 끝나기도 한다 → 취소를 요청했으면 취소로 본다
            if cancelRequested {
                cancelRequested = false
                throw DBError.cancelled
            }
            return r
        } catch {
            if cancelRequested {
                cancelRequested = false
                if profile.kind == .mssql { await reopenAfterKill() }
                throw DBError.cancelled
            }
            throw error
        }
    }

    // MARK: - 메타데이터

    /// 서버 버전 (예: MySQL 8.0.36, PostgreSQL 16.4, SQL Server 16.0.4315.2 Developer Edition)
    public func serverVersion() async throws -> String {
        let v = try await raw(dialect.versionSQL).rows.first?.first ?? nil
        return "\(profile.kind.title) \(v ?? "")".trimmingCharacters(in: .whitespaces)
    }

    /// 빠른 찾기용 모든 스키마의 테이블 · 뷰 (지원하지 않으면 빈 배열)
    public func allTables() async throws -> [(schema: String, name: String, isView: Bool)] {
        guard let sql = dialect.allTablesSQL else { return [] }
        return try await raw(sql).rows.compactMap { r in
            guard r.count >= 3, let s = r[0], let n = r[1] else { return nil }
            return (s, n, (r[2] ?? "").uppercased().contains("VIEW"))
        }
    }

    public func databases() async throws -> [String] {
        try await raw(dialect.databasesSQL).rows.compactMap { $0.first ?? nil }
    }

    public func use(_ name: String) async throws {
        _ = try await raw(dialect.useSQL(name))
        current = name
    }

    private func currentContainer() async throws -> String? {
        let sql: String
        switch profile.kind {
        case .mysql, .redis: sql = "SELECT DATABASE()"
        case .postgres: sql = "SELECT current_schema()"
        case .mssql: sql = "SELECT DB_NAME()"
        }
        return try await raw(sql).rows.first?.first ?? nil
    }

    public func loadSchema(_ schema: String) async throws -> [TableMeta] {
        if dialect.metadataNeedsUse && current != schema { try await use(schema) }
        let tableRows = try await raw(dialect.tablesSQL(schema)).rows
        let columnRows = try await raw(dialect.columnsSQL(schema)).rows
        let indexRows = try await raw(dialect.indexesSQL(schema)).rows
        var tables = SchemaBuilder.build(tableRows: tableRows, columnRows: columnRows, indexRows: indexRows)
        // 외래 키는 권한 등으로 못 읽어도 스키마 자체는 보여준다
        if let fkRows = try? await raw(dialect.foreignKeysSQL(schema)).rows {
            tables = SchemaBuilder.attachForeignKeys(tables, rows: fkRows)
        }
        return tables
    }

    public func loadRoutines(_ schema: String) async throws -> [RoutineMeta] {
        if dialect.metadataNeedsUse && current != schema { try await use(schema) }
        return try await raw(dialect.routinesSQL(schema)).rows.compactMap { r in
            guard let type = r[0], let name = r[1], let kind = RoutineMeta.Kind(rawValue: type) else { return nil }
            return RoutineMeta(kind: kind, name: name, comment: r.count > 2 ? (r[2] ?? "") : "")
        }
    }

    /// 뷰/프로시저/함수/트리거 정의 전체
    public func definition(of routine: RoutineMeta) async throws -> String? {
        let (columns, rows) = try await raw(dialect.definitionSQL(routine, schema: current))
        guard let row = rows.first else { return nil }
        let wanted = ["Create View", "Create Procedure", "Create Function", "SQL Original Statement"]
        let body: String?
        if let i = columns.firstIndex(where: { wanted.contains($0) }) {
            body = row[i]
        } else {
            body = row.compactMap { $0 }.max { $0.count < $1.count }
        }
        return body.map { dialect.formatDefinition(routine, schema: current, body: $0) }
    }

    /// 테이블 CREATE 문. MySQL 은 서버가 주는 DDL, 나머지는 메타데이터로 만든다.
    public func tableDDL(_ table: TableMeta) async throws -> String {
        if let sql = dialect.showCreateTableSQL(table.name),
           let ddl = try await raw(sql).rows.first.flatMap({ $0.count > 1 ? $0[1] : nil }) {
            return ddl + ";"
        }
        return dialect.createTableSQL(table)
    }

    /// MySQL 의 SHOW CREATE TABLE (스키마 비교에서 누락 테이블 생성용). 다른 DB 는 nil.
    public func showCreateTable(_ table: String) async throws -> String? {
        guard let sql = dialect.showCreateTableSQL(table) else { return nil }
        return try await raw(sql).rows.first.flatMap { $0.count > 1 ? $0[1] : nil }
    }
}

/// 메타데이터 조회 결과(문자열 행)를 TableMeta 로 조립한다. 컬럼 순서는 SQLDialect 설명 참고.
public enum SchemaBuilder {
    public static func build(tableRows: [[String?]], columnRows: [[String?]], indexRows: [[String?]]) -> [TableMeta] {
        var tables: [String: TableMeta] = [:]
        var order: [String] = []
        for r in tableRows {
            guard let name = r[0], tables[name] == nil else { continue }
            tables[name] = TableMeta(name: name, comment: r.count > 1 ? (r[1] ?? "") : "")
            order.append(name)
        }
        for r in columnRows {
            guard let t = r[0], let name = r[1], tables[t] != nil else { continue }
            tables[t]!.columns.append(ColumnMeta(
                name: name,
                columnType: r[2] ?? "",
                nullable: (r[3] ?? "") == "YES",
                defaultValue: r[4],
                extra: r[5] ?? "",
                columnKey: r[6] ?? "",
                comment: r[7] ?? "",
                position: Int(r[8] ?? "") ?? 0
            ))
        }
        for r in indexRows {
            guard let t = r[0], let idx = r[1], let col = r[3], tables[t] != nil else { continue }
            if let i = tables[t]!.indexes.firstIndex(where: { $0.name == idx }) {
                tables[t]!.indexes[i].columns.append(col)
            } else {
                let primary = r.count > 4 ? r[4].map { $0 == "1" } : nil
                let constraint = r.count > 5 ? r[5].map { $0 == "1" } : nil
                tables[t]!.indexes.append(IndexMeta(name: idx, unique: (r[2] ?? "1") == "0", columns: [col],
                                                    primary: primary, constraint: constraint))
            }
        }
        return order.compactMap { tables[$0] }
    }
}
