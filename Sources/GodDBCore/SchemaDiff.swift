import Foundation

/// 기준(source) 스키마와 대상(target) 스키마의 차이.
public struct SchemaDiffItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case missingTable      // 대상에 테이블 없음
        case extraTable        // 대상에만 있는 테이블 (참고용)
        case missingColumn
        case differentColumn
        case extraColumn       // 대상에만 있는 컬럼 (참고용, 자동 삭제 안 함)
        case missingIndex
        case differentIndex
        case extraIndex        // 대상에만 있는 인덱스 (참고용)
    }

    public var id: String { "\(kind.rawValue):\(table).\(object ?? "")" }
    public let kind: Kind
    public let table: String
    public let object: String?
    public let detail: String
    /// 대상에 적용할 보정 SQL. 참고용 항목은 nil.
    public let fixSQL: String?

    public var severity: Severity {
        switch kind {
        case .missingTable, .missingColumn, .missingIndex: return .missing
        case .differentColumn, .differentIndex: return .different
        case .extraTable, .extraColumn, .extraIndex: return .extra
        }
    }

    public enum Severity: Sendable { case missing, different, extra }
}

public struct SchemaDiffReport: Sendable {
    public let items: [SchemaDiffItem]
    public let matchedTables: Int

    public var missingCount: Int { items.filter { $0.severity == .missing }.count }
    public var differentCount: Int { items.filter { $0.severity == .different }.count }
    public var extraCount: Int { items.filter { $0.severity == .extra }.count }

    /// 실행 가능한 보정 SQL 전체 (DROP TABLE/COLUMN 은 생성하지 않는다)
    public var fixScript: String {
        items.compactMap(\.fixSQL).joined(separator: "\n\n")
    }
}

public enum SchemaDiff {

    /// - Parameters:
    ///   - createStatements: 대상에 없는 테이블의 CREATE 문 (MySQL 은 기준 DB 의 SHOW CREATE TABLE). 없으면 메타데이터로 만든다.
    ///   - dialect: 보정 SQL 을 만들 대상 DB 의 문법
    public static func compare(source: [TableMeta], target: [TableMeta],
                               createStatements: [String: String] = [:],
                               dialect: any SQLDialect = MySQLDialect()) -> SchemaDiffReport {
        let targetByName = Dictionary(target.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let sourceNames = Set(source.map { $0.name.lowercased() })
        var items: [SchemaDiffItem] = []
        var matched = 0

        for s in source {
            guard let t = targetByName[s.name.lowercased()] else {
                var create = createStatements[s.name] ?? dialect.createTableSQL(s)
                if !create.hasSuffix(";") { create += ";" }
                items.append(.init(kind: .missingTable, table: s.name, object: nil, detail: tr("테이블 없음"), fixSQL: create))
                continue
            }
            let tableItems = compareTable(source: s, target: t, dialect: dialect)
            if tableItems.isEmpty { matched += 1 }
            items += tableItems
        }
        for t in target where !sourceNames.contains(t.name.lowercased()) {
            items.append(.init(kind: .extraTable, table: t.name, object: nil, detail: tr("대상에만 있음"), fixSQL: nil))
        }
        return SchemaDiffReport(items: items, matchedTables: matched)
    }

    static func compareTable(source s: TableMeta, target t: TableMeta, dialect: any SQLDialect) -> [SchemaDiffItem] {
        var items: [SchemaDiffItem] = []
        let tCols = Dictionary(t.columns.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let sColNames = Set(s.columns.map { $0.name.lowercased() })
        func sql(_ change: SchemaChange) -> String { dialect.render([change], table: t.name) }

        var previous: String? = nil
        for c in s.columns.sorted(by: { $0.position < $1.position }) {
            if let tc = tCols[c.name.lowercased()] {
                let diffs = columnDifferences(c, tc)
                if !diffs.isEmpty {
                    items.append(.init(kind: .differentColumn, table: s.name, object: c.name,
                                       detail: diffs.joined(separator: ", "),
                                       fixSQL: sql(.modifyColumn(old: tc, new: c))))
                }
            } else {
                items.append(.init(kind: .missingColumn, table: s.name, object: c.name, detail: tr("컬럼 없음"),
                                   fixSQL: sql(.addColumn(c, after: previous))))
            }
            previous = c.name
        }
        for c in t.columns where !sColNames.contains(c.name.lowercased()) {
            items.append(.init(kind: .extraColumn, table: s.name, object: c.name, detail: tr("대상에만 있음"), fixSQL: nil))
        }

        // 기본 키는 DB 마다 이름이 달라서 이름이 아니라 "기본 키" 끼리 비교한다.
        func key(_ i: IndexMeta) -> String { i.isPrimary ? "#primary" : i.name.lowercased() }
        let tIdx = Dictionary(t.indexes.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let sIdxKeys = Set(s.indexes.map(key))
        for i in s.indexes {
            if let ti = tIdx[key(i)] {
                if ti.unique != i.unique || ti.columns.map({ $0.lowercased() }) != i.columns.map({ $0.lowercased() }) {
                    let detail = "(\(ti.columns.joined(separator: ", "))) → (\(i.columns.joined(separator: ", ")))"
                    var fixed = i
                    fixed.name = ti.name
                    fixed.isConstraint = ti.isConstraint
                    items.append(.init(kind: .differentIndex, table: s.name, object: i.name, detail: detail,
                                       fixSQL: dialect.render([.dropIndex(ti), .addIndex(fixed)], table: t.name)))
                }
            } else {
                items.append(.init(kind: .missingIndex, table: s.name, object: i.name, detail: tr("인덱스 없음"),
                                   fixSQL: sql(.addIndex(i))))
            }
        }
        for i in t.indexes where !sIdxKeys.contains(key(i)) {
            items.append(.init(kind: .extraIndex, table: s.name, object: i.name, detail: tr("대상에만 있음"), fixSQL: nil))
        }
        return items
    }

    public static func columnDifferences(_ s: ColumnMeta, _ t: ColumnMeta) -> [String] {
        var d: [String] = []
        if s.columnType.lowercased() != t.columnType.lowercased() { d.append(tr("타입 %@ → %@", "\(t.columnType)", "\(s.columnType)")) }
        if s.nullable != t.nullable { d.append(s.nullable ? "NOT NULL → NULL" : "NULL → NOT NULL") }
        if s.defaultValue != t.defaultValue { d.append(tr("기본값 %@ → %@", "\(t.defaultValue ?? tr("없음"))", "\(s.defaultValue ?? tr("없음"))")) }
        if normalizedExtra(s.extra) != normalizedExtra(t.extra) { d.append("EXTRA \(t.extra) → \(s.extra)") }
        if s.comment != t.comment { d.append(tr("코멘트 변경")) }
        return d
    }

    static func normalizedExtra(_ extra: String) -> String {
        extra.replacingOccurrences(of: "DEFAULT_GENERATED", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// MySQL 컬럼 정의 (기존 호출부 호환용)
    public static func columnDefinition(_ c: ColumnMeta) -> String {
        MySQLDialect().columnDefinition(c)
    }
}
