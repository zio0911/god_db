import Foundation

/// PostgreSQL. 사이드바의 "DB" 선택은 스키마(search_path)를 뜻한다. 접속 DB 는 접속 설정에서 고른다.
public struct PostgresDialect: SQLDialect {
    public init() {}
    public var kind: DatabaseKind { .postgres }

    public func quoteIdent(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func quoteString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public var readOnlySessionSQL: String? { "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY" }

    public var databasesSQL: String {
        """
        SELECT nspname FROM pg_namespace
         WHERE nspname NOT IN ('pg_catalog', 'information_schema')
           AND nspname NOT LIKE 'pg_toast%' AND nspname NOT LIKE 'pg_temp%'
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
        """
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
        """
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
        var lines = table.columns.sorted { $0.position < $1.position }.map { "  " + columnDefinition($0) }
        if let pk = table.indexes.first(where: \.isPrimary) {
            lines.append("  CONSTRAINT \(quoteIdent(pk.name)) PRIMARY KEY \(indexColumns(pk))")
        }
        var out = ["CREATE TABLE \(quoteIdent(table.name)) (\n" + lines.joined(separator: ",\n") + "\n);"]
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
                out.append("ALTER TABLE \(t) ADD COLUMN \(columnDefinition(c));")
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
}
