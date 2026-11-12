import Foundation

/// 바이너리 값 표시 (DataGrip 처럼 0x 16진수)
public enum BinaryText {
    public static func hex<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        let digits = Array("0123456789ABCDEF".utf8)
        var out = [UInt8]("0x".utf8)
        out.reserveCapacity(2 + bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// "0x…" 형태의 올바른 16진수인지
    public static func isHex(_ s: String) -> Bool {
        s.range(of: "^0[xX]([0-9A-Fa-f]{2})*$", options: .regularExpression) != nil
    }

    /// 바이너리 컬럼 타입인지 (varbinary, binary, blob, bytea, image)
    public static func isBinaryType(_ columnType: String) -> Bool {
        let t = columnType.lowercased()
        return t.contains("binary") || t.contains("blob") || t.hasPrefix("bytea") || t == "image"
    }
}

/// 결과를 직접 고칠 수 있는 대상 테이블 정보
public struct EditTarget: Sendable, Equatable {
    public let table: TableMeta
    /// 기본 키 컬럼 이름
    public let primaryKey: [String]
    /// 결과 컬럼 번호 → 테이블 컬럼 이름 (테이블 컬럼과 이름이 같은 결과 컬럼만)
    public let columnMap: [Int: String]

    /// 결과에서 기본 키 컬럼 번호
    public var primaryKeyIndexes: [Int] {
        primaryKey.compactMap { pk in columnMap.first { $0.value.lowercased() == pk.lowercased() }?.key }
    }
}

/// 결과 편집 대기 중인 변경 (적용 전까지 화면에만 있음)
public struct PendingEdits: Sendable, Equatable {
    /// 기존 행 id → (결과 컬럼 번호 → 새 값, nil 은 NULL)
    public var updates: [Int: [Int: String?]] = [:]
    /// 새 행 (결과 컬럼 번호 → 값). 비어 있는 컬럼은 INSERT 에서 빼서 DB 기본값을 쓴다.
    public var inserts: [[Int: String?]] = []
    /// 삭제할 기존 행 id
    public var deletes: Set<Int> = []

    public init() {}

    public var count: Int {
        updates.values.reduce(0) { $0 + $1.count } + inserts.count + deletes.count
    }

    public var isEmpty: Bool { count == 0 }
}

public enum ResultEditingError: LocalizedError, Equatable {
    case notSingleTable
    case tableNotFound(String)
    case noPrimaryKey(String)
    case primaryKeyNotSelected(String)

    public var errorDescription: String? {
        switch self {
        case .notSingleTable:
            return tr("테이블 하나만 조회한 결과만 고칠 수 있어요. (JOIN, GROUP BY, DISTINCT, UNION, 서브쿼리가 없는 SELECT)")
        case .tableNotFound(let t):
            return tr("테이블 %@ 을(를) 사이드바 스키마에서 찾지 못했어요. 스키마를 새로고침해 보세요.", t)
        case .noPrimaryKey(let t):
            return tr("테이블 %@ 에 기본 키가 없어서 행을 정확히 고를 수 없어요.", t)
        case .primaryKeyNotSelected(let cols):
            return tr("결과에 기본 키 컬럼(%@)이 있어야 고칠 수 있어요. SELECT 에 넣어 주세요.", cols)
        }
    }
}

public enum ResultEditing {

    /// SELECT 문에서 대상 테이블 이름을 찾는다. 테이블 하나짜리 단순 조회가 아니면 nil.
    public static func singleTable(in sql: String) -> String? {
        let cleaned = SQLText.stripComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)
        guard SQLText.firstKeyword(cleaned) == "SELECT" else { return nil }
        let upper = cleaned.uppercased()
        let blocked = "\\bJOIN\\b|\\bUNION\\b|\\bGROUP\\s+BY\\b|\\bDISTINCT\\b|\\bHAVING\\b|\\bINTO\\b|\\(\\s*SELECT\\b|\\bINTERSECT\\b|\\bEXCEPT\\b"
        guard upper.range(of: blocked, options: .regularExpression) == nil else { return nil }
        let pattern = #"\bFROM\s+((?:`[^`]+`|"[^"]+"|\[[^\]]+\]|[A-Za-z0-9_$#@]+)(?:\.(?:`[^`]+`|"[^"]+"|\[[^\]]+\]|[A-Za-z0-9_$#@]+))*)(\s*,)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = cleaned as NSString
        let matches = regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
        guard matches.count == 1, let m = matches.first, m.range(at: 2).location == NSNotFound else { return nil }
        let raw = ns.substring(with: m.range(at: 1))
        let parts = raw.split(separator: ".").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "`\"[]")) }
        return parts.joined(separator: ".")
    }

    /// 편집할 수 있는지 확인하고 대상 정보를 만든다.
    public static func target(sql: String, columns: [String], tables: [TableMeta]) throws -> EditTarget {
        guard let name = singleTable(in: sql) else { throw ResultEditingError.notSingleTable }
        let lower = name.lowercased()
        let last = name.split(separator: ".").last.map { String($0).lowercased() } ?? lower
        guard let table = tables.first(where: { $0.name.lowercased() == lower })
                ?? tables.first(where: { $0.name.lowercased() == last })
                ?? tables.first(where: { $0.name.lowercased() == "dbo." + last }) else {
            throw ResultEditingError.tableNotFound(name)
        }
        guard let pk = table.indexes.first(where: \.isPrimary), !pk.columns.isEmpty else {
            throw ResultEditingError.noPrimaryKey(table.name)
        }
        var map: [Int: String] = [:]
        var used = Set<String>()
        for (i, col) in columns.enumerated() {
            if let c = table.columns.first(where: { $0.name.lowercased() == col.lowercased() }),
               used.insert(c.name.lowercased()).inserted {
                map[i] = c.name
            }
        }
        let target = EditTarget(table: table, primaryKey: pk.columns, columnMap: map)
        guard target.primaryKeyIndexes.count == pk.columns.count else {
            throw ResultEditingError.primaryKeyNotSelected(pk.columns.joined(separator: ", "))
        }
        return target
    }

    /// 대기 중인 변경을 SQL 문들로 만든다. 순서: DELETE → UPDATE → INSERT
    public static func statements(_ edits: PendingEdits, target: EditTarget, rows: [QueryResult.Row],
                                  dialect: any SQLDialect) -> [String] {
        let table = dialect.quoteTable(target.table.name)
        let binaryColumns = Set(target.table.columns.filter { BinaryText.isBinaryType($0.columnType) }.map { $0.name.lowercased() })
        func literal(_ v: String?, column: Int) -> String {
            guard let v else { return "NULL" }
            if let name = target.columnMap[column]?.lowercased(), binaryColumns.contains(name), BinaryText.isHex(v) {
                return dialect.binaryLiteral(hex: String(v.dropFirst(2)))
            }
            return dialect.quoteString(v)
        }
        func whereClause(_ row: QueryResult.Row) -> String {
            target.primaryKeyIndexes.map { i in
                let col = dialect.quoteIdent(target.columnMap[i]!)
                let v = row.values[i]
                return v == nil ? "\(col) IS NULL" : "\(col) = \(literal(v, column: i))"
            }.joined(separator: " AND ")
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for id in edits.deletes.sorted() {
            guard let row = byID[id] else { continue }
            out.append("DELETE FROM \(table) WHERE \(whereClause(row));")
        }
        for id in edits.updates.keys.sorted() where !edits.deletes.contains(id) {
            guard let row = byID[id], let changes = edits.updates[id], !changes.isEmpty else { continue }
            let sets = changes.keys.sorted().compactMap { i -> String? in
                guard let col = target.columnMap[i] else { return nil }
                return "\(dialect.quoteIdent(col)) = \(literal(changes[i]!, column: i))"
            }
            guard !sets.isEmpty else { continue }
            out.append("UPDATE \(table) SET \(sets.joined(separator: ", ")) WHERE \(whereClause(row));")
        }
        for row in edits.inserts {
            let cols = row.keys.sorted().filter { target.columnMap[$0] != nil }
            guard !cols.isEmpty else {
                out.append(dialect.kind == .mysql ? "INSERT INTO \(table) () VALUES ();" : "INSERT INTO \(table) DEFAULT VALUES;")
                continue
            }
            let names = cols.map { dialect.quoteIdent(target.columnMap[$0]!) }.joined(separator: ", ")
            let values = cols.map { literal(row[$0]!, column: $0) }.joined(separator: ", ")
            out.append("INSERT INTO \(table) (\(names)) VALUES (\(values));")
        }
        return out
    }
}

extension SQLDialect {
    /// 16진수 → 바이너리 값 (0x 없이 넘긴다)
    public func binaryLiteral(hex: String) -> String {
        switch kind {
        case .mysql, .redis: return "X'\(hex)'"
        case .postgres: return "decode('\(hex)', 'hex')"
        case .mssql: return hex.isEmpty ? "0x" : "0x\(hex)"
        }
    }

    public var beginSQL: String {
        switch kind {
        case .mysql, .redis: return "START TRANSACTION"
        case .postgres: return "BEGIN"
        case .mssql: return "BEGIN TRANSACTION"
        }
    }

    public var commitSQL: String { kind == .mssql ? "COMMIT TRANSACTION" : "COMMIT" }
    public var rollbackSQL: String { kind == .mssql ? "ROLLBACK TRANSACTION" : "ROLLBACK" }
}

extension DBSession {
    /// 여러 변경 문을 한 트랜잭션으로 실행한다. 하나라도 실패하면 전부 되돌린다.
    /// - Returns: 실패하면 (실패한 문장 번호, 오류)
    public func executeInTransaction(_ statements: [String]) async throws {
        for s in statements where profile.readOnly && !SQLText.isReadOnly(s) {
            _ = s
            throw DBError.readOnlyBlocked
        }
        _ = try await raw(dialect.beginSQL)
        do {
            for s in statements { _ = try await raw(s) }
            _ = try await raw(dialect.commitSQL)
        } catch {
            _ = try? await raw(dialect.rollbackSQL)
            throw error
        }
    }
}
