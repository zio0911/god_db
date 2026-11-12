import Foundation

/// 실행 계획을 보기 위해 실행할 SQL 들
public struct ExplainSteps: Sendable {
    public var before: [String] = []
    public var main: String
    public var after: [String] = []
    /// 트리 형태 계획을 얻는 별도 SQL (MySQL)
    public var treeSQL: String?
    /// main 결과에서 이 컬럼을 줄바꿈으로 이어 트리로 쓴다 (PostgreSQL, SQL Server)
    public var treeColumn: String?
}

/// DB 별 SQL 문법 차이를 모은 곳.
/// 메타데이터 SQL 은 SchemaBuilder 가 읽는 정규화된 컬럼 순서로 돌려줘야 한다.
/// - tables:  [테이블, 코멘트]
/// - columns: [테이블, 컬럼, 타입, YES/NO, 기본값, extra, PRI/'', 코멘트, 순서]
/// - indexes: [테이블, 인덱스, NON_UNIQUE 0/1, 컬럼, PRIMARY 1/0, 제약조건 1/0]
/// - routines: [VIEW/PROCEDURE/FUNCTION/TRIGGER, 이름, 코멘트]
public protocol SQLDialect: Sendable {
    var kind: DatabaseKind { get }

    func quoteIdent(_ name: String) -> String
    /// 테이블 이름 (SQL Server 는 `schema.table` 형태일 수 있음)
    func quoteTable(_ name: String) -> String
    func quoteString(_ value: String) -> String

    func applyingLimit(_ sql: String, limit: Int) -> String
    /// 읽기전용 접속일 때 연결 직후 실행할 SQL (서버 측 차단)
    var readOnlySessionSQL: String? { get }

    var databasesSQL: String { get }
    func useSQL(_ name: String) -> String
    /// 메타데이터를 읽기 전에 USE 가 필요한지 (SQL Server)
    var metadataNeedsUse: Bool { get }
    func initialContainer(profile: ConnectionProfile, available: [String]) -> String

    func tablesSQL(_ schema: String) -> String
    func columnsSQL(_ schema: String) -> String
    func indexesSQL(_ schema: String) -> String
    func routinesSQL(_ schema: String) -> String
    func definitionSQL(_ routine: RoutineMeta, schema: String) -> String
    func formatDefinition(_ routine: RoutineMeta, schema: String, body: String) -> String

    /// 서버가 DDL 을 직접 주는 경우 (MySQL SHOW CREATE TABLE). nil 이면 메타데이터로 만든다.
    func showCreateTableSQL(_ table: String) -> String?
    func createTableSQL(_ table: TableMeta) -> String

    func explain(_ sql: String) -> ExplainSteps

    func columnDefinition(_ c: ColumnMeta) -> String
    func defaultLiteral(_ value: String, extra: String) -> String
    func render(_ changes: [SchemaChange], table: String) -> String
}

extension SQLDialect {
    public func quoteString(_ value: String) -> String { SQLText.quoteString(value) }
    public func quoteTable(_ name: String) -> String { quoteIdent(name) }
    public var metadataNeedsUse: Bool { false }
    public func showCreateTableSQL(_ table: String) -> String? { nil }

    public func applyingLimit(_ sql: String, limit: Int) -> String {
        SQLText.applyingLimit(sql, limit: limit)
    }

    public func initialContainer(profile: ConnectionProfile, available: [String]) -> String {
        profile.database.isEmpty ? (available.first ?? "") : profile.database
    }

    /// 인덱스 컬럼 목록 `(a, b)`
    func indexColumns(_ i: IndexMeta) -> String {
        "(" + i.columns.map(quoteIdent).joined(separator: ", ") + ")"
    }
}

public enum Dialects {
    public static func of(_ kind: DatabaseKind) -> any SQLDialect {
        switch kind {
        case .mysql, .redis: return MySQLDialect()
        case .postgres: return PostgresDialect()
        case .mssql: return MSSQLDialect()
        }
    }
}

// MARK: - MySQL

public struct MySQLDialect: SQLDialect {
    public init() {}
    public var kind: DatabaseKind { .mysql }

    public func quoteIdent(_ name: String) -> String { SQLText.quoteIdent(name) }

    public var readOnlySessionSQL: String? { "SET SESSION TRANSACTION READ ONLY" }

    public var databasesSQL: String {
        """
        SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
         WHERE SCHEMA_NAME NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys')
         ORDER BY SCHEMA_NAME
        """
    }

    public func useSQL(_ name: String) -> String { "USE \(quoteIdent(name))" }

    public func tablesSQL(_ schema: String) -> String {
        """
        SELECT TABLE_NAME, IFNULL(TABLE_COMMENT, '')
          FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = \(quoteString(schema)) AND TABLE_TYPE = 'BASE TABLE'
         ORDER BY TABLE_NAME
        """
    }

    public func columnsSQL(_ schema: String) -> String {
        """
        SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT,
               EXTRA, COLUMN_KEY, IFNULL(COLUMN_COMMENT, ''), ORDINAL_POSITION
          FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = \(quoteString(schema))
         ORDER BY TABLE_NAME, ORDINAL_POSITION
        """
    }

    public func indexesSQL(_ schema: String) -> String {
        """
        SELECT TABLE_NAME, INDEX_NAME, NON_UNIQUE, COLUMN_NAME,
               IF(INDEX_NAME = 'PRIMARY', '1', '0'), IF(INDEX_NAME = 'PRIMARY', '1', '0')
          FROM information_schema.STATISTICS
         WHERE TABLE_SCHEMA = \(quoteString(schema))
         ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
        """
    }

    public func routinesSQL(_ schema: String) -> String {
        let s = quoteString(schema)
        return """
        SELECT 'VIEW', TABLE_NAME, '' FROM information_schema.VIEWS WHERE TABLE_SCHEMA = \(s)
        UNION ALL
        SELECT ROUTINE_TYPE, ROUTINE_NAME, IFNULL(ROUTINE_COMMENT, '')
          FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(s)
        UNION ALL
        SELECT 'TRIGGER', TRIGGER_NAME, CONCAT(ACTION_TIMING, ' ', EVENT_MANIPULATION, ' ON ', EVENT_OBJECT_TABLE)
          FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(s)
        ORDER BY 1, 2
        """
    }

    public func definitionSQL(_ routine: RoutineMeta, schema: String) -> String {
        "SHOW CREATE \(routine.kind.rawValue) \(quoteIdent(routine.name))"
    }

    public func formatDefinition(_ routine: RoutineMeta, schema: String, body: String) -> String { body }

    public func showCreateTableSQL(_ table: String) -> String? {
        "SHOW CREATE TABLE \(quoteIdent(table))"
    }

    public func createTableSQL(_ table: TableMeta) -> String {
        var lines = table.columns.sorted { $0.position < $1.position }.map { "  " + columnDefinition($0) }
        for i in table.indexes {
            if i.isPrimary {
                lines.append("  PRIMARY KEY \(indexColumns(i))")
            } else {
                lines.append("  \(i.unique ? "UNIQUE " : "")KEY \(quoteIdent(i.name)) \(indexColumns(i))")
            }
        }
        var sql = "CREATE TABLE \(quoteIdent(table.name)) (\n" + lines.joined(separator: ",\n") + "\n)"
        if !table.comment.isEmpty { sql += " COMMENT=\(quoteString(table.comment))" }
        return sql + ";"
    }

    public func explain(_ sql: String) -> ExplainSteps {
        ExplainSteps(main: "EXPLAIN \(sql)", treeSQL: "EXPLAIN FORMAT=TREE \(sql)")
    }

    public func columnDefinition(_ c: ColumnMeta) -> String {
        var parts = [quoteIdent(c.name), c.columnType, c.nullable ? "NULL" : "NOT NULL"]
        if let def = c.defaultValue {
            parts.append("DEFAULT \(defaultLiteral(def, extra: c.extra))")
        }
        let extra = c.extra.replacingOccurrences(of: "DEFAULT_GENERATED", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { parts.append(extra) }
        if !c.comment.isEmpty { parts.append("COMMENT \(quoteString(c.comment))") }
        return parts.joined(separator: " ")
    }

    public func defaultLiteral(_ value: String, extra: String) -> String {
        let upper = value.uppercased()
        if extra.uppercased().contains("DEFAULT_GENERATED") || upper.hasPrefix("CURRENT_TIMESTAMP") || upper == "NULL" {
            return value
        }
        return quoteString(value)
    }

    /// MySQL 은 하나의 ALTER TABLE 문으로 모은다.
    public func render(_ changes: [SchemaChange], table: String) -> String {
        guard !changes.isEmpty else { return "" }
        let clauses: [String] = changes.map { change in
            switch change {
            case .dropIndex(let i):
                return i.isPrimary ? "DROP PRIMARY KEY" : "DROP INDEX \(quoteIdent(i.name))"
            case .dropColumn(let name):
                return "DROP COLUMN \(quoteIdent(name))"
            case .renameColumn(let old, let new):
                return "CHANGE COLUMN \(quoteIdent(old.name)) \(columnDefinition(new))"
            case .modifyColumn(_, let new):
                return "MODIFY COLUMN \(columnDefinition(new))"
            case .addColumn(let c, let after):
                return "ADD COLUMN \(columnDefinition(c)) " + (after.map { "AFTER \(quoteIdent($0))" } ?? "FIRST")
            case .addIndex(let i):
                if i.isPrimary { return "ADD PRIMARY KEY \(indexColumns(i))" }
                return "ADD \(i.unique ? "UNIQUE " : "")INDEX \(quoteIdent(i.name)) \(indexColumns(i))"
            case .tableComment(_, let new):
                return "COMMENT = \(quoteString(new))"
            }
        }
        // 절이 1~2개면 한 줄, 그보다 많으면 줄마다
        if clauses.count <= 2 {
            return "ALTER TABLE \(quoteTable(table)) " + clauses.joined(separator: ", ") + ";"
        }
        return "ALTER TABLE \(quoteTable(table))\n  " + clauses.joined(separator: ",\n  ") + ";"
    }
}

// MARK: - 화면에서 쓰는 DB 별 SQL

extension SQLDialect {
    /// 테이블 데이터 보기
    public func selectAllSQL(_ table: String) -> String {
        "SELECT * FROM \(quoteTable(table));"
    }

    /// 인덱스 상세 (카디널리티/정의 등)
    public func indexDetailSQL(_ table: String, schema: String) -> String {
        switch kind {
        case .mysql, .redis:
            return "SHOW INDEX FROM \(quoteIdent(table));"
        case .postgres:
            return """
            SELECT i.indexname, i.indexdef, s.idx_scan AS scans, pg_size_pretty(pg_relation_size(c.oid)) AS size
              FROM pg_indexes i
              JOIN pg_class c ON c.relname = i.indexname
              JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = i.schemaname
              LEFT JOIN pg_stat_user_indexes s ON s.indexrelid = c.oid
             WHERE i.schemaname = \(quoteString(schema)) AND i.tablename = \(quoteString(table))
             ORDER BY i.indexname;
            """
        case .mssql:
            return "EXEC sp_helpindex \(quoteString(table));"
        }
    }

    /// 서버 버전 한 줄
    public var versionSQL: String {
        switch kind {
        case .mysql, .redis: return "SELECT VERSION()"
        case .postgres: return "SHOW server_version"
        case .mssql:
            return "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)) + ' ' + CAST(SERVERPROPERTY('Edition') AS nvarchar(100))"
        }
    }

    /// 프로시저 호출 문 틀
    public func callSQL(_ name: String) -> String {
        switch kind {
        case .mysql, .redis, .postgres: return "CALL \(quoteTable(name))();"
        case .mssql: return "EXEC \(quoteTable(name));"
        }
    }
}

// MARK: - 결과 페이징

/// 한 페이지를 가져오는 SQL. skip 은 받아온 뒤 앞에서 버릴 행 수 (SQL Server 에서 ORDER BY 가 없을 때)
public struct PagedSQL: Sendable, Equatable {
    public let sql: String
    public let skip: Int
}

extension SQLDialect {
    /// SELECT 를 페이지 단위로 가져오는 SQL. 다음 페이지가 있는지 알기 위해 limit + 1 행을 요청한다.
    /// 이미 LIMIT/TOP/OFFSET/INTO/FOR UPDATE 가 있거나 SELECT 가 아니면 nil (그대로 실행).
    public func pagedSQL(_ sql: String, limit: Int, offset: Int) -> PagedSQL? {
        guard limit > 0 else { return nil }
        var body = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") { body.removeLast(); body = body.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kw = SQLText.firstKeyword(body)
        let upper = SQLText.stripComments(body).uppercased()
        let blocked = "\\bLIMIT\\s+\\d|\\bOFFSET\\b|\\bFETCH\\s+(FIRST|NEXT)\\b|\\bTOP\\s*\\(?\\s*\\d|\\bINTO\\b|\\bFOR\\s+UPDATE\\b|\\bFOR\\s+SHARE\\b"
        guard upper.range(of: blocked, options: .regularExpression) == nil else { return nil }
        let fetch = limit + 1

        switch kind {
        case .mysql, .redis, .postgres:
            guard kw == "SELECT" || kw == "WITH" else { return nil }
            return PagedSQL(sql: "\(body)\nLIMIT \(fetch)" + (offset > 0 ? " OFFSET \(offset)" : ""), skip: 0)
        case .mssql:
            if SQLText.hasTopLevelOrderBy(upper) {
                guard kw == "SELECT" || kw == "WITH" else { return nil }
                return PagedSQL(sql: "\(body)\nOFFSET \(offset) ROWS FETCH NEXT \(fetch) ROWS ONLY", skip: 0)
            }
            // ORDER BY 가 없으면 OFFSET 을 못 써서 TOP(앞 페이지 + 이번 페이지) 로 가져온 뒤 앞부분을 버린다.
            guard kw == "SELECT" else { return nil }
            let top = applyingLimit(body, limit: offset + fetch)
            return top == body ? nil : PagedSQL(sql: top, skip: offset)
        }
    }

    /// 쿼리 결과의 전체 행 수
    public func countSQL(_ sql: String) -> String? {
        var body = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") { body.removeLast(); body = body.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kw = SQLText.firstKeyword(body)
        guard kw == "SELECT" || (kw == "WITH" && kind != .mssql) else { return nil }
        if kind == .mssql {
            // SQL Server 는 서브쿼리 안의 ORDER BY 를 허용하지 않는다.
            body = SQLText.removingTopLevelOrderBy(body)
        }
        return "SELECT COUNT(*) FROM (\n\(body)\n) AS goddb_cnt"
    }
}

extension SQLText {
    /// 괄호 밖(맨 바깥) 마지막 ORDER BY 의 위치. 없으면 nil.
    static func topLevelOrderByRange(_ sql: String) -> Range<String.Index>? {
        let upper = sql.uppercased()
        var depth = 0
        var found: Range<String.Index>? = nil
        var i = upper.startIndex
        var quote: Character? = nil
        while i < upper.endIndex {
            let c = upper[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" || c == "`" || c == "[" {
                quote = c == "[" ? "]" : c
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, upper[i...].hasPrefix("ORDER"),
                      let r = upper.range(of: "^ORDER\\s+BY\\b", options: .regularExpression, range: i..<upper.endIndex) {
                let before = i == upper.startIndex ? " " : upper[upper.index(before: i)]
                if !(before.isLetter || before.isNumber || before == "_") { found = r }
            }
            i = upper.index(after: i)
        }
        guard let f = found else { return nil }
        // 원문 인덱스로 변환 (uppercased 는 한글/영문에서 길이가 같다고 가정)
        let start = sql.index(sql.startIndex, offsetBy: upper.distance(from: upper.startIndex, to: f.lowerBound))
        return start..<sql.endIndex
    }

    static func hasTopLevelOrderBy(_ sql: String) -> Bool { topLevelOrderByRange(sql) != nil }

    static func removingTopLevelOrderBy(_ sql: String) -> String {
        guard let r = topLevelOrderByRange(sql) else { return sql }
        return String(sql[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 테이블 이름 변경 / 삭제

extension SQLDialect {
    public func renameTableSQL(_ table: String, to newName: String) -> String {
        switch kind {
        case .mysql, .redis:
            return "RENAME TABLE \(quoteTable(table)) TO \(quoteIdent(newName));"
        case .postgres:
            return "ALTER TABLE \(quoteTable(table)) RENAME TO \(quoteIdent(newName));"
        case .mssql:
            // sp_rename 의 새 이름에는 스키마를 붙이지 않는다
            let bare = newName.split(separator: ".").last.map(String.init) ?? newName
            return "EXEC sp_rename \(quoteString(quoteTable(table))), \(quoteString(bare));"
        }
    }

    public func dropTableSQL(_ table: String) -> String {
        "DROP TABLE \(quoteTable(table));"
    }
}
