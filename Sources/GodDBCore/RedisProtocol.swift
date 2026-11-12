import Foundation
import NIOCore

/// Redis 응답 값 (RESP2)
public indirect enum RESPValue: Sendable, Equatable {
    case simple(String)
    case error(String)
    case integer(Int)
    case bulk([UInt8]?)
    case array([RESPValue]?)

    /// 글자로 (bulk 는 UTF-8, 아니면 redis-cli 처럼 \xNN)
    public var string: String? {
        switch self {
        case .simple(let s): return s
        case .error(let s): return s
        case .integer(let i): return String(i)
        case .bulk(let b): return b.map(RedisText.display)
        case .array: return nil
        }
    }

    public var int: Int? {
        switch self {
        case .integer(let i): return i
        case .bulk, .simple: return string.flatMap { Int($0) }
        default: return nil
        }
    }

    public var array: [RESPValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var isNil: Bool {
        switch self {
        case .bulk(nil), .array(nil): return true
        default: return false
        }
    }

    /// redis-cli 와 비슷한 모양의 텍스트
    public func formatted(indent: String = "") -> String {
        switch self {
        case .simple(let s): return s
        case .error(let s): return "(error) " + s
        case .integer(let i): return "(integer) \(i)"
        case .bulk(nil), .array(nil): return "(nil)"
        case .bulk(let b?): return "\"" + RedisText.display(b).replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case .array(let a?):
            if a.isEmpty { return "(empty array)" }
            let width = String(a.count).count
            return a.enumerated().map { i, v in
                let n = String(i + 1)
                let prefix = String(repeating: " ", count: width - n.count) + n + ") "
                let inner = v.formatted(indent: indent + String(repeating: " ", count: prefix.count))
                return (i == 0 ? "" : indent) + prefix + inner
            }.joined(separator: "\n")
        }
    }
}

public struct RedisServerError: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    /// WRONGPASS, NOAUTH, ERR … 같은 앞 단어
    public var code: String { String(message.prefix { $0 != " " }) }
}

public enum RedisText {
    /// 바이트를 화면 글자로. UTF-8 이면 그대로, 아니면 출력 불가 바이트를 \xNN 으로.
    public static func display(_ bytes: [UInt8]) -> String {
        if !bytes.contains(0), let s = String(bytes: bytes, encoding: .utf8) {
            return s
        }
        var out = ""
        for b in bytes {
            if b >= 0x20 && b < 0x7F { out.append(Character(UnicodeScalar(b))) }
            else if b == 0x0A { out += "\\n" }
            else if b == 0x0D { out += "\\r" }
            else if b == 0x09 { out += "\\t" }
            else { out += String(format: "\\x%02x", b) }
        }
        return out
    }

    /// Workbench 편집기 글을 실행할 명령 줄들로 (빈 줄, // 와 # 주석 줄은 건너뜀)
    public static func scriptLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") && !$0.hasPrefix("#") }
    }

    /// 콘솔 한 줄을 인자로 나눈다. "…" '…' 따옴표와 \n \t \xNN 이스케이프 지원 (redis-cli 와 같은 규칙)
    public static func splitArgs(_ line: String) -> [String]? {
        var args: [String] = []
        var cur = ""
        var inArg = false
        var quote: Character? = nil
        let it = Array(line)
        var i = 0
        while i < it.count {
            let c = it[i]
            if let q = quote {
                if c == "\\" && q == "\"" && i + 1 < it.count {
                    let n = it[i + 1]
                    switch n {
                    case "n": cur.append("\n"); i += 2; continue
                    case "t": cur.append("\t"); i += 2; continue
                    case "r": cur.append("\r"); i += 2; continue
                    case "x" where i + 3 < it.count:
                        if let v = UInt8(String(it[(i + 2)...(i + 3)]), radix: 16) {
                            cur.unicodeScalars.append(UnicodeScalar(v)); i += 4; continue
                        }
                    default: cur.append(n); i += 2; continue
                    }
                }
                if c == "\\" && q == "'" && i + 1 < it.count && it[i + 1] == "'" {
                    cur.append("'"); i += 2; continue
                }
                if c == q {
                    quote = nil
                    // 닫는 따옴표 뒤에는 공백이 와야 한다
                    if i + 1 < it.count && !it[i + 1].isWhitespace { return nil }
                } else {
                    cur.append(c)
                }
            } else if c.isWhitespace {
                if inArg { args.append(cur); cur = ""; inArg = false }
            } else if (c == "\"" || c == "'") && !inArg {
                quote = c
                inArg = true
            } else {
                cur.append(c)
                inArg = true
            }
            i += 1
        }
        if quote != nil { return nil }
        if inArg { args.append(cur) }
        return args
    }
}

// MARK: - 인코딩 / 디코딩

enum RESPCoder {
    static func encode(_ args: [[UInt8]], into buffer: inout ByteBuffer) {
        buffer.writeString("*\(args.count)\r\n")
        for a in args {
            buffer.writeString("$\(a.count)\r\n")
            buffer.writeBytes(a)
            buffer.writeString("\r\n")
        }
    }

    /// 버퍼에서 값 하나를 읽는다. 아직 다 안 왔으면 nil (버퍼 위치는 그대로).
    static func decode(_ buffer: inout ByteBuffer) throws -> RESPValue? {
        var copy = buffer
        guard let v = try parse(&copy) else { return nil }
        buffer = copy
        return v
    }

    private static func line(_ b: inout ByteBuffer) -> String? {
        let view = b.readableBytesView
        guard let cr = view.firstIndex(of: 0x0D), view.index(after: cr) < view.endIndex,
              view[view.index(after: cr)] == 0x0A else { return nil }
        let len = cr - view.startIndex
        let s = b.readString(length: len)
        b.moveReaderIndex(forwardBy: 2)
        return s
    }

    private static func parse(_ b: inout ByteBuffer) throws -> RESPValue? {
        guard let type: UInt8 = b.readInteger() else { return nil }
        guard let l = line(&b) else { return nil }
        switch type {
        case UInt8(ascii: "+"): return .simple(l)
        case UInt8(ascii: "-"): return .error(l)
        case UInt8(ascii: ":"):
            guard let i = Int(l) else { throw RedisProtocolError.bad("integer \(l)") }
            return .integer(i)
        case UInt8(ascii: "$"):
            guard let n = Int(l) else { throw RedisProtocolError.bad("bulk \(l)") }
            if n < 0 { return .bulk(nil) }
            guard b.readableBytes >= n + 2, let bytes = b.readBytes(length: n) else { return nil }
            b.moveReaderIndex(forwardBy: 2)
            return .bulk(bytes)
        case UInt8(ascii: "*"):
            guard let n = Int(l) else { throw RedisProtocolError.bad("array \(l)") }
            if n < 0 { return .array(nil) }
            var items: [RESPValue] = []
            items.reserveCapacity(n)
            for _ in 0..<n {
                guard let v = try parse(&b) else { return nil }
                items.append(v)
            }
            return .array(items)
        default:
            throw RedisProtocolError.bad("type byte \(type)")
        }
    }
}

enum RedisProtocolError: LocalizedError {
    case bad(String)
    var errorDescription: String? {
        switch self { case .bad(let s): return "Redis protocol error: \(s)" }
    }
}
