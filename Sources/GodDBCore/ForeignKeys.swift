import CoreGraphics
import Foundation

/// 외래 키 (여러 컬럼 가능)
public struct ForeignKeyMeta: Hashable, Sendable, Identifiable {
    public var id: String { "\(table).\(name)" }
    public let name: String
    public let table: String
    public var columns: [String]
    public let referencedTable: String
    public var referencedColumns: [String]

    public init(name: String, table: String, columns: [String], referencedTable: String, referencedColumns: [String]) {
        self.name = name
        self.table = table
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
    }
}

extension SQLDialect {
    /// [테이블, 외래키 이름, 컬럼, 참조 테이블, 참조 컬럼, 순서] — 같은 DB/스키마 안의 참조만
    public func foreignKeysSQL(_ schema: String) -> String {
        let s = quoteString(schema)
        switch kind {
        case .mysql:
            return """
            SELECT TABLE_NAME, CONSTRAINT_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME, ORDINAL_POSITION
              FROM information_schema.KEY_COLUMN_USAGE
             WHERE TABLE_SCHEMA = \(s) AND REFERENCED_TABLE_NAME IS NOT NULL AND REFERENCED_TABLE_SCHEMA = \(s)
             ORDER BY 1, 2, 6
            """
        case .postgres:
            return """
            SELECT c.relname, con.conname, a.attname, rc.relname, ra.attname, k.ord
              FROM pg_constraint con
              JOIN pg_class c ON c.oid = con.conrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
              JOIN pg_class rc ON rc.oid = con.confrelid
              JOIN pg_namespace rn ON rn.oid = rc.relnamespace
              JOIN LATERAL unnest(con.conkey, con.confkey) WITH ORDINALITY AS k(col, refcol, ord) ON true
              JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.col
              JOIN pg_attribute ra ON ra.attrelid = con.confrelid AND ra.attnum = k.refcol
             WHERE con.contype = 'f' AND n.nspname = \(s) AND rn.nspname = \(s)
             ORDER BY 1, 2, 6
            """
        case .mssql:
            return """
            SELECT CASE WHEN s.name = 'dbo' THEN t.name ELSE s.name + '.' + t.name END, fk.name, c.name,
                   CASE WHEN rs.name = 'dbo' THEN rt.name ELSE rs.name + '.' + rt.name END, rc.name, fkc.constraint_column_id
              FROM sys.foreign_keys fk
              JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
              JOIN sys.tables t ON t.object_id = fk.parent_object_id
              JOIN sys.schemas s ON s.schema_id = t.schema_id
              JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
              JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
              JOIN sys.schemas rs ON rs.schema_id = rt.schema_id
              JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
             ORDER BY 1, 2, 6
            """
        }
    }
}

extension SchemaBuilder {
    public static func attachForeignKeys(_ tables: [TableMeta], rows: [[String?]]) -> [TableMeta] {
        var byName = Dictionary(tables.enumerated().map { ($0.element.name, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var out = tables
        for r in rows {
            guard r.count >= 5, let t = r[0], let name = r[1], let col = r[2], let refT = r[3], let refC = r[4],
                  let i = byName[t] else { continue }
            if let k = out[i].foreignKeys.firstIndex(where: { $0.name == name }) {
                out[i].foreignKeys[k].columns.append(col)
                out[i].foreignKeys[k].referencedColumns.append(refC)
            } else {
                out[i].foreignKeys.append(ForeignKeyMeta(name: name, table: t, columns: [col],
                                                         referencedTable: refT, referencedColumns: [refC]))
            }
        }
        byName.removeAll()
        return out
    }
}

/// ER 다이어그램 배치
public enum DiagramLayout {
    public static let cardWidth: CGFloat = 250
    public static let headerHeight: CGFloat = 34
    public static let rowHeight: CGFloat = 20
    public static let maxRows = 24

    public static func cardHeight(_ t: TableMeta) -> CGFloat {
        headerHeight + CGFloat(min(t.columns.count, maxRows) + (t.columns.count > maxRows ? 1 : 0)) * rowHeight + 10
    }

    /// 테이블과, 외래 키로 바로 이어진 테이블 (참조하는 쪽 + 참조되는 쪽)
    public static func related(to name: String, in tables: [TableMeta]) -> [TableMeta] {
        guard let center = tables.first(where: { $0.name == name }) else { return [] }
        var names: [String] = [center.name]
        for fk in center.foreignKeys where !names.contains(fk.referencedTable) { names.append(fk.referencedTable) }
        for t in tables where t.foreignKeys.contains(where: { $0.referencedTable == name }) && !names.contains(t.name) {
            names.append(t.name)
        }
        return names.compactMap { n in tables.first { $0.name == n } }
    }

    /// 참조되는 테이블(부모)을 왼쪽, 참조하는 테이블(자식)을 오른쪽 열에 놓는다. 관계 없는 테이블은 격자로 아래에.
    public static func frames(_ tables: [TableMeta], gap: CGFloat = 70) -> [String: CGRect] {
        let names = Set(tables.map(\.name))
        let parents: [String: [String]] = Dictionary(uniqueKeysWithValues: tables.map { t in
            (t.name, t.foreignKeys.map(\.referencedTable).filter { names.contains($0) && $0 != t.name })
        })
        let connected = Set(tables.filter { t in
            !(parents[t.name] ?? []).isEmpty || tables.contains { $0.foreignKeys.contains { $0.referencedTable == t.name && $0.table != t.name } }
        }.map(\.name))

        // 단계 = 1 + 부모 단계의 최대값 (순환은 횟수 제한으로 끊음)
        var level: [String: Int] = [:]
        for t in tables where connected.contains(t.name) { level[t.name] = 0 }
        for _ in 0..<tables.count {
            var changed = false
            for t in tables where connected.contains(t.name) {
                let l = (parents[t.name] ?? []).compactMap { level[$0] }.max().map { $0 + 1 } ?? 0
                if l > (level[t.name] ?? 0) && l < tables.count { level[t.name] = l; changed = true }
            }
            if !changed { break }
        }

        var result: [String: CGRect] = [:]
        var bottomOfGraph: CGFloat = 0
        let maxLevel = level.values.max() ?? -1
        if maxLevel >= 0 {
            for l in 0...maxLevel {
                var y: CGFloat = 0
                for t in tables where level[t.name] == l {
                    let h = cardHeight(t)
                    result[t.name] = CGRect(x: CGFloat(l) * (cardWidth + gap * 1.6), y: y, width: cardWidth, height: h)
                    y += h + gap
                }
                bottomOfGraph = max(bottomOfGraph, y)
            }
        }
        // 관계 없는 테이블: 격자
        let loose = tables.filter { !connected.contains($0.name) }
        if !loose.isEmpty {
            let columns = max(1, Int(Double(loose.count).squareRoot().rounded(.up)))
            var rowTop = bottomOfGraph
            var index = 0
            while index < loose.count {
                let row = loose[index..<min(index + columns, loose.count)]
                var rowHeight: CGFloat = 0
                for (c, t) in row.enumerated() {
                    let h = cardHeight(t)
                    result[t.name] = CGRect(x: CGFloat(c) * (cardWidth + gap), y: rowTop, width: cardWidth, height: h)
                    rowHeight = max(rowHeight, h)
                }
                rowTop += rowHeight + gap
                index += columns
            }
        }
        return result
    }
}
