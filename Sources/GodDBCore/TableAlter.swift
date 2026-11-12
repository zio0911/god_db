import Foundation

/// 테이블 수정 화면에서 편집 중인 컬럼. originalName 이 nil 이면 새 컬럼.
public struct EditableColumn: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var originalName: String?
    public var name: String
    public var columnType: String
    public var nullable: Bool
    /// nil 이면 DEFAULT 없음
    public var defaultValue: String?
    public var extra: String
    public var comment: String

    public init(id: UUID = UUID(), originalName: String? = nil, name: String = "", columnType: String = "varchar(100)",
                nullable: Bool = true, defaultValue: String? = nil, extra: String = "", comment: String = "") {
        self.id = id
        self.originalName = originalName
        self.name = name
        self.columnType = columnType
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.extra = extra
        self.comment = comment
    }

    public init(_ c: ColumnMeta) {
        self.init(originalName: c.name, name: c.name, columnType: c.columnType, nullable: c.nullable,
                  defaultValue: c.defaultValue, extra: c.extra, comment: c.comment)
    }

    var meta: ColumnMeta {
        ColumnMeta(name: name, columnType: columnType, nullable: nullable, defaultValue: defaultValue,
                   extra: extra, comment: comment)
    }
}

public struct EditableIndex: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var originalName: String?
    public var name: String
    public var unique: Bool
    public var columns: [String]

    public init(id: UUID = UUID(), originalName: String? = nil, name: String = "", unique: Bool = false, columns: [String] = []) {
        self.id = id
        self.originalName = originalName
        self.name = name
        self.unique = unique
        self.columns = columns
    }

    public init(_ i: IndexMeta) {
        self.init(originalName: i.name, name: i.name, unique: i.unique, columns: i.columns)
    }

    var meta: IndexMeta { IndexMeta(name: name, unique: unique, columns: columns) }
}

public enum TableAlterError: LocalizedError, Equatable {
    case emptyColumnName
    case emptyColumnType(String)
    case duplicateColumn(String)
    case emptyIndex(String)
    case unknownIndexColumn(index: String, column: String)
    case noColumns

    public var errorDescription: String? {
        switch self {
        case .emptyColumnName: return "이름이 비어 있는 컬럼이 있어요."
        case .emptyColumnType(let c): return "\(c) 컬럼의 타입이 비어 있어요."
        case .duplicateColumn(let c): return "컬럼 이름 \(c) 이(가) 중복돼요."
        case .emptyIndex(let i): return "\(i.isEmpty ? "이름 없는" : i) 인덱스에 이름 또는 컬럼이 없어요."
        case .unknownIndexColumn(let i, let c): return "\(i) 인덱스의 컬럼 \(c) 이(가) 테이블에 없어요."
        case .noColumns: return "컬럼이 최소 1개는 있어야 해요."
        }
    }
}

/// 원래 테이블과 편집 결과를 비교해 하나의 ALTER TABLE 문을 만든다.
public enum TableAlter {

    /// 변경 사항이 없으면 nil.
    public static func statement(original: TableMeta, columns: [EditableColumn], indexes: [EditableIndex],
                                 comment: String, dialect: any SQLDialect = MySQLDialect()) throws -> String? {
        let list = try changes(original: original, columns: columns, indexes: indexes, comment: comment)
        return list.isEmpty ? nil : dialect.render(list, table: original.name)
    }

    /// 원래 테이블과 편집 결과를 비교해 변경 목록을 만든다. (순서: 인덱스 삭제 → 컬럼 삭제 → 컬럼 변경/추가 → 인덱스 추가 → 코멘트)
    public static func changes(original: TableMeta, columns: [EditableColumn], indexes: [EditableIndex],
                               comment: String) throws -> [SchemaChange] {
        try validate(columns: columns, indexes: indexes)
        var out: [SchemaChange] = []
        let originalCols = Dictionary(original.columns.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let originalIdx = Dictionary(original.indexes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        // 1) 인덱스 삭제 (삭제됐거나 바뀐 것) — 컬럼 삭제보다 먼저
        let keptIndexNames = Set(indexes.compactMap(\.originalName))
        var droppedIndexNames = Set<String>()
        for i in original.indexes where !keptIndexNames.contains(i.name) {
            out.append(.dropIndex(i))
            droppedIndexNames.insert(i.name)
        }
        for e in indexes {
            guard let on = e.originalName, let o = originalIdx[on] else { continue }
            if o.name != e.name || o.unique != e.unique || o.columns != e.columns {
                out.append(.dropIndex(o))
                droppedIndexNames.insert(o.name)
            }
        }

        // 2) 컬럼 삭제
        let keptColumnNames = Set(columns.compactMap(\.originalName))
        for c in original.columns where !keptColumnNames.contains(c.name) {
            out.append(.dropColumn(c.name))
        }

        // 3) 컬럼 변경 / 추가 (편집 순서대로, 새 컬럼은 앞 컬럼 뒤에)
        var previous: String? = nil
        for c in columns {
            if let on = c.originalName, let o = originalCols[on] {
                if on != c.name {
                    out.append(.renameColumn(old: o, new: c.meta))
                } else if !SchemaDiff.columnDifferences(c.meta, o).isEmpty {
                    out.append(.modifyColumn(old: o, new: c.meta))
                }
            } else {
                out.append(.addColumn(c.meta, after: previous))
            }
            previous = c.name
        }

        // 4) 인덱스 추가 (새 것 + 바뀐 것)
        for e in indexes {
            let original = e.originalName.flatMap { originalIdx[$0] }
            let changed = e.originalName.map { droppedIndexNames.contains($0) } ?? false
            if original == nil || changed {
                var meta = e.meta
                meta.isPrimary = original?.isPrimary ?? (e.name == "PRIMARY")
                meta.isConstraint = original?.isConstraint ?? meta.isPrimary
                out.append(.addIndex(meta))
            }
        }

        // 5) 테이블 코멘트
        if comment != original.comment {
            out.append(.tableComment(old: original.comment, new: comment))
        }
        return out
    }

    static func validate(columns: [EditableColumn], indexes: [EditableIndex]) throws {
        guard !columns.isEmpty else { throw TableAlterError.noColumns }
        var seen = Set<String>()
        for c in columns {
            let n = c.name.trimmingCharacters(in: .whitespaces)
            if n.isEmpty { throw TableAlterError.emptyColumnName }
            if c.columnType.trimmingCharacters(in: .whitespaces).isEmpty { throw TableAlterError.emptyColumnType(n) }
            if !seen.insert(n.lowercased()).inserted { throw TableAlterError.duplicateColumn(n) }
        }
        for i in indexes {
            if i.name.trimmingCharacters(in: .whitespaces).isEmpty || i.columns.isEmpty {
                throw TableAlterError.emptyIndex(i.name)
            }
            for col in i.columns where !seen.contains(col.lowercased()) {
                throw TableAlterError.unknownIndexColumn(index: i.name, column: col)
            }
        }
    }
}
