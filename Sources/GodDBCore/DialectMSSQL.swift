import Foundation

/// SQL Server. 테이블 이름은 dbo 스키마면 `table`, 그 외는 `schema.table` 로 다룬다.
public struct MSSQLDialect: SQLDialect {
    public init() {}
    public var kind: DatabaseKind { .mssql }

    public func quoteIdent(_ name: String) -> String {
        "[" + name.replacingOccurrences(of: "]", with: "]]") + "]"
    }

    public func quoteTable(_ name: String) -> String {
        let (schema, table) = split(name)
        return schema.map { "\(quoteIdent($0)).\(quoteIdent(table))" } ?? quoteIdent(table)
    }

    public func quoteString(_ value: String) -> String {
        "N'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// `sales.orders` → ("sales", "orders"), `orders` → (nil, "orders")
    func split(_ name: String) -> (String?, String) {
        guard let dot = name.firstIndex(of: ".") else { return (nil, name) }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// SQL Server 는 세션 단위 읽기전용 설정이 없어서 앱 검사만 한다.
    public var readOnlySessionSQL: String? { nil }

    public var databasesSQL: String {
        "SELECT name FROM sys.databases WHERE name NOT IN ('master', 'tempdb', 'model', 'msdb') ORDER BY name"
    }

    public func useSQL(_ name: String) -> String { "USE \(quoteIdent(name))" }
    public var metadataNeedsUse: Bool { true }

    /// LIMIT 대신 SELECT 뒤에 TOP n 을 넣는다.
    public func applyingLimit(_ sql: String, limit: Int) -> String {
        guard limit > 0, SQLText.firstKeyword(sql) == "SELECT" else { return sql }
        let upper = SQLText.stripComments(sql).uppercased()
        if upper.range(of: "\\bTOP\\s*\\(?\\s*\\d|\\bOFFSET\\b|\\bFETCH\\b|\\bINTO\\b", options: .regularExpression) != nil {
            return sql
        }
        let pattern = "^((?:\\s|--[^\\n]*\\n|/\\*[\\s\\S]*?\\*/)*)(SELECT)(\\s+(?:DISTINCT|ALL)\\b)?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: sql, range: NSRange(location: 0, length: (sql as NSString).length)) else {
            return sql
        }
        let ns = sql as NSString
        let head = ns.substring(with: m.range)
        var trimmed = (ns.substring(from: m.range.upperBound)).trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") { trimmed.removeLast() }
        return "\(head) TOP \(limit) \(trimmed)"
    }

    private let tableName = "CASE WHEN s.name = 'dbo' THEN t.name ELSE s.name + '.' + t.name END"

    public func tablesSQL(_ schema: String) -> String {
        """
        SELECT \(tableName), ISNULL(CAST(ep.value AS nvarchar(4000)), '')
          FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
          LEFT JOIN sys.extended_properties ep
            ON ep.class = 1 AND ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = 'MS_Description'
         ORDER BY 1
        """
    }

    public func columnsSQL(_ schema: String) -> String {
        """
        SELECT \(tableName), c.name,
               CASE WHEN ty.name IN ('varchar', 'char', 'varbinary', 'binary')
                      THEN ty.name + '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length AS varchar(10)) END + ')'
                    WHEN ty.name IN ('nvarchar', 'nchar')
                      THEN ty.name + '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length / 2 AS varchar(10)) END + ')'
                    WHEN ty.name IN ('decimal', 'numeric')
                      THEN ty.name + '(' + CAST(c.precision AS varchar(10)) + ',' + CAST(c.scale AS varchar(10)) + ')'
                    WHEN ty.name IN ('datetime2', 'time', 'datetimeoffset')
                      THEN ty.name + '(' + CAST(c.scale AS varchar(10)) + ')'
                    ELSE ty.name END,
               CASE WHEN c.is_nullable = 1 THEN 'YES' ELSE 'NO' END,
               dc.definition,
               CASE WHEN c.is_identity = 1 THEN 'identity' ELSE '' END,
               CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic
                                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                                  WHERE i.is_primary_key = 1 AND ic.object_id = c.object_id AND ic.column_id = c.column_id)
                    THEN 'PRI' ELSE '' END,
               ISNULL(CAST(ep.value AS nvarchar(4000)), ''), c.column_id
          FROM sys.columns c
          JOIN sys.tables t ON t.object_id = c.object_id
          JOIN sys.schemas s ON s.schema_id = t.schema_id
          JOIN sys.types ty ON ty.user_type_id = c.user_type_id
          LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
          LEFT JOIN sys.extended_properties ep
            ON ep.class = 1 AND ep.major_id = c.object_id AND ep.minor_id = c.column_id AND ep.name = 'MS_Description'
         ORDER BY 1, c.column_id
        """
    }

    public func indexesSQL(_ schema: String) -> String {
        """
        SELECT \(tableName), i.name, CASE WHEN i.is_unique = 1 THEN '0' ELSE '1' END, c.name,
               CASE WHEN i.is_primary_key = 1 THEN '1' ELSE '0' END,
               CASE WHEN i.is_primary_key = 1 OR i.is_unique_constraint = 1 THEN '1' ELSE '0' END
          FROM sys.indexes i
          JOIN sys.tables t ON t.object_id = i.object_id
          JOIN sys.schemas s ON s.schema_id = t.schema_id
          JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
          JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
         WHERE i.type > 0
         ORDER BY 1, i.name, ic.key_ordinal
        """
    }

    public func routinesSQL(_ schema: String) -> String {
        """
        SELECT CASE o.type WHEN 'V' THEN 'VIEW' WHEN 'P' THEN 'PROCEDURE' WHEN 'TR' THEN 'TRIGGER' ELSE 'FUNCTION' END,
               CASE WHEN s.name = 'dbo' THEN o.name ELSE s.name + '.' + o.name END,
               CASE WHEN o.type = 'TR' THEN 'ON ' + OBJECT_NAME(o.parent_object_id) ELSE '' END
          FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
         WHERE o.type IN ('V', 'P', 'FN', 'IF', 'TF', 'TR') AND o.is_ms_shipped = 0
         ORDER BY 1, 2
        """
    }

    public func definitionSQL(_ routine: RoutineMeta, schema: String) -> String {
        "SELECT OBJECT_DEFINITION(OBJECT_ID(\(quoteString(quoteTable(routine.name)))))"
    }

    public func formatDefinition(_ routine: RoutineMeta, schema: String, body: String) -> String { body }

    public func createTableSQL(_ table: TableMeta) -> String {
        let t = quoteTable(table.name)
        var lines = table.columns.sorted { $0.position < $1.position }.map { "  " + columnDefinition($0) }
        if let pk = table.indexes.first(where: \.isPrimary) {
            lines.append("  CONSTRAINT \(quoteIdent(pk.name)) PRIMARY KEY \(indexColumns(pk))")
        }
        var out = ["CREATE TABLE \(t) (\n" + lines.joined(separator: ",\n") + "\n);"]
        for i in table.indexes where !i.isPrimary {
            if i.isConstraint {
                out.append("ALTER TABLE \(t) ADD CONSTRAINT \(quoteIdent(i.name)) UNIQUE \(indexColumns(i));")
            } else {
                out.append("CREATE \(i.unique ? "UNIQUE " : "")INDEX \(quoteIdent(i.name)) ON \(t) \(indexColumns(i));")
            }
        }
        if !table.comment.isEmpty { out.append(commentSQL(table.name, column: nil, comment: table.comment, exists: false)) }
        for c in table.columns where !c.comment.isEmpty {
            out.append(commentSQL(table.name, column: c.name, comment: c.comment, exists: false))
        }
        return out.joined(separator: "\n")
    }

    /// SHOWPLAN_ALL 은 같은 연결에서 따로 켜고 꺼야 한다.
    public func explain(_ sql: String) -> ExplainSteps {
        ExplainSteps(before: ["SET SHOWPLAN_ALL ON"], main: sql, after: ["SET SHOWPLAN_ALL OFF"], treeColumn: "StmtText")
    }

    public func columnDefinition(_ c: ColumnMeta) -> String {
        var parts = [quoteIdent(c.name), c.columnType]
        if c.extra.lowercased().contains("identity") { parts.append("IDENTITY(1,1)") }
        parts.append(c.nullable ? "NULL" : "NOT NULL")
        if let d = c.defaultValue { parts.append("DEFAULT \(defaultLiteral(d, extra: c.extra))") }
        return parts.joined(separator: " ")
    }

    /// SQL Server 기본값도 식 그대로 쓴다 (예: ('A'), (getdate())).
    public func defaultLiteral(_ value: String, extra: String) -> String { value }

    /// MS_Description 확장 속성으로 코멘트를 단다.
    func commentSQL(_ table: String, column: String?, comment: String, exists: Bool) -> String {
        let (schema, name) = split(table)
        let proc = comment.isEmpty ? "sp_dropextendedproperty" : (exists ? "sp_updateextendedproperty" : "sp_addextendedproperty")
        var args = ["@name = N'MS_Description'"]
        if !comment.isEmpty { args.append("@value = \(quoteString(comment))") }
        args += ["@level0type = N'SCHEMA'", "@level0name = \(quoteString(schema ?? "dbo"))",
                 "@level1type = N'TABLE'", "@level1name = \(quoteString(name))"]
        if let column { args += ["@level2type = N'COLUMN'", "@level2name = \(quoteString(column))"] }
        return "EXEC sys.\(proc) " + args.joined(separator: ", ") + ";"
    }

    public func render(_ changes: [SchemaChange], table: String) -> String {
        let t = quoteTable(table)
        let (schema, name) = split(table)
        var out: [String] = []
        for change in changes {
            switch change {
            case .dropIndex(let i):
                out.append(i.isConstraint
                           ? "ALTER TABLE \(t) DROP CONSTRAINT \(quoteIdent(i.name));"
                           : "DROP INDEX \(quoteIdent(i.name)) ON \(t);")
            case .dropColumn(let col):
                out.append("ALTER TABLE \(t) DROP COLUMN \(quoteIdent(col));")
            case .renameColumn(let old, let new):
                let path = quoteString("\(schema ?? "dbo").\(name).\(old.name)")
                out.append("EXEC sp_rename \(path), \(quoteString(new.name)), 'COLUMN';")
                out += alterColumn(t, table: table, old: old, new: new)
            case .modifyColumn(let old, let new):
                out += alterColumn(t, table: table, old: old, new: new)
            case .addColumn(let c, _):
                out.append("ALTER TABLE \(t) ADD \(columnDefinition(c));")
                if !c.comment.isEmpty { out.append(commentSQL(table, column: c.name, comment: c.comment, exists: false)) }
            case .addIndex(let i):
                if i.isPrimary {
                    out.append("ALTER TABLE \(t) ADD CONSTRAINT \(quoteIdent(i.name)) PRIMARY KEY \(indexColumns(i));")
                } else {
                    out.append("CREATE \(i.unique ? "UNIQUE " : "")INDEX \(quoteIdent(i.name)) ON \(t) \(indexColumns(i));")
                }
            case .tableComment(let old, let new):
                out.append(commentSQL(table, column: nil, comment: new, exists: !old.isEmpty))
            }
        }
        return out.joined(separator: "\n")
    }

    private func alterColumn(_ t: String, table: String, old: ColumnMeta, new: ColumnMeta) -> [String] {
        var out: [String] = []
        if old.columnType.lowercased() != new.columnType.lowercased() || old.nullable != new.nullable {
            out.append("ALTER TABLE \(t) ALTER COLUMN \(quoteIdent(new.name)) \(new.columnType) \(new.nullable ? "NULL" : "NOT NULL");")
        }
        if old.defaultValue != new.defaultValue {
            if old.defaultValue != nil {
                out.append(tr("-- 기존 기본값 제약조건을 먼저 지워야 해요: ALTER TABLE %@ DROP CONSTRAINT <기본값 제약조건 이름>;", "\(t)"))
            }
            if let d = new.defaultValue {
                out.append("ALTER TABLE \(t) ADD DEFAULT \(d) FOR \(quoteIdent(new.name));")
            }
        }
        if old.comment != new.comment {
            out.append(commentSQL(table, column: new.name, comment: new.comment, exists: !old.comment.isEmpty))
        }
        return out
    }
}
