import Foundation

/// 뷰 / 프로시저 / 함수 / 트리거
public struct RoutineMeta: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case view = "VIEW"
        case procedure = "PROCEDURE"
        case function = "FUNCTION"
        case trigger = "TRIGGER"

        public var title: String {
            switch self {
            case .view: return "뷰"
            case .procedure: return "프로시저"
            case .function: return "함수"
            case .trigger: return "트리거"
            }
        }
    }

    public var id: String { "\(kind.rawValue):\(name)" }
    public let kind: Kind
    public let name: String
    public let comment: String

    public init(kind: Kind, name: String, comment: String = "") {
        self.kind = kind
        self.name = name
        self.comment = comment
    }
}

/// 실행 계획 결과에서 성능상 주의할 점을 찾는다. (MySQL EXPLAIN / PostgreSQL QUERY PLAN / SQL Server SHOWPLAN_ALL)
public enum PlanAnalyzer {
    public struct Warning: Hashable, Sendable {
        public let table: String
        public let message: String
    }

    public static func warnings(_ result: QueryResult) -> [Warning] {
        func col(_ name: String) -> Int? { result.columns.firstIndex { $0.name.lowercased() == name.lowercased() } }
        if let i = col("QUERY PLAN") { return postgres(result.rows.compactMap { $0.values[i] }) }
        if let op = col("PhysicalOp") { return mssql(result, op: op, rowsIdx: col("EstimateRows"), argIdx: col("Argument")) }
        return mysql(result, col: col)
    }

    static func mysql(_ result: QueryResult, col: (String) -> Int?) -> [Warning] {
        guard let typeIdx = col("type") else { return [] }
        let tableIdx = col("table"), keyIdx = col("key"), possibleIdx = col("possible_keys"),
            rowsIdx = col("rows"), extraIdx = col("extra")
        var out: [Warning] = []
        for row in result.rows {
            let v = row.values
            let table = tableIdx.flatMap { v[$0] } ?? "?"
            let type = (v[typeIdx] ?? "").uppercased()
            let rows = rowsIdx.flatMap { v[$0] }.flatMap { Int($0) }
            let extra = extraIdx.flatMap { v[$0] } ?? ""
            let key = keyIdx.flatMap { v[$0] }
            let possible = possibleIdx.flatMap { v[$0] }
            let rowsText = rows.map { " (예상 \($0.formatted())행)" } ?? ""

            if type == "ALL" {
                out.append(.init(table: table, message: "풀 테이블 스캔\(rowsText) — WHERE/JOIN 컬럼에 인덱스가 있는지 확인하세요."))
            } else if type == "INDEX" {
                out.append(.init(table: table, message: "인덱스 풀 스캔\(rowsText)"))
            }
            if key == nil, let possible, !possible.isEmpty, type != "ALL" {
                out.append(.init(table: table, message: "사용 가능한 인덱스(\(possible))가 있지만 사용하지 않았어요."))
            }
            if extra.contains("Using filesort") {
                out.append(.init(table: table, message: "정렬을 위해 filesort 사용 — ORDER BY 컬럼 인덱스를 검토하세요."))
            }
            if extra.contains("Using temporary") {
                out.append(.init(table: table, message: "임시 테이블 사용 — GROUP BY / DISTINCT 를 검토하세요."))
            }
        }
        return out
    }

    static func postgres(_ lines: [String]) -> [Warning] {
        var out: [Warning] = []
        let seq = try! NSRegularExpression(pattern: "Seq Scan on (\\S+).*?rows=(\\d+)")
        for line in lines {
            let ns = line as NSString
            if let m = seq.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let table = ns.substring(with: m.range(at: 1))
                let rows = Int(ns.substring(with: m.range(at: 2))) ?? 0
                out.append(.init(table: table, message: "풀 테이블 스캔 (Seq Scan, 예상 \(rows.formatted())행) — WHERE/JOIN 컬럼에 인덱스가 있는지 확인하세요."))
            }
            if line.contains("Sort Method: external") {
                out.append(.init(table: "-", message: "정렬이 메모리를 넘어 디스크를 사용해요 — work_mem 또는 ORDER BY 인덱스를 검토하세요."))
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("->  Sort") || line.hasPrefix("Sort ") {
                out.append(.init(table: "-", message: "정렬(Sort) 단계가 있어요 — ORDER BY 컬럼 인덱스를 검토하세요."))
            }
            if line.contains("Nested Loop") && line.contains("rows=") {
                if let r = line.range(of: "rows=(\\d+)", options: .regularExpression),
                   let n = Int(line[r].dropFirst(5)), n > 10_000 {
                    out.append(.init(table: "-", message: "큰 Nested Loop 조인 (예상 \(n.formatted())행) — 조인 조건 인덱스를 검토하세요."))
                }
            }
        }
        return out
    }

    static func mssql(_ result: QueryResult, op: Int, rowsIdx: Int?, argIdx: Int?) -> [Warning] {
        var out: [Warning] = []
        for row in result.rows {
            let physical = row.values[op] ?? ""
            let argument = argIdx.flatMap { row.values[$0] } ?? ""
            let rows = rowsIdx.flatMap { row.values[$0] }.flatMap { Double($0) }.map { Int($0) }
            let rowsText = rows.map { " (예상 \($0.formatted())행)" } ?? ""
            let table = argument.range(of: "OBJECT:\\(([^)]*)\\)", options: .regularExpression)
                .map { String(argument[$0]).replacingOccurrences(of: "OBJECT:(", with: "").replacingOccurrences(of: ")", with: "") } ?? "-"
            switch physical {
            case "Table Scan", "Clustered Index Scan":
                out.append(.init(table: table, message: "\(physical) — 풀 스캔\(rowsText). WHERE/JOIN 컬럼 인덱스를 확인하세요."))
            case "Index Scan":
                out.append(.init(table: table, message: "인덱스 풀 스캔\(rowsText)"))
            case "Sort":
                out.append(.init(table: "-", message: "정렬(Sort) 단계\(rowsText) — ORDER BY 컬럼 인덱스를 검토하세요."))
            case "Key Lookup", "RID Lookup":
                out.append(.init(table: table, message: "\(physical)\(rowsText) — 인덱스에 필요한 컬럼을 INCLUDE 하면 줄일 수 있어요."))
            default:
                break
            }
        }
        return out
    }
}
