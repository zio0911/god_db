import Foundation

public enum DBError: LocalizedError {
    case readOnlyBlocked
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .readOnlyBlocked: return "읽기전용 접속이라 이 쿼리는 실행할 수 없어요. (SELECT / SHOW / DESC / EXPLAIN 만 허용)"
        case .notConnected: return "DB 연결이 끊어졌어요. 다시 연결해 주세요."
        }
    }
}

/// 접속 하나 (필요하면 SSH 터널 포함). DB 종류에 맞는 드라이버와 문법(Dialect)을 쓴다. 쿼리는 순차 실행된다.
public actor DBSession {
    public nonisolated let profile: ConnectionProfile
    public nonisolated let dialect: any SQLDialect
    private var tunnel: SSHTunnel?
    private var driver: (any DBDriver)?
    /// 현재 선택된 DB(MySQL/SQL Server) 또는 스키마(PostgreSQL)
    public private(set) var current: String = ""

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
            database: profile.database, useTLS: profile.useTLS)
        do {
            switch profile.kind {
            case .mysql: driver = try await MySQLDriver.connect(endpoint)
            case .postgres: driver = try await PostgresDriver.connect(endpoint)
            case .mssql: driver = try await MSSQLDriver.connect(endpoint)
            }
            if profile.readOnly, let sql = dialect.readOnlySessionSQL {
                // 서버 측에서도 변경을 거부하도록 세션을 읽기전용으로 설정
                _ = try await raw(sql)
            }
        } catch {
            await driver?.close()
            driver = nil
            tunnel?.stop()
            tunnel = nil
            throw error
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
    public func execute(_ sql: String, limit: Int, page: Int = 0) async throws -> QueryResult {
        if profile.readOnly && !SQLText.isReadOnly(sql) { throw DBError.readOnlyBlocked }
        let paged = dialect.pagedSQL(sql, limit: limit, offset: max(0, page) * limit)
        let started = Date()
        var (columns, rows) = try await raw(paged?.sql ?? sql)
        let elapsed = Date().timeIntervalSince(started)
        var hasMore = false
        if let paged {
            if paged.skip > 0 { rows = Array(rows.dropFirst(paged.skip)) }
            hasMore = rows.count > limit
            if hasMore { rows = Array(rows.prefix(limit)) }
        }
        let kw = SQLText.firstKeyword(sql)
        let message: String? = columns.isEmpty
            ? (["SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "WITH"].contains(kw) ? "결과 없음" : "실행 완료")
            : nil
        if kw == "USE" { current = (try? await currentContainer()) ?? current }
        var result = QueryResult(columns: columns, rows: rows, elapsed: elapsed, message: message)
        if paged != nil {
            result.page = max(0, page)
            result.pageSize = limit
            result.hasMore = hasMore
        }
        return result
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
        return try await driver.query(sql)
    }

    // MARK: - 메타데이터

    /// 서버 버전 (예: MySQL 8.0.36, PostgreSQL 16.4, SQL Server 16.0.4315.2 Developer Edition)
    public func serverVersion() async throws -> String {
        let v = try await raw(dialect.versionSQL).rows.first?.first ?? nil
        return "\(profile.kind.title) \(v ?? "")".trimmingCharacters(in: .whitespaces)
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
        case .mysql: sql = "SELECT DATABASE()"
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
        return SchemaBuilder.build(tableRows: tableRows, columnRows: columnRows, indexRows: indexRows)
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
