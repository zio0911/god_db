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
        case .mysql, .redis:
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

    /// 테이블과, 외래 키(+ 추정 관계)로 바로 이어진 테이블 (참조하는 쪽 + 참조되는 쪽)
    public static func related(to name: String, in tables: [TableMeta], extra: [ForeignKeyMeta] = []) -> [TableMeta] {
        guard tables.contains(where: { $0.name == name }) else { return [] }
        let all = tables.flatMap(\.foreignKeys) + extra
        var names: [String] = [name]
        for fk in all where fk.table == name && !names.contains(fk.referencedTable) { names.append(fk.referencedTable) }
        for fk in all where fk.referencedTable == name && !names.contains(fk.table) { names.append(fk.table) }
        return names.compactMap { n in tables.first { $0.name == n } }
    }

    /// 고른 테이블(관계 없어도 모두) + 관계로 이어진 테이블. 고른 순서(스키마 순서)가 먼저.
    public static func withRelated(_ names: Set<String>, in tables: [TableMeta], extra: [ForeignKeyMeta] = []) -> [TableMeta] {
        var ordered = tables.map(\.name).filter { names.contains($0) }
        for name in ordered {
            for t in related(to: name, in: tables, extra: extra) where !ordered.contains(t.name) { ordered.append(t.name) }
        }
        return ordered.compactMap { n in tables.first { $0.name == n } }
    }

    /// 외래 키 제약이 없는 DB 를 위한 관계 추정 (DataGrip 의 가상 외래 키와 비슷)
    /// 규칙: 어떤 테이블의 컬럼 이름이 다른 테이블의 "단일 컬럼 기본 키" 이름과 같으면 그 테이블을 참조한다고 본다.
    ///  - 자기 자신의 기본 키 컬럼은 제외, 이미 진짜 외래 키가 있는 컬럼은 제외
    ///  - 같은 이름의 기본 키를 가진 테이블이 여러 개면, 이름이 컬럼과 가장 비슷한 하나만 (애매하면 건너뜀)
    ///  - 흔한 이름(id, seq, no …)은 너무 많이 이어지므로 제외
    public static func inferredRelations(_ tables: [TableMeta]) -> [ForeignKeyMeta] {
        let generic: Set<String> = ["id", "seq", "no", "idx", "num", "code", "key", "uid", "sn"]
        func pk(_ t: TableMeta) -> String? {
            let pkIndex = t.indexes.first(where: \.isPrimary)?.columns
            let cols = pkIndex ?? t.columns.filter(\.isPrimaryKey).map(\.name)
            return cols.count == 1 ? cols[0] : nil
        }
        var byPK: [String: [TableMeta]] = [:]
        for t in tables { if let k = pk(t)?.lowercased(), !generic.contains(k) { byPK[k, default: []].append(t) } }
        func stem(_ s: String) -> String {
            var x = s.lowercased()
            for p in ["tb_", "tbl_", "t_", "tm_", "th_"] where x.hasPrefix(p) { x.removeFirst(p.count) }
            for suf in ["_id", "_no", "_seq", "_cd", "_code", "id"] where x.hasSuffix(suf) && x.count > suf.count {
                x.removeLast(suf.count); break
            }
            return x
        }
        var out: [ForeignKeyMeta] = []
        for t in tables {
            let own = pk(t)?.lowercased()
            let real = Set(t.foreignKeys.flatMap(\.columns).map { $0.lowercased() })
            for c in t.columns {
                let name = c.name.lowercased()
                guard name != own, !real.contains(name), let candidates = byPK[name] else { continue }
                let others = candidates.filter { $0.name != t.name }
                guard !others.isEmpty else { continue }
                let target: TableMeta?
                if others.count == 1 {
                    target = others[0]
                } else {
                    let s = stem(c.name)
                    let close = others.filter { stem($0.name) == s || stem($0.name).hasSuffix(s) }
                    target = close.count == 1 ? close[0] : nil
                }
                guard let ref = target, let refPK = pk(ref) else { continue }
                out.append(ForeignKeyMeta(name: "~\(t.name).\(c.name)", table: t.name, columns: [c.name],
                                          referencedTable: ref.name, referencedColumns: [refPK]))
            }
        }
        return out
    }

    /// 참조되는 테이블(부모)을 왼쪽, 참조하는 테이블(자식)을 오른쪽 열에 놓는다. 관계 없는 테이블은 격자로 아래에.
    public static func frames(_ tables: [TableMeta], extra: [ForeignKeyMeta] = [], gap: CGFloat = 70,
                              cardWidth width: CGFloat = cardWidth) -> [String: CGRect] {
        let names = Set(tables.map(\.name))
        let all = tables.flatMap(\.foreignKeys) + extra
        let parents: [String: [String]] = Dictionary(uniqueKeysWithValues: tables.map { t in
            (t.name, all.filter { $0.table == t.name }.map(\.referencedTable).filter { names.contains($0) && $0 != t.name })
        })
        let connected = Set(tables.filter { t in
            !(parents[t.name] ?? []).isEmpty || all.contains { $0.referencedTable == t.name && $0.table != t.name && names.contains($0.table) }
        }.map(\.name))
        let cardWidth = width

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
