import Foundation

/// PostgreSQL. 사이드바의 "DB" 선택은 스키마(search_path)를 뜻한다. 접속 DB 는 접속 설정에서 고른다.
/// Amazon Redshift 도 PostgreSQL 접속으로 붙는다. 연결할 때 `version()` 으로 알아내 `redshift` 를 켜고,
/// PostgreSQL 8.0 기반 카탈로그에서 동작하는 메타데이터 조회를 쓴다 (identity · prokind · unnest · LATERAL 없음).
public struct PostgresDialect: SQLDialect {
    /// Amazon Redshift 접속
    public let redshift: Bool
    public init(redshift: Bool = false) { self.redshift = redshift }
    public var kind: DatabaseKind { .postgres }

    public func quoteIdent(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 문자열 상수. 백슬래시가 있으면 E'…' 로 쓰고 \\ 로 바꾼다 — 서버의 standard_conforming_strings 설정과
    /// 상관없이 같은 값으로 읽힌다 (#197). Redshift 는 E'' 를 지원하지 않아 예전처럼 둔다.
    public func quoteString(_ value: String) -> String {
        let quoted = value.replacingOccurrences(of: "'", with: "''")
        guard !redshift, value.contains("\\") else { return "'" + quoted + "'" }
        return "E'" + quoted.replacingOccurrences(of: "\\", with: "\\\\") + "'"
    }

    public var readOnlySessionSQL: String? { "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY" }
    /// 큰 테이블의 순차 스캔은 기본으로 직전 스캔이 멈춘 곳부터 시작한다 (synchronize_seqscans).
    /// 그러면 ORDER BY 없는 결과를 LIMIT/OFFSET 으로 나눠 받을 때 페이지끼리 행이 겹치거나 빠진다. 항상 처음부터 읽게 한다.
    public var sessionSetupSQL: String? { redshift ? nil : "SET synchronize_seqscans = off" }
    /// 모든 문장에 적용 (Redshift 도 같은 변수, 밀리초)
    public func statementTimeoutSQL(milliseconds: Int) -> String? { "SET statement_timeout = \(milliseconds)" }
    public var sessionIDSQL: String { "SELECT pg_backend_pid()" }
    public func cancelSQL(sessionID: Int) -> String { "SELECT pg_cancel_backend(\(sessionID))" }

    public var allTablesSQL: String? {
        if redshift {
            // Redshift 의 information_schema.tables 는 권한 있는 테이블만 보여 비어 있을 수 있다
            return """
            SELECT n.nspname, c.relname, CASE c.relkind WHEN 'v' THEN 'VIEW' ELSE 'BASE TABLE' END
              FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE c.relkind IN ('r', 'v') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
               AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%'
               AND has_schema_privilege(n.nspname, 'USAGE')
             ORDER BY 1, 2 LIMIT 20000
            """
        }
        return """
        SELECT table_schema, table_name, table_type FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema') AND table_schema NOT LIKE 'pg_toast%'
        ORDER BY table_schema, table_name LIMIT 20000
        """
    }

    public var databasesSQL: String {
        // Redshift: 사용 권한(USAGE) 없는 스키마는 고르면 search_path 가 비어 "테이블 없음" 이 되므로 빼고 보여준다
        """
        SELECT nspname FROM pg_namespace
         WHERE nspname NOT IN ('pg_catalog', 'information_schema')
           AND nspname NOT LIKE 'pg_toast%' AND nspname NOT LIKE 'pg_temp%'\(redshift ? "\n   AND has_schema_privilege(nspname, 'USAGE')" : "")
         ORDER BY nspname
        """
    }

    public func useSQL(_ name: String) -> String { "SET search_path TO \(quoteIdent(name))" }

    public func initialContainer(profile: ConnectionProfile, available: [String]) -> String {
        available.contains("public") ? "public" : (available.first ?? "public")
    }

    public func tablesSQL(_ schema: String) -> String {
        """
        SELECT c.relname, COALESCE(obj_description(c.oid, 'pg_class'), '')
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = \(quoteString(schema)) AND c.relkind IN ('r', 'p')
         ORDER BY c.relname
        """
    }

    public func columnsSQL(_ schema: String) -> String {
        if redshift { return redshiftColumnsSQL(schema) }
        return """
        SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod),
               CASE WHEN a.attnotnull THEN 'NO' ELSE 'YES' END,
               pg_get_expr(d.adbin, d.adrelid),
               CASE a.attidentity WHEN 'a' THEN 'identity always' WHEN 'd' THEN 'identity' ELSE '' END,
               CASE WHEN EXISTS (SELECT 1 FROM pg_index i
                                  WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY(i.indkey))
                    THEN 'PRI' ELSE '' END,
               COALESCE(col_description(c.oid, a.attnum), ''), a.attnum
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
         WHERE n.nspname = \(quoteString(schema)) AND c.relkind IN ('r', 'p')
           AND a.attnum > 0 AND NOT a.attisdropped
         ORDER BY c.relname, a.attnum
        """
    }

    public func indexesSQL(_ schema: String) -> String {
        if redshift { return redshiftPrimaryKeysSQL(schema) }
        return """
        SELECT t.relname, i.relname, CASE WHEN ix.indisunique THEN '0' ELSE '1' END, a.attname,
               CASE WHEN ix.indisprimary THEN '1' ELSE '0' END,
               CASE WHEN EXISTS (SELECT 1 FROM pg_constraint con WHERE con.conindid = ix.indexrelid)
                    THEN '1' ELSE '0' END
          FROM pg_index ix
          JOIN pg_class t ON t.oid = ix.indrelid
          JOIN pg_class i ON i.oid = ix.indexrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          JOIN LATERAL unnest(ix.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) ON true
          JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
         WHERE n.nspname = \(quoteString(schema)) AND t.relkind IN ('r', 'p')
         ORDER BY t.relname, i.relname, k.ord
        """
    }

    public func routinesSQL(_ schema: String) -> String {
        let s = quoteString(schema)
        if redshift {
            // 프로시저 구분은 pg_proc_info.prokind. 트리거는 없다
            return """
            SELECT 'VIEW', c.relname, COALESCE(obj_description(c.oid, 'pg_class'), '')
              FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = \(s) AND c.relkind = 'v'
            UNION ALL
            SELECT CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END, p.proname,
                   COALESCE(obj_description(p.prooid, 'pg_proc'), '')
              FROM pg_proc_info p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = \(s)
            ORDER BY 1, 2
            """
        }
        return """
        SELECT 'VIEW', c.relname, COALESCE(obj_description(c.oid, 'pg_class'), '')
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = \(s) AND c.relkind IN ('v', 'm')
        UNION ALL
        SELECT CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END, p.proname,
               COALESCE(obj_description(p.oid, 'pg_proc'), '')
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = \(s) AND p.prokind IN ('f', 'p')
        UNION ALL
        SELECT 'TRIGGER', t.tgname, 'ON ' || c.relname
          FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = \(s) AND NOT t.tgisinternal
        ORDER BY 1, 2
        """
    }

    public func definitionSQL(_ routine: RoutineMeta, schema: String) -> String {
        let s = quoteString(schema), name = quoteString(routine.name)
        switch routine.kind {
        case .view:
            return """
            SELECT pg_get_viewdef(c.oid, true) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = \(s) AND c.relname = \(name)
            """
        case .procedure where redshift, .function where redshift:
            // pg_get_functiondef 가 없다 → 본문만
            return """
            SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = \(s) AND p.proname = \(name) ORDER BY p.oid LIMIT 1
            """
        case .procedure, .function:
            return """
            SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = \(s) AND p.proname = \(name) ORDER BY p.oid LIMIT 1
            """
        case .trigger:
            return """
            SELECT pg_get_triggerdef(t.oid, true) FROM pg_trigger t
              JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = \(s) AND t.tgname = \(name) LIMIT 1
            """
        }
    }

    public func formatDefinition(_ routine: RoutineMeta, schema: String, body: String) -> String {
        guard routine.kind == .view else { return body }
        return "CREATE OR REPLACE VIEW \(quoteIdent(schema)).\(quoteIdent(routine.name)) AS\n" + body
    }

    public func createTableSQL(_ table: TableMeta) -> String {
        if redshift { return redshiftCreateTableSQL(table) }
        var lines = table.columns.sorted { $0.position < $1.position }.map { "  " + columnDefinition($0) }
        if let pk = table.indexes.first(where: \.isPrimary) {
            lines.append("  CONSTRAINT \(quoteIdent(pk.name)) PRIMARY KEY \(indexColumns(pk))")
        }
        let sequences = table.columns.compactMap { c in Self.sequenceName(c).map { (c, $0) } }
        var out = sequences.map { createSequenceSQL($1, column: $0) }
        out.append("CREATE TABLE \(quoteIdent(table.name)) (\n" + lines.joined(separator: ",\n") + "\n);")
        // serial 처럼 테이블을 지우면 시퀀스도 함께 지워지게
        out += sequences.map { "ALTER SEQUENCE \($1) OWNED BY \(quoteIdent(table.name)).\(quoteIdent($0.name));" }
        for i in table.indexes where !i.isPrimary {
            out.append("CREATE \(i.unique ? "UNIQUE " : "")INDEX \(quoteIdent(i.name)) ON \(quoteIdent(table.name)) \(indexColumns(i));")
        }
        if !table.comment.isEmpty {
            out.append("COMMENT ON TABLE \(quoteIdent(table.name)) IS \(quoteString(table.comment));")
        }
        for c in table.columns where !c.comment.isEmpty {
            out.append("COMMENT ON COLUMN \(quoteIdent(table.name)).\(quoteIdent(c.name)) IS \(quoteString(c.comment));")
        }
        return out.joined(separator: "\n")
    }

    public func explain(_ sql: String) -> ExplainSteps {
        ExplainSteps(main: "EXPLAIN \(sql)", treeColumn: "QUERY PLAN")
    }

    public func columnDefinition(_ c: ColumnMeta) -> String {
        var parts = [quoteIdent(c.name), c.columnType]
        let extra = c.extra.lowercased()
        if extra.contains("identity") {
            parts.append(extra.contains("always") ? "GENERATED ALWAYS AS IDENTITY" : "GENERATED BY DEFAULT AS IDENTITY")
        }
        if !c.nullable { parts.append("NOT NULL") }
        if let d = c.defaultValue { parts.append("DEFAULT \(defaultLiteral(d, extra: c.extra))") }
        return parts.joined(separator: " ")
    }

    /// PostgreSQL 기본값은 SQL 식 그대로 쓴다 (문자열은 'A' 처럼 따옴표 포함, 예: 'A'::bpchar, now()).
    public func defaultLiteral(_ value: String, extra: String) -> String { value }

    /// PostgreSQL 은 변경마다 별도 문장으로 만든다.
    public func render(_ changes: [SchemaChange], table: String) -> String {
        let t = quoteIdent(table)
        var out: [String] = []
        for change in changes {
            switch change {
            case .dropIndex(let i):
                out.append(i.isConstraint
                           ? "ALTER TABLE \(t) DROP CONSTRAINT \(quoteIdent(i.name));"
                           : "DROP INDEX \(quoteIdent(i.name));")
            case .dropColumn(let name):
                out.append("ALTER TABLE \(t) DROP COLUMN \(quoteIdent(name));")
            case .renameColumn(let old, let new):
                out.append("ALTER TABLE \(t) RENAME COLUMN \(quoteIdent(old.name)) TO \(quoteIdent(new.name));")
                out += alterColumn(t, old: old, new: new)
            case .modifyColumn(let old, let new):
                out += alterColumn(t, old: old, new: new)
            case .addColumn(let c, _):
                let sequence = Self.sequenceName(c)
                if let sequence { out.append(createSequenceSQL(sequence, column: c)) }
                out.append("ALTER TABLE \(t) ADD COLUMN \(columnDefinition(c));")
                if let sequence { out.append("ALTER SEQUENCE \(sequence) OWNED BY \(t).\(quoteIdent(c.name));") }
                if !c.comment.isEmpty {
                    out.append("COMMENT ON COLUMN \(t).\(quoteIdent(c.name)) IS \(quoteString(c.comment));")
                }
            case .addIndex(let i):
                if i.isPrimary {
                    out.append("ALTER TABLE \(t) ADD PRIMARY KEY \(indexColumns(i));")
                } else {
                    out.append("CREATE \(i.unique ? "UNIQUE " : "")INDEX \(quoteIdent(i.name)) ON \(t) \(indexColumns(i));")
                }
            case .tableComment(_, let new):
                out.append("COMMENT ON TABLE \(t) IS \(new.isEmpty ? "NULL" : quoteString(new));")
            }
        }
        return out.joined(separator: "\n")
    }

    /// 기본값이 `nextval('시퀀스'::regclass)` (serial 컬럼)이면 시퀀스 이름 (SQL 에 그대로 쓸 수 있는 형태).
    /// 다른 스키마에 테이블을 만들 때 시퀀스가 없으면 CREATE TABLE 이 실패하므로 먼저 만든다.
    static func sequenceName(_ c: ColumnMeta) -> String? {
        guard let d = c.defaultValue,
              let m = d.range(of: #"^nextval\('((?:[^']|'')+)'(::regclass)?\)$"#, options: .regularExpression) else { return nil }
        let inner = d[m].dropFirst("nextval('".count)
        guard let end = inner.range(of: "'", options: .backwards) else { return nil }
        return String(inner[..<end.lowerBound]).replacingOccurrences(of: "''", with: "'")
    }

    func createSequenceSQL(_ name: String, column c: ColumnMeta) -> String {
        let type = c.columnType.lowercased()
        let asType = ["smallint", "integer", "bigint"].contains(type) ? " AS \(type)" : ""
        return "CREATE SEQUENCE IF NOT EXISTS \(name)\(asType);"
    }

    private func alterColumn(_ t: String, old: ColumnMeta, new: ColumnMeta) -> [String] {
        let c = "\(t) ALTER COLUMN \(quoteIdent(new.name))"
        var out: [String] = []
        if old.columnType.lowercased() != new.columnType.lowercased() {
            out.append("ALTER TABLE \(c) TYPE \(new.columnType) USING \(quoteIdent(new.name))::\(new.columnType);")
        }
        if old.nullable != new.nullable {
            out.append("ALTER TABLE \(c) \(new.nullable ? "DROP" : "SET") NOT NULL;")
        }
        if old.defaultValue != new.defaultValue {
            out.append(new.defaultValue.map { "ALTER TABLE \(c) SET DEFAULT \($0);" } ?? "ALTER TABLE \(c) DROP DEFAULT;")
        }
        if old.comment != new.comment {
            out.append("COMMENT ON COLUMN \(t).\(quoteIdent(new.name)) IS \(new.comment.isEmpty ? "NULL" : quoteString(new.comment));")
        }
        return out
    }

    // MARK: - Redshift

    /// 컬럼 순서는 PostgreSQL 과 같다. 6번째(extra)에 "distkey" · "sortkey N" (N = 정렬 키 안의 순서)
    func redshiftColumnsSQL(_ schema: String) -> String {
        """
        SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod),
               CASE WHEN a.attnotnull THEN 'NO' ELSE 'YES' END,
               pg_get_expr(d.adbin, d.adrelid),
               TRIM(CASE WHEN a.attisdistkey THEN 'distkey' ELSE '' END
                    || CASE WHEN a.attsortkeyord <> 0 THEN ' sortkey ' || CAST(ABS(a.attsortkeyord) AS varchar) ELSE '' END),
               CASE WHEN EXISTS (SELECT 1 FROM pg_constraint con
                                  WHERE con.conrelid = c.oid AND con.contype = 'p' AND a.attnum = ANY(con.conkey))
                    THEN 'PRI' ELSE '' END,
               COALESCE(col_description(c.oid, a.attnum), ''), a.attnum
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
         WHERE n.nspname = \(quoteString(schema)) AND c.relkind = 'r'
           AND a.attnum > 0 AND NOT a.attisdropped
         ORDER BY c.relname, a.attnum
        """
    }

    /// Redshift 에는 인덱스가 없다. 기본 키(정보용 제약)만 인덱스 모양으로 돌려준다
    func redshiftPrimaryKeysSQL(_ schema: String) -> String {
        """
        SELECT c.relname, con.conname, '0', a.attname, '1', '1'
          FROM pg_constraint con
          JOIN pg_class c ON c.oid = con.conrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          CROSS JOIN generate_series(1, 32) AS g(i)
          JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[g.i]
         WHERE con.contype = 'p' AND n.nspname = \(quoteString(schema))
         ORDER BY c.relname, con.conname, g.i
        """
    }

    /// 외래 키 (정보용 제약). unnest · LATERAL 대신 배열 첨자
    func redshiftForeignKeysSQL(_ schema: String) -> String {
        let s = quoteString(schema)
        return """
        SELECT c.relname, con.conname, a.attname, rc.relname, ra.attname, g.i
          FROM pg_constraint con
          JOIN pg_class c ON c.oid = con.conrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_class rc ON rc.oid = con.confrelid
          JOIN pg_namespace rn ON rn.oid = rc.relnamespace
          CROSS JOIN generate_series(1, 32) AS g(i)
          JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[g.i]
          JOIN pg_attribute ra ON ra.attrelid = con.confrelid AND ra.attnum = con.confkey[g.i]
         WHERE con.contype = 'f' AND n.nspname = \(s) AND rn.nspname = \(s)
         ORDER BY 1, 2, 6
        """
    }

    /// "distkey" / "sortkey N" (extra 에서)
    static func redshiftKeys(_ c: ColumnMeta) -> (dist: Bool, sort: Int?) {
        let parts = c.extra.lowercased().split(separator: " ")
        let sort = parts.firstIndex(of: "sortkey").flatMap { i in i + 1 < parts.count ? Int(parts[i + 1]) : nil }
        return (parts.contains("distkey"), sort)
    }

    /// CREATE TABLE + DISTKEY · SORTKEY. 인덱스 · 시퀀스는 없다
    func redshiftCreateTableSQL(_ table: TableMeta) -> String {
        let columns = table.columns.sorted { $0.position < $1.position }
        var lines = columns.map { "  " + columnDefinition($0) }
        if let pk = table.indexes.first(where: \.isPrimary) {
            lines.append("  CONSTRAINT \(quoteIdent(pk.name)) PRIMARY KEY \(indexColumns(pk))")
        }
        var tail = ""
        if let dist = columns.first(where: { Self.redshiftKeys($0).dist }) {
            tail += "\nDISTKEY (\(quoteIdent(dist.name)))"
        }
        let sort = columns.compactMap { c in Self.redshiftKeys(c).sort.map { ($0, c.name) } }.sorted { $0.0 < $1.0 }
        if !sort.isEmpty {
            tail += "\nSORTKEY (\(sort.map { quoteIdent($0.1) }.joined(separator: ", ")))"
        }
        var out = ["CREATE TABLE \(quoteIdent(table.name)) (\n" + lines.joined(separator: ",\n") + "\n)" + tail + ";"]
        if !table.comment.isEmpty {
            out.append("COMMENT ON TABLE \(quoteIdent(table.name)) IS \(quoteString(table.comment));")
        }
        for c in columns where !c.comment.isEmpty {
            out.append("COMMENT ON COLUMN \(quoteIdent(table.name)).\(quoteIdent(c.name)) IS \(quoteString(c.comment));")
        }
        return out.joined(separator: "\n")
    }

    /// `version()` 결과에서 "Redshift 1.0.12345" (없으면 nil)
    public static func redshiftVersion(_ version: String) -> String? {
        guard let r = version.range(of: #"Redshift [0-9][0-9.]*"#, options: .regularExpression) else { return nil }
        return String(version[r])
    }
}

extension SQLDialect {
    /// Amazon Redshift 접속인지
    public var isRedshift: Bool { (self as? PostgresDialect)?.redshift == true }
}
