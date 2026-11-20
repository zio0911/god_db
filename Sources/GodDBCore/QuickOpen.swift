import Foundation

/// 객체 빠른 찾기 (⌘O): 이름 일부 · 첫 글자들로 테이블 · 뷰 · 프로시저 · 함수 · 컬럼을 찾는다
public enum QuickOpen {
    public enum Kind: String, Sendable, CaseIterable {
        case table, view, procedure, function, trigger, column, database
        /// 저장 쿼리 (schema = 폴더, detail = 저장 쿼리 id)
        case savedQuery
    }

    public struct Item: Identifiable, Hashable, Sendable {
        public var id: String { "\(kind.rawValue):\(schema):\(name):\(detail)" }
        public let kind: Kind
        /// 이 객체가 있는 DB(스키마)
        public let schema: String
        public let name: String
        /// 컬럼이면 테이블 이름, 아니면 코멘트 등
        public let detail: String

        public init(kind: Kind, schema: String, name: String, detail: String = "") {
            self.kind = kind
            self.schema = schema
            self.name = name
            self.detail = detail
        }
    }

    /// 높을수록 잘 맞음. 맞지 않으면 nil.
    /// 같음 > 앞부분 > 단어(_ . 뒤) 앞부분 > 포함 > 글자 순서대로 들어 있음(ord_it → order_items)
    public static func score(_ query: String, _ name: String) -> Int? {
        let q = query.lowercased().filter { !$0.isWhitespace }
        guard !q.isEmpty else { return 0 }
        let n = name.lowercased()
        if n == q { return 1000 }
        if n.hasPrefix(q) { return 800 - min(n.count, 200) }
        let words = n.split(whereSeparator: { $0 == "_" || $0 == "." || $0 == " " })
        if words.contains(where: { $0.hasPrefix(q) }) { return 600 - min(n.count, 200) }
        if n.contains(q) { return 400 - min(n.count, 200) }
        // 글자 순서대로 (중간을 건너뛰어도 됨)
        var it = n.makeIterator()
        var gaps = 0
        for ch in q {
            var found = false
            while let c = it.next() {
                if c == ch { found = true; break }
                gaps += 1
            }
            if !found { return nil }
        }
        return max(1, 200 - gaps - min(n.count, 100))
    }

    /// 점수 순 (같으면 종류 · 이름 순), 최대 limit 개
    public static func search(_ query: String, in items: [Item], limit: Int = 200) -> [Item] {
        let order = Dictionary(uniqueKeysWithValues: Kind.allCases.enumerated().map { ($1, $0) })
        return items.compactMap { item -> (Item, Int)? in
            // "schema.name" 으로도 찾을 수 있게
            let s = max(score(query, item.name) ?? -1, (score(query, item.schema + "." + item.name) ?? -1) - 50,
                        item.kind == .column ? (score(query, item.detail + "." + item.name) ?? -1) - 20 : -1)
            return s >= 0 ? (item, s) : nil
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if order[$0.0.kind]! != order[$1.0.kind]! { return order[$0.0.kind]! < order[$1.0.kind]! }
            return $0.0.name < $1.0.name
        }
        .prefix(limit).map(\.0)
    }
}
