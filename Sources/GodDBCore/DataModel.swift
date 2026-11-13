import CoreGraphics
import Foundation

/// 데이터 모델 (MySQL Workbench 의 모델처럼): 논리명으로 설계하고, 물리명을 붙여 DDL 로 뽑는다.
public struct DataModel: Codable, Identifiable, Hashable, Sendable {
    public static let fileExtension = "goddbmodel"
    public static let formatName = "goddb-model"

    public var format = DataModel.formatName
    public var version = 1
    public var id: UUID
    public var name: String
    /// DDL 을 뽑을 대상 DB
    public var kind: DatabaseKind
    public var tables: [ModelTable]
    public var relations: [ModelRelation]
    public var memo: String
    public var created: Date
    public var updated: Date

    public init(id: UUID = UUID(), name: String = tr("새 모델"), kind: DatabaseKind = .mysql,
                tables: [ModelTable] = [], relations: [ModelRelation] = [], memo: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.tables = tables
        self.relations = relations
        self.memo = memo
        self.created = Date()
        self.updated = Date()
    }

    public func table(_ id: UUID) -> ModelTable? { tables.first { $0.id == id } }
    public func tableIndex(_ id: UUID) -> Int? { tables.firstIndex { $0.id == id } }
}

public struct ModelTable: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var logicalName: String
    public var physicalName: String
    /// 설명 (논리명 외 추가 설명)
    public var comment: String
    public var columns: [ModelColumn]
    public var indexes: [ModelIndex]
    /// 다이어그램 위치 (왼쪽 위)
    public var x: Double
    public var y: Double
    /// 카드 머리 색 (nil 이면 기본)
    public var color: String?

    public init(id: UUID = UUID(), logicalName: String = "", physicalName: String = "", comment: String = "",
                columns: [ModelColumn] = [], indexes: [ModelIndex] = [], x: Double = 40, y: Double = 40, color: String? = nil) {
        self.id = id
        self.logicalName = logicalName
        self.physicalName = physicalName
        self.comment = comment
        self.columns = columns
        self.indexes = indexes
        self.x = x
        self.y = y
        self.color = color
    }

    public var primaryKey: [ModelColumn] { columns.filter(\.primaryKey) }
    /// 화면 제목: 논리명 → 물리명 → (이름 없음)
    public var displayName: String {
        !logicalName.isEmpty ? logicalName : (!physicalName.isEmpty ? physicalName : tr("(이름 없음)"))
    }
}

public struct ModelColumn: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var logicalName: String
    public var physicalName: String
    public var dataType: String
    public var primaryKey: Bool
    public var notNull: Bool
    public var autoIncrement: Bool
    public var unique: Bool
    /// SQL 식 그대로 (문자열이면 'A' 처럼 따옴표 포함). 비우면 DEFAULT 없음
    public var defaultValue: String
    public var comment: String

    public init(id: UUID = UUID(), logicalName: String = "", physicalName: String = "", dataType: String = "varchar(100)",
                primaryKey: Bool = false, notNull: Bool = false, autoIncrement: Bool = false, unique: Bool = false,
                defaultValue: String = "", comment: String = "") {
        self.id = id
        self.logicalName = logicalName
        self.physicalName = physicalName
        self.dataType = dataType
        self.primaryKey = primaryKey
        self.notNull = notNull
        self.autoIncrement = autoIncrement
        self.unique = unique
        self.defaultValue = defaultValue
        self.comment = comment
    }

    public var displayName: String {
        !logicalName.isEmpty ? logicalName : (!physicalName.isEmpty ? physicalName : tr("(이름 없음)"))
    }
}

public struct ModelIndex: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var unique: Bool
    public var columns: [UUID]

    public init(id: UUID = UUID(), name: String = "", unique: Bool = false, columns: [UUID] = []) {
        self.id = id
        self.name = name
        self.unique = unique
        self.columns = columns
    }
}

/// 관계: 부모(참조되는 쪽) 1 — 자식(참조하는 쪽) N (또는 1)
public struct ModelRelation: Codable, Identifiable, Hashable, Sendable {
    public enum Cardinality: String, Codable, CaseIterable, Sendable {
        case oneToMany = "1:N"
        case oneToOne = "1:1"
        public var title: String { rawValue }
    }

    public enum Action: String, Codable, CaseIterable, Sendable {
        case noAction = "NO ACTION", restrict = "RESTRICT", cascade = "CASCADE", setNull = "SET NULL"
    }

    public struct Pair: Codable, Hashable, Sendable {
        /// 자식 테이블의 FK 컬럼
        public var child: UUID
        /// 부모 테이블의 키 컬럼
        public var parent: UUID
        public init(child: UUID, parent: UUID) { self.child = child; self.parent = parent }
    }

    public var id: UUID
    /// FK 제약 이름 (비우면 fk_자식_부모)
    public var name: String
    public var parent: UUID
    public var child: UUID
    public var cardinality: Cardinality
    /// 식별 관계 (자식 PK 에 FK 가 포함) — 실선, 비식별은 점선
    public var identifying: Bool
    /// 자식 쪽이 없어도 되는지 (FK 컬럼 NULL 허용)
    public var optional: Bool
    public var pairs: [Pair]
    public var onDelete: Action
    public var onUpdate: Action
    /// false 면 DDL 에 FK 제약을 만들지 않고 그림에만 (논리 관계)
    public var createConstraint: Bool

    public init(id: UUID = UUID(), name: String = "", parent: UUID, child: UUID, cardinality: Cardinality = .oneToMany,
                identifying: Bool = false, optional: Bool = false, pairs: [Pair] = [],
                onDelete: Action = .noAction, onUpdate: Action = .noAction, createConstraint: Bool = true) {
        self.id = id
        self.name = name
        self.parent = parent
        self.child = child
        self.cardinality = cardinality
        self.identifying = identifying
        self.optional = optional
        self.pairs = pairs
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        self.createConstraint = createConstraint
    }

    enum CodingKeys: String, CodingKey {
        case id, name, parent, child, cardinality, identifying, optional, pairs, onDelete, onUpdate, createConstraint
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        parent = try c.decode(UUID.self, forKey: .parent)
        child = try c.decode(UUID.self, forKey: .child)
        cardinality = try c.decodeIfPresent(Cardinality.self, forKey: .cardinality) ?? .oneToMany
        identifying = try c.decodeIfPresent(Bool.self, forKey: .identifying) ?? false
        optional = try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        pairs = try c.decodeIfPresent([Pair].self, forKey: .pairs) ?? []
        onDelete = try c.decodeIfPresent(Action.self, forKey: .onDelete) ?? .noAction
        onUpdate = try c.decodeIfPresent(Action.self, forKey: .onUpdate) ?? .noAction
        createConstraint = try c.decodeIfPresent(Bool.self, forKey: .createConstraint) ?? true
    }
}

// MARK: - 편집 동작

extension DataModel {
    /// 빈 자리에 새 테이블 (기본 키 컬럼 하나 포함)
    @discardableResult
    public mutating func addTable(logicalName: String = "", at point: CGPoint? = nil) -> UUID {
        let n = tables.count + 1
        let pos = point ?? CGPoint(x: 40 + Double((n - 1) % 4) * 300, y: 40 + Double((n - 1) / 4) * 260)
                var t = ModelTable(logicalName: logicalName.isEmpty ? tr("테이블%@", "\(n)") : logicalName, x: pos.x, y: pos.y)
        t.columns = [ModelColumn(logicalName: tr("ID"), physicalName: "", dataType: "bigint", primaryKey: true, notNull: true,
                                 autoIncrement: true)]
        tables.append(t)
        touch()
        return t.id
    }

    public mutating func removeTable(_ id: UUID) {
        // 이 테이블을 부모로 하는 관계가 자식에 만든 FK 컬럼도 함께 지운다
        for r in relations where r.parent == id { removeRelation(r.id, dropColumns: true) }
        relations.removeAll { $0.child == id || $0.parent == id }
        tables.removeAll { $0.id == id }
        touch()
    }

    /// 관계 추가: 부모 기본 키를 자식에 FK 컬럼으로 복사 (이미 같은 물리명/논리명 컬럼이 있으면 그 컬럼을 쓴다)
    @discardableResult
    public mutating func addRelation(parent: UUID, child: UUID, cardinality: ModelRelation.Cardinality = .oneToMany,
                                     identifying: Bool = false) -> UUID? {
        guard let p = table(parent), let ci = tableIndex(child) else { return nil }
        let keys = p.primaryKey.isEmpty ? Array(p.columns.prefix(1)) : p.primaryKey
        guard !keys.isEmpty else { return nil }
        var pairs: [ModelRelation.Pair] = []
        for k in keys {
            let fkPhysical = Self.fkColumnName(parent: p, key: k)
            let fkLogical = k.logicalName.isEmpty ? "" : (p.primaryKey.count == 1 && Self.isGenericKey(k)
                                                          ? "\(p.logicalName) \(k.logicalName)" : k.logicalName)
            if let existing = tables[ci].columns.first(where: {
                (!fkPhysical.isEmpty && $0.physicalName.lowercased() == fkPhysical.lowercased())
                    || (!fkLogical.isEmpty && $0.logicalName == fkLogical)
            }) {
                if identifying, let j = tables[ci].columns.firstIndex(where: { $0.id == existing.id }) {
                    tables[ci].columns[j].primaryKey = true
                    tables[ci].columns[j].notNull = true
                }
                pairs.append(.init(child: existing.id, parent: k.id))
                continue
            }
            let col = ModelColumn(logicalName: fkLogical, physicalName: fkPhysical, dataType: Self.fkType(k.dataType),
                                  primaryKey: identifying, notNull: true, autoIncrement: false, unique: cardinality == .oneToOne,
                                  comment: "")
            // 기본 키 컬럼들 뒤에 넣는다
            let insertAt = identifying ? (tables[ci].columns.lastIndex(where: \.primaryKey).map { $0 + 1 } ?? 0)
                                       : tables[ci].columns.count
            tables[ci].columns.insert(col, at: insertAt)
            pairs.append(.init(child: col.id, parent: k.id))
        }
        let r = ModelRelation(parent: parent, child: child, cardinality: cardinality, identifying: identifying, pairs: pairs)
        relations.append(r)
        touch()
        return r.id
    }

    public mutating func removeRelation(_ id: UUID, dropColumns: Bool) {
        guard let r = relations.first(where: { $0.id == id }) else { return }
        relations.removeAll { $0.id == id }
        if dropColumns, let ci = tableIndex(r.child) {
            // 다른 관계가 쓰지 않는 FK 컬럼만
            let used = Set(relations.filter { $0.child == r.child }.flatMap { $0.pairs.map(\.child) })
            let drop = Set(r.pairs.map(\.child)).subtracting(used)
            tables[ci].columns.removeAll { drop.contains($0.id) }
            for k in tables[ci].indexes.indices { tables[ci].indexes[k].columns.removeAll { drop.contains($0) } }
            tables[ci].indexes.removeAll { $0.columns.isEmpty }
        }
        touch()
    }

    /// 식별/비식별, 1:1/1:N 이 바뀌면 FK 컬럼 속성도 맞춘다
    public mutating func updateRelation(_ r: ModelRelation) {
        guard let i = relations.firstIndex(where: { $0.id == r.id }) else { return }
        relations[i] = r
        if let ci = tableIndex(r.child) {
            for p in r.pairs {
                guard let j = tables[ci].columns.firstIndex(where: { $0.id == p.child }) else { continue }
                tables[ci].columns[j].primaryKey = r.identifying
                tables[ci].columns[j].notNull = r.identifying || !r.optional
                if r.pairs.count == 1 { tables[ci].columns[j].unique = r.cardinality == .oneToOne && !r.identifying }
            }
        }
        touch()
    }

    public mutating func touch() { updated = Date() }

    static func isGenericKey(_ c: ModelColumn) -> Bool {
        ["id", "seq", "no", "sn", "idx"].contains(c.physicalName.lowercased())
            || ["ID", "id", "번호", "일련번호", "순번"].contains(c.logicalName)
    }

    /// 부모 키 → 자식 FK 컬럼 물리명: id 처럼 흔한 이름이면 부모테이블_id
    static func fkColumnName(parent: ModelTable, key: ModelColumn) -> String {
        guard !key.physicalName.isEmpty else { return "" }
        if isGenericKey(key), !parent.physicalName.isEmpty {
            var base = parent.physicalName.lowercased()
            for p in ["tb_", "tbl_", "t_"] where base.hasPrefix(p) { base.removeFirst(p.count) }
            return "\(base)_\(key.physicalName)"
        }
        return key.physicalName
    }

    /// 자동 증가 타입은 FK 쪽에선 일반 타입으로 (serial → integer 등)
    static func fkType(_ t: String) -> String {
        switch t.lowercased() {
        case "serial": return "integer"
        case "bigserial": return "bigint"
        case "smallserial": return "smallint"
        default: return t
        }
    }
}

// MARK: - 검사

public struct ModelIssue: Hashable, Sendable, Identifiable {
    public enum Level: Sendable { case error, warning }
    public var id: String { "\(level)-\(message)" }
    public let level: Level
    public let message: String
    public let table: UUID?
}

extension DataModel {
    /// DDL 을 만들기 전 검사: 오류(물리명 없음·중복)는 DDL 을 막고, 경고는 알려만 준다.
    public func issues() -> [ModelIssue] {
        var out: [ModelIssue] = []
        var tableNames = Set<String>()
        let ident = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_$]*$")
        func valid(_ s: String) -> Bool {
            ident.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        for t in tables {
            let name = t.physicalName.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                out.append(.init(level: .error, message: tr("%@ 테이블에 물리명이 없어요.", t.displayName), table: t.id))
            } else {
                if !tableNames.insert(name.lowercased()).inserted {
                    out.append(.init(level: .error, message: tr("테이블 물리명 %@ 이(가) 중복돼요.", name), table: t.id))
                }
                if !valid(name) {
                    out.append(.init(level: .warning, message: tr("%@ 테이블 물리명에 영문·숫자·_ 외 글자가 있어요.", name), table: t.id))
                }
            }
            if t.columns.isEmpty {
                out.append(.init(level: .error, message: tr("%@ 테이블에 컬럼이 없어요.", t.displayName), table: t.id))
            }
            if t.primaryKey.isEmpty, !t.columns.isEmpty {
                out.append(.init(level: .warning, message: tr("%@ 테이블에 기본 키가 없어요.", t.displayName), table: t.id))
            }
            var colNames = Set<String>()
            for c in t.columns {
                let cn = c.physicalName.trimmingCharacters(in: .whitespaces)
                if cn.isEmpty {
                    out.append(.init(level: .error, message: tr("%@.%@ 컬럼에 물리명이 없어요.", t.displayName, c.displayName), table: t.id))
                    continue
                }
                if !colNames.insert(cn.lowercased()).inserted {
                    out.append(.init(level: .error, message: tr("%@ 테이블의 컬럼 %@ 이(가) 중복돼요.", t.displayName, cn), table: t.id))
                }
                if !valid(cn) {
                    out.append(.init(level: .warning, message: tr("%@.%@ 물리명에 영문·숫자·_ 외 글자가 있어요.", t.displayName, cn), table: t.id))
                }
                if c.dataType.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(.init(level: .error, message: tr("%@.%@ 컬럼의 타입이 비어 있어요.", t.displayName, cn), table: t.id))
                }
            }
        }
        return out
    }
}

// MARK: - 물리 변환 / DDL

extension DataModel {
    /// DB 코멘트: 논리명(물리명과 다를 때) + 줄바꿈 + 설명. 리버스 때 첫 줄이 논리명이 된다.
    public static func commentText(logical: String, physical: String, comment: String) -> String {
        var parts: [String] = []
        let l = logical.trimmingCharacters(in: .whitespaces)
        if !l.isEmpty, l != physical { parts.append(l) }
        let c = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { parts.append(c) }
        return parts.joined(separator: "\n")
    }

    /// DB 코멘트 → (논리명, 설명)
    public static func splitComment(_ comment: String) -> (logical: String, comment: String) {
        let lines = comment.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let rest = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (first, rest)
    }

    /// 자동 증가를 DB 별 Extra 로
    static func extra(_ c: ModelColumn, kind: DatabaseKind) -> String {
        guard c.autoIncrement else { return "" }
        switch kind {
        case .mysql, .redis: return "auto_increment"
        case .postgres: return "identity"
        case .mssql: return "identity"
        }
    }

    /// 모델 테이블 → TableMeta (DDL 렌더링용)
    public func tableMeta(_ t: ModelTable) -> TableMeta {
        let cols = t.columns.enumerated().map { i, c in
            ColumnMeta(name: c.physicalName, columnType: c.dataType, nullable: !(c.notNull || c.primaryKey),
                       defaultValue: c.defaultValue.isEmpty ? nil : c.defaultValue,
                       extra: Self.extra(c, kind: kind), columnKey: c.primaryKey ? "PRI" : "",
                       comment: Self.commentText(logical: c.logicalName, physical: c.physicalName, comment: c.comment),
                       position: i + 1)
        }
        var indexes: [IndexMeta] = []
        let pk = t.primaryKey.map(\.physicalName)
        if !pk.isEmpty {
            let pkName = kind == .mysql ? "PRIMARY" : "pk_\(t.physicalName)"
            indexes.append(IndexMeta(name: pkName, unique: true, columns: pk, primary: true))
        }
        let byID = Dictionary(t.columns.map { ($0.id, $0.physicalName) }, uniquingKeysWith: { a, _ in a })
        // 단일 컬럼 UNIQUE (PK 가 아닌 것)
        for c in t.columns where c.unique && !c.primaryKey {
            indexes.append(IndexMeta(name: "uk_\(t.physicalName)_\(c.physicalName)", unique: true, columns: [c.physicalName]))
        }
        for i in t.indexes {
            let cols = i.columns.compactMap { byID[$0] }
            guard !cols.isEmpty else { continue }
            indexes.append(IndexMeta(name: i.name.isEmpty ? "idx_\(t.physicalName)_\(cols.joined(separator: "_"))" : i.name,
                                     unique: i.unique, columns: cols))
        }
        return TableMeta(name: t.physicalName,
                         comment: Self.commentText(logical: t.logicalName, physical: t.physicalName, comment: t.comment),
                         columns: cols, indexes: indexes)
    }

    /// 물리 모델 전체 (FK 포함) — DB 와 비교할 때
    public func physicalTables() -> [TableMeta] {
        tables.map { t in
            var m = tableMeta(t)
            m.foreignKeys = relations.filter { $0.child == t.id && $0.createConstraint }.compactMap(foreignKey)
            return m
        }
    }

    func foreignKey(_ r: ModelRelation) -> ForeignKeyMeta? {
        guard let c = table(r.child), let p = table(r.parent) else { return nil }
        let childCols = r.pairs.compactMap { pr in c.columns.first { $0.id == pr.child }?.physicalName }
        let parentCols = r.pairs.compactMap { pr in p.columns.first { $0.id == pr.parent }?.physicalName }
        guard !childCols.isEmpty, childCols.count == parentCols.count else { return nil }
        return ForeignKeyMeta(name: r.name.isEmpty ? "fk_\(c.physicalName)_\(p.physicalName)" : r.name,
                              table: c.physicalName, columns: childCols,
                              referencedTable: p.physicalName, referencedColumns: parentCols)
    }

    /// Forward Engineering: CREATE TABLE 전부 + FK 는 마지막에 ALTER TABLE 로 (순서·순환 참조 걱정 없음)
    public func ddl(kind target: DatabaseKind? = nil, dropFirst: Bool = false) throws -> String {
        let errors = issues().filter { $0.level == .error }
        if let e = errors.first { throw ModelError.invalid(e.message, count: errors.count) }
        var model = self
        if let target { model.kind = target }
        let dialect = Dialects.of(model.kind)
        var out: [String] = []
        out.append("-- " + tr("GodDB 모델: %@", model.name))
        out.append("-- " + tr("대상: %@ · 테이블 %@개 · 관계 %@개", model.kind.title, "\(model.tables.count)", "\(model.relations.count)"))
        out.append("")
        let fks = model.relations.filter(\.createConstraint).compactMap(model.foreignKey)
        if dropFirst {
            for fk in fks.reversed() { out.append(dropFKSQL(fk, dialect: dialect)) }
            for t in model.tables.reversed() { out.append(dialect.dropTableSQL(t.physicalName)) }
            out.append("")
        }
        for t in model.tables {
            out.append(dialect.createTableSQL(model.tableMeta(t)))
            out.append("")
        }
        let actions = Dictionary(model.relations.compactMap { r in model.foreignKey(r).map { ($0.id, r) } },
                                 uniquingKeysWith: { a, _ in a })
        for fk in fks {
            var s = "ALTER TABLE \(dialect.quoteTable(fk.table)) ADD CONSTRAINT \(dialect.quoteIdent(fk.name)) FOREIGN KEY ("
                + fk.columns.map(dialect.quoteIdent).joined(separator: ", ") + ") REFERENCES \(dialect.quoteTable(fk.referencedTable)) ("
                + fk.referencedColumns.map(dialect.quoteIdent).joined(separator: ", ") + ")"
            if let r = actions[fk.id] {
                // SQL Server 는 RESTRICT 가 없다 (NO ACTION 과 같음)
                if r.onDelete != .noAction, !(model.kind == .mssql && r.onDelete == .restrict) { s += " ON DELETE \(r.onDelete.rawValue)" }
                if r.onUpdate != .noAction, !(model.kind == .mssql && r.onUpdate == .restrict) { s += " ON UPDATE \(r.onUpdate.rawValue)" }
            }
            out.append(s + ";")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    func dropFKSQL(_ fk: ForeignKeyMeta, dialect: any SQLDialect) -> String {
        switch dialect.kind {
        case .mysql, .redis:
            return "ALTER TABLE \(dialect.quoteTable(fk.table)) DROP FOREIGN KEY \(dialect.quoteIdent(fk.name));"
        case .postgres, .mssql:
            return "ALTER TABLE \(dialect.quoteTable(fk.table)) DROP CONSTRAINT \(dialect.quoteIdent(fk.name));"
        }
    }
}

public enum ModelError: LocalizedError, Equatable {
    case invalid(String, count: Int)
    case badFile

    public var errorDescription: String? {
        switch self {
        case .invalid(let m, let n): return n > 1 ? tr("%@ (외 %@건)", m, "\(n - 1)") : m
        case .badFile: return tr("GodDB 모델 파일이 아니에요.")
        }
    }
}

// MARK: - 리버스 엔지니어링

extension DataModel {
    /// DB 테이블 → 모델. 코멘트 첫 줄은 논리명, 나머지는 설명. FK(+원하면 추정 관계)는 관계로.
    public static func reverse(_ tables: [TableMeta], name: String, kind: DatabaseKind,
                               inferred: [ForeignKeyMeta] = []) -> DataModel {
        var model = DataModel(name: name, kind: kind == .redis ? .mysql : kind)
        let frames = DiagramLayout.frames(tables, extra: inferred, cardWidth: 260)
        var ids: [String: (table: UUID, columns: [String: UUID])] = [:]
        for t in tables {
            let pk = Set((t.indexes.first(where: \.isPrimary)?.columns ?? t.columns.filter(\.isPrimaryKey).map(\.name))
                .map { $0.lowercased() })
            let tc = splitComment(t.comment)
            var cols: [ModelColumn] = []
            var colIDs: [String: UUID] = [:]
            for c in t.columns.sorted(by: { $0.position < $1.position }) {
                let cc = splitComment(c.comment)
                let extra = c.extra.lowercased()
                let uniqueSingle = t.indexes.contains { $0.unique && !$0.isPrimary && $0.columns.count == 1
                    && $0.columns[0].lowercased() == c.name.lowercased() }
                let col = ModelColumn(logicalName: cc.logical, physicalName: c.name, dataType: c.columnType,
                                      primaryKey: pk.contains(c.name.lowercased()), notNull: !c.nullable,
                                      autoIncrement: extra.contains("auto_increment") || extra.contains("identity"),
                                      unique: uniqueSingle, defaultValue: c.defaultValue.map { reverseDefault($0, kind: kind) } ?? "",
                                      comment: cc.comment)
                colIDs[c.name.lowercased()] = col.id
                cols.append(col)
            }
            // 단일 UNIQUE 와 PK 를 뺀 나머지 인덱스
            let indexes = t.indexes.filter { !$0.isPrimary && !($0.unique && $0.columns.count == 1) }.map { i in
                ModelIndex(name: i.name, unique: i.unique, columns: i.columns.compactMap { colIDs[$0.lowercased()] })
            }
            let f = frames[t.name] ?? .zero
            let mt = ModelTable(logicalName: tc.logical, physicalName: t.name, comment: tc.comment, columns: cols,
                                indexes: indexes, x: f.minX + 40, y: f.minY + 40)
            ids[t.name] = (mt.id, colIDs)
            model.tables.append(mt)
        }
        func relation(_ fk: ForeignKeyMeta, constraint: Bool) -> ModelRelation? {
            guard let c = ids[fk.table], let p = ids[fk.referencedTable] else { return nil }
            let pairs = zip(fk.columns, fk.referencedColumns).compactMap { cc, pc -> ModelRelation.Pair? in
                guard let a = c.columns[cc.lowercased()], let b = p.columns[pc.lowercased()] else { return nil }
                return .init(child: a, parent: b)
            }
            guard !pairs.isEmpty, let child = model.table(c.table) else { return nil }
            let fkCols = pairs.compactMap { pr in child.columns.first { $0.id == pr.child } }
            let identifying = !fkCols.isEmpty && fkCols.allSatisfy(\.primaryKey)
            let oneToOne = fkCols.count == 1 && (fkCols[0].unique || (identifying && child.primaryKey.count == 1))
            return ModelRelation(name: constraint ? fk.name : "", parent: p.table, child: c.table,
                                 cardinality: oneToOne ? .oneToOne : .oneToMany, identifying: identifying,
                                 optional: fkCols.contains { !$0.notNull }, pairs: pairs, createConstraint: constraint)
        }
        model.relations = tables.flatMap(\.foreignKeys).compactMap { relation($0, constraint: true) }
            + inferred.compactMap { relation($0, constraint: false) }
        return model
    }

    /// MySQL 은 기본값을 따옴표 없이 돌려주므로 모델(SQL 식) 형태로 감싼다
    static func reverseDefault(_ v: String, kind: DatabaseKind) -> String {
        guard kind == .mysql || kind == .redis else { return v }
        let upper = v.uppercased()
        if upper == "NULL" || upper.hasPrefix("CURRENT_TIMESTAMP") || upper.hasPrefix("NOW(") || Double(v) != nil
            || (v.hasPrefix("(") && v.hasSuffix(")")) || v.hasPrefix("'") { return v }
        return SQLText.quoteString(v)
    }
}

// MARK: - DB 와 비교 (Synchronize)

extension DataModel {
    /// 모델(원본)과 DB(대상)를 비교해 DB 를 모델에 맞추는 SQL. 기존 스키마 비교 엔진을 그대로 쓴다.
    public func compare(with db: [TableMeta], dialect: (any SQLDialect)? = nil) throws -> SchemaDiffReport {
        let errors = issues().filter { $0.level == .error }
        if let e = errors.first { throw ModelError.invalid(e.message, count: errors.count) }
        return SchemaDiff.compare(source: physicalTables(), target: db, dialect: dialect ?? Dialects.of(kind))
    }

    /// 타입 칸 메뉴에 보일 자주 쓰는 타입
    public static func commonTypes(_ kind: DatabaseKind) -> [String] {
        switch kind {
        case .mysql, .redis:
            return ["bigint", "int", "smallint", "tinyint(1)", "decimal(12,2)", "varchar(50)", "varchar(100)", "varchar(255)",
                    "char(1)", "text", "longtext", "json", "date", "datetime", "datetime(3)", "timestamp"]
        case .postgres:
            return ["bigint", "integer", "smallint", "numeric(12,2)", "varchar(50)", "varchar(100)", "varchar(255)", "char(1)",
                    "text", "jsonb", "boolean", "date", "timestamp", "timestamptz", "uuid"]
        case .mssql:
            return ["bigint", "int", "smallint", "bit", "decimal(12,2)", "varchar(100)", "nvarchar(50)", "nvarchar(100)",
                    "nvarchar(255)", "nvarchar(max)", "char(1)", "date", "datetime2(3)", "uniqueidentifier"]
        }
    }
}

// MARK: - 저장소

/// 모델 파일 저장소: ~/Library/Application Support/GodDB/models/<id>.goddbmodel
public final class ModelStore: @unchecked Sendable {
    public static let shared = ModelStore(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GodDB/models", isDirectory: true))

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func encode(_ model: DataModel) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(model)
    }

    public static func decode(_ data: Data) throws -> DataModel {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let m = try? d.decode(DataModel.self, from: data), m.format == DataModel.formatName else {
            throw ModelError.badFile
        }
        return m
    }

    func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).\(DataModel.fileExtension)") }

    /// 최근 수정 순
    public func list() -> [DataModel] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == DataModel.fileExtension }
            .compactMap { try? Self.decode(Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    public func save(_ model: DataModel) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(model).write(to: url(model.id), options: .atomic)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }
}
