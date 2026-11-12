import Foundation

public struct ColumnMeta: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var columnType: String
    public var nullable: Bool
    public var defaultValue: String?
    public var extra: String
    public var columnKey: String
    public var comment: String
    public var position: Int

    public init(name: String, columnType: String, nullable: Bool, defaultValue: String? = nil,
                extra: String = "", columnKey: String = "", comment: String = "", position: Int = 0) {
        self.name = name
        self.columnType = columnType
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.extra = extra
        self.columnKey = columnKey
        self.comment = comment
        self.position = position
    }

    public var isPrimaryKey: Bool { columnKey == "PRI" }
}

public struct IndexMeta: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var unique: Bool
    public var columns: [String]
    /// 기본 키 인덱스 (MySQL 은 이름이 PRIMARY, PostgreSQL/SQL Server 는 제약조건 이름)
    public var isPrimary: Bool
    /// PRIMARY KEY / UNIQUE 제약조건이 만든 인덱스 (삭제 시 DROP CONSTRAINT 필요)
    public var isConstraint: Bool

    public init(name: String, unique: Bool, columns: [String], primary: Bool? = nil, constraint: Bool? = nil) {
        self.name = name
        self.unique = unique
        self.columns = columns
        let p = primary ?? (name == "PRIMARY")
        self.isPrimary = p
        self.isConstraint = constraint ?? p
    }
}

public struct TableMeta: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var comment: String
    public var columns: [ColumnMeta]
    public var indexes: [IndexMeta]
    /// 이 테이블이 다른 테이블을 참조하는 외래 키
    public var foreignKeys: [ForeignKeyMeta] = []

    public init(name: String, comment: String = "", columns: [ColumnMeta] = [], indexes: [IndexMeta] = [],
                foreignKeys: [ForeignKeyMeta] = []) {
        self.name = name
        self.comment = comment
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
    }
}

public struct QueryResult: Sendable {
    public struct Column: Identifiable, Sendable, Hashable {
        public let id: Int
        public let name: String
    }
    public struct Row: Identifiable, Sendable {
        public let id: Int
        public let values: [String?]

        public init(id: Int, values: [String?]) {
            self.id = id
            self.values = values
        }
    }

    public let id = UUID()
    public var columns: [Column]
    public var rows: [Row]
    public var elapsed: TimeInterval
    public var message: String?
    /// 이 결과를 만든 SQL (여러 문장 실행 시 결과 탭 이름에 사용)
    public var sql: String?
    /// 페이징: 0부터 시작하는 페이지 번호, 페이지 크기(0 이면 페이징 안 함), 다음 페이지 존재 여부, 전체 행 수(센 경우)
    public var page = 0
    public var pageSize = 0
    public var hasMore = false
    public var totalCount: Int?
    /// DB 에서 정렬해 가져온 경우 (페이지를 넘겨도 유지)
    public var serverSort: ResultSort?
    /// 앱 안에서 정렬한 경우 (한 페이지짜리 결과)
    public var clientSort: ResultSort?

    /// 헤더에 표시할 정렬
    public var activeSort: ResultSort? { serverSort ?? clientSort }

    public var isPaged: Bool { pageSize > 0 }
    /// 이 페이지 첫 행의 전체 기준 번호 (0부터)
    public var rowOffset: Int { page * pageSize }

    public init(columns: [String], rows: [[String?]], elapsed: TimeInterval, message: String? = nil) {
        self.columns = columns.enumerated().map { Column(id: $0.offset, name: $0.element) }
        self.rows = rows.enumerated().map { Row(id: $0.offset, values: $0.element) }
        self.elapsed = elapsed
        self.message = message
    }

    /// RFC 4180 CSV 로 변환 (파일 저장은 lineEnding "\r\n" — 엑셀 호환)
    public func csv(lineEnding: String = "\n") -> String {
        func esc(_ v: String?) -> String {
            guard let v else { return "" }
            if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return v
        }
        var lines = [columns.map { esc($0.name) }.joined(separator: ",")]
        for r in rows { lines.append(r.values.map(esc).joined(separator: ",")) }
        return lines.joined(separator: lineEnding)
    }
}
