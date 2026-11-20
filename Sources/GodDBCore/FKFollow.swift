import Foundation

/// 결과 안의 외래 키 관계 하나 (진짜 외래 키 또는 이름으로 추정한 관계)
public struct FKRelation: Hashable, Sendable, Identifiable {
    public var id: String { "\(table)(\(columns.joined(separator: ",")))→\(referencedTable)(\(referencedColumns.joined(separator: ",")))" }
    /// 참조하는 테이블 (자식)
    public let table: String
    public let columns: [String]
    /// 참조되는 테이블 (부모)
    public let referencedTable: String
    public let referencedColumns: [String]
    /// 컬럼 이름으로 추정한 관계 (외래 키 제약 없음)
    public let inferred: Bool

    public init(table: String, columns: [String], referencedTable: String, referencedColumns: [String], inferred: Bool) {
        self.table = table
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.inferred = inferred
    }

    public init(_ fk: ForeignKeyMeta, inferred: Bool) {
        self.init(table: fk.table, columns: fk.columns, referencedTable: fk.referencedTable,
                  referencedColumns: fk.referencedColumns, inferred: inferred)
    }

    /// 이 관계에 그 컬럼이 들어 있는지 (대소문자 무시)
    public func contains(column: String) -> Bool {
        columns.contains { $0.lowercased() == column.lowercased() }
    }
}

/// 외래 키 따라가기: 결과 행에서 참조하는 행 / 이 행을 참조하는 행을 새 탭으로 조회한다.
/// (명세 docs/specs/1.4.0.md · F3)
public enum FKFollow {
    // MARK: - 결과의 원본 테이블

    /// 결과가 테이블 하나에서 온 조회면 그 테이블 (결과 편집 `EditTarget` 과 같은 판단: JOIN · 집계 · UNION · 서브쿼리 제외)
    public static func sourceTable(sql: String, tables: [TableMeta]) -> TableMeta? {
        guard let name = ResultEditing.singleTable(in: sql) else { return nil }
        return ResultEditing.table(named: name, in: tables)
    }

    /// 단일 컬럼 기본 키 이름 (복합 키 · 키 없음은 nil)
    public static func singlePrimaryKey(_ table: TableMeta) -> String? {
        let cols = table.indexes.first(where: \.isPrimary)?.columns ?? table.columns.filter(\.isPrimaryKey).map(\.name)
        return cols.count == 1 ? cols[0] : nil
    }

    // MARK: - 관계 찾기

    /// 스키마 전체의 추정 관계 (ER 다이어그램과 같은 규칙). 스키마를 읽을 때 한 번 계산해 둔다.
    public static func inferredRelations(_ tables: [TableMeta]) -> [ForeignKeyMeta] {
        DiagramLayout.inferredRelations(tables)
    }

    /// 이 테이블이 참조하는 관계 (진짜 외래 키 먼저, 그다음 추정)
    public static func outgoing(from table: TableMeta, inferred: [ForeignKeyMeta]) -> [FKRelation] {
        table.foreignKeys.map { FKRelation($0, inferred: false) }
            + inferred.filter { $0.table == table.name }.map { FKRelation($0, inferred: true) }
    }

    /// 이 컬럼이 들어 있는 관계 (보통 하나)
    public static func relations(forColumn column: String, in relations: [FKRelation]) -> [FKRelation] {
        relations.filter { $0.contains(column: column) }
    }

    /// 이 테이블의 기본 키(단일 컬럼)를 참조하는 테이블들. 기본 키가 복합이거나 없으면 빈 목록.
    public static func incoming(to table: TableMeta, tables: [TableMeta], inferred: [ForeignKeyMeta]) -> [FKRelation] {
        guard let pk = singlePrimaryKey(table)?.lowercased() else { return [] }
        let real = tables.flatMap(\.foreignKeys).map { FKRelation($0, inferred: false) }
        let guessed = inferred.map { FKRelation($0, inferred: true) }
        var seen = Set<String>()
        return (real + guessed)
            .filter { $0.referencedTable == table.name && $0.columns.count == 1 && $0.referencedColumns.first?.lowercased() == pk }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.table.lowercased(), $0.columns[0].lowercased()) < ($1.table.lowercased(), $1.columns[0].lowercased()) }
    }

    // MARK: - 값

    /// 결과 행에서 관계의 컬럼 값들 (관계의 컬럼 순서). 결과에 없는 컬럼은 nil.
    public static func values(for relation: FKRelation, resultColumns: [String], row: [String?]) -> [String?] {
        relation.columns.map { col in
            guard let i = resultColumns.firstIndex(where: { $0.lowercased() == col.lowercased() }), row.indices.contains(i) else {
                return nil
            }
            return row[i]
        }
    }

    /// 결과 행에서 한 컬럼 값 (결과에 없거나 NULL 이면 nil)
    public static func value(of column: String, resultColumns: [String], row: [String?]) -> String? {
        guard let i = resultColumns.firstIndex(where: { $0.lowercased() == column.lowercased() }), row.indices.contains(i) else {
            return nil
        }
        return row[i]
    }

    // MARK: - SQL

    /// 따라가기: `SELECT * FROM <참조 테이블> WHERE <참조 컬럼> = <값>` (복합 키는 AND). 값이 하나라도 NULL 이면 nil (비활성).
    /// 값 인용은 컬럼 타입 기준 (ID 로 찾기와 같음): 참조되는 컬럼 타입, 모르면 참조하는 컬럼 타입.
    public static func followSQL(_ relation: FKRelation, values: [String?], tables: [TableMeta], dialect: any SQLDialect) -> String? {
        guard !relation.columns.isEmpty, values.count == relation.columns.count,
              relation.referencedColumns.count == relation.columns.count else { return nil }
        let present = values.compactMap { $0 }
        guard present.count == values.count else { return nil }
        let parent = ResultEditing.table(named: relation.referencedTable, in: tables)
        let child = ResultEditing.table(named: relation.table, in: tables)
        let conditions = zip(relation.referencedColumns, zip(relation.columns, present)).map { refCol, pair in
            let numeric = isNumeric(refCol, in: parent) ?? isNumeric(pair.0, in: child) ?? false
            return "\(dialect.quoteIdent(refCol)) = \(IDSearch.literal(pair.1, numeric: numeric, dialect: dialect))"
        }
        return "SELECT * FROM \(dialect.quoteTable(relation.referencedTable)) WHERE \(conditions.joined(separator: " AND "))"
    }

    /// 참조하는 행: `SELECT * FROM <참조하는 테이블> WHERE <그 테이블의 FK 컬럼> = <이 행 기본 키 값>`. 값이 NULL 이면 nil.
    public static func referencingSQL(_ relation: FKRelation, primaryKeyValue: String?, tables: [TableMeta],
                                      dialect: any SQLDialect) -> String? {
        guard let value = primaryKeyValue, relation.columns.count == 1, let col = relation.columns.first else { return nil }
        let child = ResultEditing.table(named: relation.table, in: tables)
        let parent = ResultEditing.table(named: relation.referencedTable, in: tables)
        let numeric = isNumeric(col, in: child) ?? relation.referencedColumns.first.flatMap { isNumeric($0, in: parent) } ?? false
        return "SELECT * FROM \(dialect.quoteTable(relation.table)) WHERE \(dialect.quoteIdent(col)) = "
            + IDSearch.literal(value, numeric: numeric, dialect: dialect)
    }

    /// 컬럼이 숫자 타입인지 (테이블 · 컬럼을 모르면 nil)
    static func isNumeric(_ column: String, in table: TableMeta?) -> Bool? {
        guard let c = table?.columns.first(where: { $0.name.lowercased() == column.lowercased() }) else { return nil }
        return IDSearch.isNumericType(c.columnType)
    }

    // MARK: - 탭 제목

    /// 따라가기 탭: `↗ <테이블>`
    public static func followTitle(_ relation: FKRelation) -> String { "↗ \(relation.referencedTable)" }
    /// 참조하는 행 탭: `↙ <테이블>`
    public static func referencingTitle(_ relation: FKRelation) -> String { "↙ \(relation.table)" }
}
