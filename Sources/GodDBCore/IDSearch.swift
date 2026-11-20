import Foundation

/// ID 로 찾기 (⌥⌘F): 로그에서 복사한 글에서 ID 를 뽑아 `SELECT * FROM t WHERE c IN (…)` 로 조회하고,
/// 결과에 없는 ID 를 알려 준다. (명세 docs/specs/1.4.0.md · F1)
public enum IDSearch {
    /// 한 번에 조회하는 값의 최대 개수
    public static let maxValues = 1_000
    /// 미리보기로 보여 주는 값 개수
    public static let previewCount = 20
    /// 자동으로 올리는 결과 행 수 제한의 최대값
    public static let maxRowLimit = 5_000

    /// 붙여넣은 글에서 뽑은 값
    public struct Extraction: Equatable, Sendable {
        /// 조회에 쓰는 값 (순서 유지 · 중복 제거 · 최대 maxValues 개)
        public var values: [String]
        /// 중복이라 뺀 개수
        public var duplicates: Int
        /// maxValues 를 넘어서 뺀 개수
        public var overflow: Int

        /// 중복을 뺀 전체 개수 (넘친 것 포함)
        public var uniqueCount: Int { values.count + overflow }
    }

    // MARK: - 컬럼 타입

    private static let numericTypes: Set<String> = [
        "tinyint", "smallint", "mediumint", "int", "integer", "bigint",
        "decimal", "numeric", "float", "double", "real", "double precision", "number",
        "int2", "int4", "int8", "float4", "float8", "serial", "smallserial", "bigserial",
        "money", "smallmoney",
    ]

    /// 정수 · 소수 타입인지 (`bigint(20) unsigned`, `numeric(10,2)`, `int4` 등)
    public static func isNumericType(_ columnType: String) -> Bool {
        var t = columnType.lowercased()
        if let p = t.firstIndex(of: "(") { t = String(t[..<p]) }
        for word in [" unsigned", " signed", " zerofill", " identity"] { t = t.replacingOccurrences(of: word, with: "") }
        t = t.trimmingCharacters(in: .whitespaces)
        return numericTypes.contains(t)
    }

    // MARK: - 값 뽑기

    private static let numberRegex = try! NSRegularExpression(pattern: #"(?<![\w.-])-?\d+(?![\w.])"#)
    private static let tokenRegex = try! NSRegularExpression(pattern: #"[A-Za-z0-9][A-Za-z0-9_\-:.]{0,99}"#)
    /// 날짜 (ISO 8601 날짜+시각 포함) · 시각 꼴
    private static let dateTimeRegex = try! NSRegularExpression(
        pattern: #"\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2}(?:[.,]\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?|\d{2}:\d{2}:\d{2}(?:[.,]\d+)?"#)
    private static let levelWords: Set<String> = ["INFO", "WARN", "WARNING", "ERROR", "DEBUG", "TRACE"]

    /// 글에서 ID 를 뽑는다.
    /// - Parameter text: 붙여넣은 글 (로그 등)
    /// - Parameter numeric: 숫자 컬럼이고 "문자 ID 포함" 을 켜지 않았으면 true → 숫자만
    public static func extract(_ text: String, numeric: Bool) -> Extraction {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var raw: [String] = []
        if numeric {
            // 날짜 · 시각 안의 숫자(2026, 10 …)는 빼고
            let dateRanges = dateTimeRegex.matches(in: text, range: all).map(\.range)
            for m in numberRegex.matches(in: text, range: all)
            where !dateRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                raw.append(ns.substring(with: m.range))
            }
        } else {
            for m in tokenRegex.matches(in: text, range: all) {
                // 문장 끝의 . : - 는 ID 가 아니다 ("id=A-77." → A-77)
                var token = ns.substring(with: m.range)
                while let last = token.last, ".:-".contains(last) { token.removeLast() }
                guard !token.isEmpty, !isDateTime(token), !levelWords.contains(token.uppercased()) else { continue }
                raw.append(token)
            }
        }
        var seen = Set<String>()
        var unique: [String] = []
        for v in raw where seen.insert(numeric ? normalize(v) : v).inserted {
            unique.append(v)
        }
        let used = Array(unique.prefix(maxValues))
        return Extraction(values: used, duplicates: raw.count - unique.count, overflow: unique.count - used.count)
    }

    /// 글자 전체가 날짜 · 시각 꼴인지
    static func isDateTime(_ token: String) -> Bool {
        let ns = token as NSString
        guard let m = dateTimeRegex.firstMatch(in: token, range: NSRange(location: 0, length: ns.length)) else { return false }
        return m.range.location == 0 && m.range.length == ns.length
    }

    /// 미리보기: 앞 previewCount 개 + "…외 N개"
    public static func preview(_ values: [String]) -> String {
        let head = values.prefix(previewCount).joined(separator: ", ")
        return values.count > previewCount ? head + " " + tr("…외 %@개", "\(values.count - previewCount)") : head
    }

    // MARK: - SQL

    /// `SELECT * FROM <테이블> WHERE <컬럼> IN (…)`. 숫자 컬럼은 따옴표 없이, 그 밖은 다이얼렉트 문자열 인용.
    public static func sql(table: String, column: String, values: [String], numeric: Bool, dialect: any SQLDialect) -> String {
        let list = values.map { literal($0, numeric: numeric, dialect: dialect) }
        return "SELECT * FROM \(dialect.quoteTable(table)) WHERE \(dialect.quoteIdent(column)) IN (\(list.joined(separator: ", ")))"
    }

    /// 탭 제목: `ID: <테이블>.<컬럼> (N)`
    public static func tabTitle(table: String, column: String, count: Int) -> String {
        "ID: \(table).\(column) (\(count))"
    }

    /// 결과 행 수 제한: 평소 설정 그대로, 값이 더 많으면 값 개수 이상으로 (최대 maxRowLimit). 0 은 "제한 없음".
    public static func rowLimit(current: Int, valueCount: Int) -> Int {
        guard current > 0 else { return 0 }
        return max(current, min(valueCount, maxRowLimit))
    }

    /// 값 하나의 SQL 글자: 숫자 컬럼이고 숫자 꼴이면 그대로, 그 밖은 다이얼렉트 문자열 인용 (MSSQL 은 N'…')
    public static func literal(_ value: String, numeric: Bool, dialect: any SQLDialect) -> String {
        numeric && isNumberLiteral(value) ? value : dialect.quoteString(value)
    }

    private static func isNumberLiteral(_ s: String) -> Bool {
        s.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil
    }

    // MARK: - 없는 ID

    /// 비교용 값: 대소문자 구분 없이, 숫자는 앞 0(과 소수점 뒤 끝 0)을 뗀다.
    public static func normalize(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard isNumberLiteral(v) else { return v.lowercased() }
        var negative = false
        var s = Substring(v)
        if s.first == "-" { negative = true; s = s.dropFirst() }
        var intPart = s
        var frac = Substring("")
        if let dot = s.firstIndex(of: ".") {
            intPart = s[..<dot]
            frac = s[s.index(after: dot)...]
            while frac.last == "0" { frac = frac.dropLast() }
        }
        while intPart.count > 1, intPart.first == "0" { intPart = intPart.dropFirst() }
        var out = String(intPart) + (frac.isEmpty ? "" : "." + frac)
        if negative && out != "0" { out = "-" + out }
        return out
    }

    public struct Comparison: Equatable, Sendable {
        public var requested: Int
        public var found: Int
        /// 결과에 없는 값 (요청한 순서)
        public var missing: [String]
    }

    /// 요청한 값과 결과의 그 컬럼 값을 비교한다.
    public static func compare(requested: [String], found: [String?]) -> Comparison {
        let have = Set(found.compactMap { $0.map(normalize) })
        let missing = requested.filter { !have.contains(normalize($0)) }
        return Comparison(requested: requested.count, found: requested.count - missing.count, missing: missing)
    }
}

// MARK: - 마지막 선택 기억 (id-search.json)

/// 접속 · DB 별로 마지막에 쓴 테이블 · 컬럼. 형식: `{"version":1,"last":[{profileID,database,table,column,updatedAt}]}`
public struct IDSearchMemory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var profileID: UUID
        public var database: String
        public var table: String
        public var column: String
        public var updatedAt: Date

        public init(profileID: UUID, database: String, table: String, column: String, updatedAt: Date = Date()) {
            self.profileID = profileID
            self.database = database
            self.table = table
            self.column = column
            self.updatedAt = updatedAt
        }
    }

    public var version = 1
    public var last: [Entry] = []

    public init(last: [Entry] = []) { self.last = last }

    /// 이 접속 · DB 에서 마지막으로 쓴 테이블
    public func lastTable(profileID: UUID, database: String) -> String? {
        last.filter { $0.profileID == profileID && $0.database == database }
            .max { $0.updatedAt < $1.updatedAt }?.table
    }

    /// 이 접속 · DB · 테이블에서 마지막으로 쓴 컬럼
    public func lastColumn(profileID: UUID, database: String, table: String) -> String? {
        last.first { $0.profileID == profileID && $0.database == database && $0.table == table }?.column
    }

    /// 기록 (같은 접속 · DB · 테이블은 바꿔 쓴다). 오래된 것부터 지워 최대 maxEntries 개.
    public mutating func remember(_ entry: Entry, maxEntries: Int = 500) {
        last.removeAll { $0.profileID == entry.profileID && $0.database == entry.database && $0.table == entry.table }
        last.append(entry)
        if last.count > maxEntries {
            last.sort { $0.updatedAt < $1.updatedAt }
            last.removeFirst(last.count - maxEntries)
        }
    }
}

public struct IDSearchStore: Sendable {
    public static let shared = IDSearchStore(file: AppPaths.dataDirectory.appendingPathComponent("id-search.json"))

    public let file: URL

    public init(file: URL) { self.file = file }

    public func load() -> IDSearchMemory {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file), let m = try? d.decode(IDSearchMemory.self, from: data) else {
            return IDSearchMemory()
        }
        return m
    }

    public func save(_ memory: IDSearchMemory) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? e.encode(memory) { try? data.write(to: file, options: .atomic) }
    }
}
