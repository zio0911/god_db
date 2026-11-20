import Foundation

/// JSON 값 (객체 키 순서를 원래대로 유지)
public indirect enum JSONNode: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONNode])
    case string(String)
    /// 숫자는 원래 글자 그대로 (정밀도 · 표기 유지)
    case number(String)
    case bool(Bool)
    case null

    public var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }
}

public struct JSONMember: Equatable, Sendable {
    public let key: String
    public let value: JSONNode

    public init(_ key: String, _ value: JSONNode) {
        self.key = key
        self.value = value
    }
}

/// 경로 한 칸: 객체 키 또는 배열 번호
public enum JSONPathComponent: Hashable, Sendable {
    case key(String)
    case index(Int)
}

/// 행 상세의 JSON 보기 방식 (설정 키 `GodDB.json.viewMode`)
public enum JSONViewMode: String, CaseIterable, Sendable {
    case raw, pretty, tree

    public static let defaultsKey = "GodDB.json.viewMode"
    public static let `default` = JSONViewMode.tree
}

/// 칸 값이 JSON 인지 판단한 결과
public enum JSONDetection: Equatable, Sendable {
    case notJSON
    /// JSON 으로 보이지만 1MB 가 넘어 원문만 보여 준다 (파싱하지 않음)
    case tooLarge
    case json(JSONNode)
}

public enum JSONView {
    /// 이보다 크면 정렬 · 트리 대신 원문만 (UTF-8 바이트)
    public static let sizeLimit = 1_048_576
    /// 이보다 깊으면 JSON 으로 보지 않는다 (재귀 깊이 보호)
    static let maxDepth = 512

    // MARK: - 판단

    /// 컬럼 타입이 json / jsonb 인지 (`json`, `JSONB`, `json(…)` 등)
    public static func isJSONType(_ columnType: String?) -> Bool {
        guard let t = columnType?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        let base = t.split(whereSeparator: { $0 == "(" || $0 == " " }).first.map(String.init) ?? t
        return base == "json" || base == "jsonb"
    }

    /// 앞뒤 공백을 뺀 값이 `{` 또는 `[` 로 시작하고 JSON 으로 파싱되면 JSON.
    /// 컬럼 타입이 json / jsonb 이면 시작 글자는 보지 않고 파싱만 확인한다.
    /// 1MB 가 넘으면 파싱하지 않고 (시작 글자 · 타입만 보고) `.tooLarge`.
    public static func detect(_ value: String?, columnType: String? = nil) -> JSONDetection {
        guard let value, mightBeJSON(value, columnType: columnType) else { return .notJSON }
        if value.utf8.count > sizeLimit { return .tooLarge }
        guard let node = parse(value) else { return .notJSON }
        return .json(node)
    }

    /// 파싱 전 빠른 확인: 타입이 json / jsonb 이면 공백이 아닌 글자가 있는지, 아니면 첫 글자가 `{` · `[` 인지
    public static func mightBeJSON(_ value: String, columnType: String?) -> Bool {
        guard let first = value.unicodeScalars.first(where: { !isSpace($0) }) else { return false }
        return isJSONType(columnType) || first == "{" || first == "["
    }

    /// 편집한 값이 JSON 으로 파싱되는지 (NULL 은 문제 없음)
    public static func isValid(_ value: String?) -> Bool {
        guard let value else { return true }
        if value.utf8.count > sizeLimit {
            return (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])) != nil
        }
        return parse(value) != nil
    }

    /// 이 칸을 JSON 칸으로 다룰지: 타입이 json / jsonb 이거나 원래 값이 JSON
    public static func isJSONColumn(original: String?, columnType: String?) -> Bool {
        if isJSONType(columnType) { return true }
        switch detect(original, columnType: nil) {
        case .notJSON: return false
        case .json, .tooLarge: return true
        }
    }

    /// 편집 결과에서 JSON 칸인데 JSON 이 깨진 컬럼 이름 (저장 전 경고용, 중복 없이 컬럼 순서대로)
    public static func invalidEdits(_ edits: PendingEdits, target: EditTarget, columns: [String],
                                    rows: [QueryResult.Row]) -> [String] {
        func type(_ col: Int) -> String? {
            guard let name = target.columnMap[col] else { return nil }
            return target.table.columns.first { $0.name.lowercased() == name.lowercased() }?.columnType
        }
        var bad = Set<Int>()
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (rowID, changes) in edits.updates where !edits.deletes.contains(rowID) {
            for (col, value) in changes {
                let original = byID[rowID].flatMap { $0.values.indices.contains(col) ? $0.values[col] : nil }
                if isJSONColumn(original: original, columnType: type(col)), !isValid(value) { bad.insert(col) }
            }
        }
        for insert in edits.inserts {
            for (col, value) in insert where isJSONType(type(col)) && !isValid(value) { bad.insert(col) }
        }
        return bad.sorted().compactMap { columns.indices.contains($0) ? columns[$0] : nil }
    }

    // MARK: - 파싱 (키 순서 유지)

    /// 엄격한 JSON 파싱. 전체가 하나의 JSON 값이어야 한다 (앞뒤 공백 허용).
    public static func parse(_ text: String) -> JSONNode? {
        var p = Parser(bytes: Array(text.utf8))
        guard let node = p.value(depth: 0) else { return nil }
        p.skipSpace()
        return p.pos == p.bytes.count ? node : nil
    }

    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "\n" || s == "\r"
    }

    private struct Parser {
        let bytes: [UInt8]
        var pos = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while pos < bytes.count {
                switch bytes[pos] {
                case 0x20, 0x09, 0x0A, 0x0D: pos += 1
                default: return
                }
            }
        }

        mutating func literal(_ word: String) -> Bool {
            let w = Array(word.utf8)
            guard pos + w.count <= bytes.count, Array(bytes[pos..<pos + w.count]) == w else { return false }
            pos += w.count
            return true
        }

        mutating func value(depth: Int) -> JSONNode? {
            guard depth <= JSONView.maxDepth else { return nil }
            skipSpace()
            guard pos < bytes.count else { return nil }
            switch bytes[pos] {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(JSONNode.string)
            case UInt8(ascii: "t"): return literal("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return literal("false") ? .bool(false) : nil
            case UInt8(ascii: "n"): return literal("null") ? .null : nil
            default: return number()
            }
        }

        mutating func object(depth: Int) -> JSONNode? {
            pos += 1
            var members: [JSONMember] = []
            skipSpace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object([]) }
            while true {
                skipSpace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipSpace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { return nil }
                pos += 1
                guard let v = value(depth: depth + 1) else { return nil }
                members.append(JSONMember(key, v))
                skipSpace()
                guard pos < bytes.count else { return nil }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(members) }
                return nil
            }
        }

        mutating func array(depth: Int) -> JSONNode? {
            pos += 1
            var items: [JSONNode] = []
            skipSpace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array([]) }
            while true {
                guard let v = value(depth: depth + 1) else { return nil }
                items.append(v)
                skipSpace()
                guard pos < bytes.count else { return nil }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
                return nil
            }
        }

        mutating func hex4() -> UInt32? {
            guard pos + 4 <= bytes.count else { return nil }
            var v: UInt32 = 0
            for b in bytes[pos..<pos + 4] {
                v <<= 4
                switch b {
                case 0x30...0x39: v |= UInt32(b - 0x30)
                case 0x41...0x46: v |= UInt32(b - 0x41 + 10)
                case 0x61...0x66: v |= UInt32(b - 0x61 + 10)
                default: return nil
                }
            }
            pos += 4
            return v
        }

        /// `"` 에서 시작해 닫는 `"` 다음까지
        mutating func string() -> String? {
            pos += 1
            var out: [UInt8] = []
            while pos < bytes.count {
                let b = bytes[pos]
                if b == UInt8(ascii: "\"") {
                    pos += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if b < 0x20 { return nil }
                if b != UInt8(ascii: "\\") { out.append(b); pos += 1; continue }
                pos += 1
                guard pos < bytes.count else { return nil }
                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard var code = hex4() else { return nil }
                    if (0xD800...0xDBFF).contains(code) {
                        // 짝이 되는 낮은 서로게이트가 이어지면 합친다
                        if pos + 6 <= bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                            let save = pos
                            pos += 2
                            if let low = hex4(), (0xDC00...0xDFFF).contains(low) {
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                pos = save
                                code = 0xFFFD
                            }
                        } else {
                            code = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(code) {
                        code = 0xFFFD
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    return nil
                }
            }
            return nil
        }

        /// -?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?
        mutating func number() -> JSONNode? {
            let start = pos
            func digit(_ i: Int) -> Bool { i < bytes.count && (0x30...0x39).contains(bytes[i]) }
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            guard digit(pos) else { return nil }
            if bytes[pos] == UInt8(ascii: "0") { pos += 1 } else { while digit(pos) { pos += 1 } }
            if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
                pos += 1
                guard digit(pos) else { return nil }
                while digit(pos) { pos += 1 }
            }
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
                pos += 1
                if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
                guard digit(pos) else { return nil }
                while digit(pos) { pos += 1 }
            }
            return .number(String(decoding: bytes[start..<pos], as: UTF8.self))
        }
    }

    // MARK: - 정렬 출력

    /// 들여쓰기 2칸, 키는 원래 순서. 한글 등은 그대로 두고 꼭 필요한 것만 이스케이프.
    public static func pretty(_ node: JSONNode) -> String {
        var out = ""
        write(node, indent: 0, into: &out)
        return out
    }

    private static func write(_ node: JSONNode, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent + 1)
        let close = String(repeating: "  ", count: indent)
        switch node {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (i, m) in members.enumerated() {
                out += pad + quote(m.key) + ": "
                write(m.value, indent: indent + 1, into: &out)
                out += i == members.count - 1 ? "\n" : ",\n"
            }
            out += close + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (i, v) in items.enumerated() {
                out += pad
                write(v, indent: indent + 1, into: &out)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += close + "]"
        default:
            out += scalarText(node)
        }
    }

    /// 한 줄 JSON 글자 (객체 · 배열은 한 줄로)
    public static func compact(_ node: JSONNode) -> String {
        switch node {
        case .object(let members):
            return "{" + members.map { quote($0.key) + ":" + compact($0.value) }.joined(separator: ",") + "}"
        case .array(let items):
            return "[" + items.map(compact).joined(separator: ",") + "]"
        default:
            return scalarText(node)
        }
    }

    /// 문자 · 숫자 · 참거짓 · null 의 JSON 표기
    public static func scalarText(_ node: JSONNode) -> String {
        switch node {
        case .string(let s): return quote(s)
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .object, .array: return compact(node)
        }
    }

    /// "값 복사" 에 넣을 글자: 문자는 따옴표 없이 내용만, 객체 · 배열은 정렬 출력
    public static func copyText(_ node: JSONNode) -> String {
        switch node {
        case .string(let s): return s
        case .object, .array: return pretty(node)
        default: return scalarText(node)
        }
    }

    /// JSON 문자열 표기 (따옴표 포함)
    public static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    // MARK: - 경로

    /// `$.order.items[0].sku` 꼴. 식별자가 아닌 키는 `$["key with space"]`.
    public static func path(_ components: [JSONPathComponent]) -> String {
        var out = "$"
        for c in components {
            switch c {
            case .index(let i): out += "[\(i)]"
            case .key(let k): out += isIdentifier(k) ? "." + k : "[" + quote(k) + "]"
            }
        }
        return out
    }

    /// 글자(한글 포함) 또는 `_` 로 시작하고 글자 · 숫자 · `_` 만 있으면 식별자
    static func isIdentifier(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        func letter(_ u: Unicode.Scalar) -> Bool { u == "_" || u.properties.isAlphabetic }
        func digit(_ u: Unicode.Scalar) -> Bool { ("0"..."9").contains(u) }
        return letter(first) && key.unicodeScalars.dropFirst().allSatisfy { letter($0) || digit($0) }
    }
}
