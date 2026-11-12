import Foundation

/// 결과 정렬 (헤더 클릭)
public struct ResultSort: Sendable, Equatable, Hashable {
    public let column: String
    public let ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

public enum ResultSorting {
    /// 앱 안에서 값 비교: NULL 이 가장 앞, 둘 다 숫자면 숫자 크기, 아니면 사람이 읽는 순서 (숫자 섞인 글자도 자연스럽게)
    public static func compare(_ a: String?, _ b: String?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (x?, y?):
            if let dx = Double(x), let dy = Double(y) {
                return dx < dy ? .orderedAscending : (dx > dy ? .orderedDescending : .orderedSame)
            }
            return x.localizedStandardCompare(y)
        }
    }

    /// 행을 정렬한다 (같은 값이면 원래 순서 유지)
    public static func sorted(_ rows: [QueryResult.Row], column: Int, ascending: Bool) -> [QueryResult.Row] {
        rows.enumerated().sorted { l, r in
            let c = compare(l.element.values[column], r.element.values[column])
            if c == .orderedSame { return l.offset < r.offset }
            return ascending ? c == .orderedAscending : c == .orderedDescending
        }.map(\.element)
    }
}

extension SQLDialect {
    /// 원래 쿼리를 감싸 정렬한 SQL. SELECT 가 아니면 nil.
    /// 맨 바깥 ORDER BY 는 바깥 정렬로 대신하므로 뺀다 (단, LIMIT/TOP 이 있으면 결과 집합이 바뀌므로 둔다).
    public func sortedSQL(_ sql: String, sort: ResultSort) -> String? {
        var body = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") { body.removeLast(); body = body.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kw = SQLText.firstKeyword(body)
        guard kw == "SELECT" || (kw == "WITH" && kind != .mssql) else { return nil }
        let upper = SQLText.stripComments(body).uppercased()
        let limited = upper.range(of: "\\bLIMIT\\s+\\d|\\bTOP\\s*\\(?\\s*\\d|\\bOFFSET\\b|\\bFETCH\\s+(FIRST|NEXT)\\b",
                                  options: .regularExpression) != nil
        if !limited { body = SQLText.removingTopLevelOrderBy(body) }
        return "SELECT * FROM (\n\(body)\n) AS goddb_sort ORDER BY \(quoteIdent(sort.column)) \(sort.ascending ? "ASC" : "DESC")"
    }
}
