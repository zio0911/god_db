import Foundation

/// 쿼리 편집기 Tab 자동완성 후보를 만든다.
public enum SQLCompleter {

    public static let keywords: [String] = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "AS", "ON", "JOIN", "LEFT", "RIGHT",
        "INNER", "OUTER", "CROSS", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "UNION", "UNION ALL",
        "DISTINCT", "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "CREATE TABLE", "ALTER TABLE",
        "DROP TABLE", "TRUNCATE TABLE", "SHOW", "SHOW TABLES", "SHOW CREATE TABLE", "SHOW INDEX FROM",
        "DESC", "DESCRIBE", "EXPLAIN", "USE", "WITH", "CASE", "WHEN", "THEN", "ELSE", "END", "LIKE",
        "BETWEEN", "EXISTS", "ASC", "COUNT(*)", "SUM(", "AVG(", "MIN(", "MAX(", "IFNULL(", "COALESCE(",
        "NOW()", "DATE_FORMAT(", "CONCAT(", "SUBSTRING(", "CAST(", "IF(", "LENGTH(", "TRIM(", "REPLACE(",
        "PRIMARY KEY", "FOREIGN KEY", "REFERENCES", "DEFAULT", "AUTO_INCREMENT", "COMMENT",
        "ADD COLUMN", "MODIFY COLUMN", "CHANGE COLUMN", "DROP COLUMN", "ADD INDEX", "DROP INDEX",
        "VARCHAR(", "CHAR(", "INT", "BIGINT", "DECIMAL(", "DATETIME", "TIMESTAMP", "DATE", "TEXT",
        "TINYINT", "CURRENT_TIMESTAMP", "FOR UPDATE", "CALL",
        // PostgreSQL
        "ILIKE", "RETURNING", "SERIAL", "BIGSERIAL", "BOOLEAN", "JSONB", "NOW()", "COALESCE(", "STRING_AGG(",
        "ON CONFLICT", "DO NOTHING", "INTERVAL", "TIMESTAMPTZ",
        // SQL Server
        "TOP", "EXEC", "NVARCHAR(", "DATETIME2", "GETDATE()", "SYSDATETIME()", "ISNULL(", "WITH (NOLOCK)",
        "OFFSET", "FETCH NEXT", "ROWS ONLY", "IDENTITY(1,1)", "UNIQUEIDENTIFIER", "NEWID()",
    ]

    /// 알리아스로 쓰일 수 없는 단어 (FROM t WHERE … 에서 WHERE 를 알리아스로 오인하지 않게)
    private static let reserved: Set<String> = [
        "WHERE", "ON", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "GROUP", "ORDER", "HAVING",
        "LIMIT", "SET", "VALUES", "UNION", "USING", "STRAIGHT_JOIN", "NATURAL", "FOR", "WINDOW", "AS",
    ]

    /// 구문에서 "알리아스/테이블명(소문자) → 실제 테이블명" 을 찾는다.
    public static func aliases(in statement: String) -> [String: String] {
        let pattern = "\\b(?:FROM|JOIN|UPDATE|INTO)\\s+`?([A-Za-z0-9_$.]+)`?(?:\\s+(?:AS\\s+)?`?([A-Za-z0-9_$]+)`?)?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [:] }
        var map: [String: String] = [:]
        let ns = statement as NSString
        // 쉼표로 이어진 FROM a x, b y 도 처리
        let commaRegex = try? NSRegularExpression(pattern: ",\\s*`?([A-Za-z0-9_$.]+)`?(?:\\s+(?:AS\\s+)?`?([A-Za-z0-9_$]+)`?)?", options: [.caseInsensitive])
        for regex in [regex, commaRegex].compactMap({ $0 }) {
            for m in regex.matches(in: statement, range: NSRange(location: 0, length: ns.length)) {
                guard m.range(at: 1).location != NSNotFound else { continue }
                var table = ns.substring(with: m.range(at: 1))
                if let dot = table.lastIndex(of: ".") { table = String(table[table.index(after: dot)...]) }
                map[table.lowercased()] = table
                if m.range(at: 2).location != NSNotFound {
                    let alias = ns.substring(with: m.range(at: 2))
                    if !reserved.contains(alias.uppercased()) { map[alias.lowercased()] = table }
                }
            }
        }
        return map
    }

    /// - Parameters:
    ///   - prefix: 커서 앞에서 입력 중인 단어
    ///   - qualifier: `m.em` 처럼 점 앞의 단어 (없으면 nil)
    ///   - statement: 커서가 있는 구문 전체 (알리아스 해석용)
    public static func suggestions(prefix: String, qualifier: String?, statement: String,
                                   tables: [TableMeta], routines: [RoutineMeta] = [], limit: Int = 50) -> [String] {
        let p = prefix.lowercased()
        let byName = Dictionary(tables.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let aliasMap = aliases(in: statement)

        func matches(_ s: String) -> Bool { p.isEmpty || s.lowercased().hasPrefix(p) }
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            if matches(s), seen.insert(s.lowercased()).inserted { out.append(s) }
        }

        // 1) 테이블/알리아스 뒤의 점 → 그 테이블의 컬럼만
        if let qualifier {
            let q = qualifier.lowercased()
            let tableName = aliasMap[q] ?? byName[q]?.name
            if let t = tableName.flatMap({ byName[$0.lowercased()] }) {
                t.columns.sorted { $0.position < $1.position }.forEach { add($0.name) }
            }
            return Array(out.prefix(limit))
        }

        // 2) 구문에 등장한 테이블의 컬럼
        let usedTables = Set(aliasMap.values.map { $0.lowercased() }).compactMap { byName[$0] }
        for t in usedTables.sorted(by: { $0.name < $1.name }) {
            t.columns.sorted { $0.position < $1.position }.forEach { add($0.name) }
        }
        // 3) FROM/JOIN 바로 뒤라면 테이블을 키워드보다 먼저
        let afterTableKeyword = statement.range(of: "\\b(FROM|JOIN|UPDATE|INTO|TABLE|DESC|DESCRIBE)\\s+[A-Za-z0-9_$]*$",
                                                options: [.regularExpression, .caseInsensitive]) != nil
        if afterTableKeyword {
            tables.forEach { add($0.name) }
            routines.filter { $0.kind == .view }.forEach { add($0.name) }
        }
        // 4) 키워드 (입력이 소문자면 소문자로)
        let lowerCase = prefix.first.map { $0.isLowercase } ?? false
        for k in keywords { add(lowerCase ? k.lowercased() : k) }
        // 5) 나머지 테이블, 뷰, 프로시저/함수
        tables.forEach { add($0.name) }
        routines.filter { $0.kind != .trigger }.forEach { add($0.name) }

        return Array(out.prefix(limit))
    }
}
