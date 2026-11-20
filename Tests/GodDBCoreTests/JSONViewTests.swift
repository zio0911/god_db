import Foundation
import Testing
@testable import GodDBCore

@Suite("JSONView")
struct JSONViewTests {
    // MARK: - 판단

    @Test func detectsObjectsAndArrays() {
        #expect(JSONView.detect(#"{"a":1}"#).isJSONValue)
        #expect(JSONView.detect("  [1, 2, 3]\n").isJSONValue)
        #expect(JSONView.detect("{}").isJSONValue)
        #expect(JSONView.detect("[]").isJSONValue)
    }

    @Test func plainValuesAreNotJSON() {
        #expect(JSONView.detect("hello") == .notJSON)
        #expect(JSONView.detect("123") == .notJSON)
        #expect(JSONView.detect(#""quoted""#) == .notJSON)
        #expect(JSONView.detect("true") == .notJSON)
        #expect(JSONView.detect("") == .notJSON)
        #expect(JSONView.detect(nil) == .notJSON)
    }

    @Test func brokenJSONIsNotJSON() {
        #expect(JSONView.detect(#"{"a":1"#) == .notJSON)
        #expect(JSONView.detect(#"{"a":1,}"#) == .notJSON)
        #expect(JSONView.detect("[1, 2] trailing") == .notJSON)
        #expect(JSONView.detect("{a:1}") == .notJSON)
        #expect(JSONView.detect("[01]") == .notJSON)
        #expect(JSONView.detect("[1.]") == .notJSON)
        #expect(JSONView.detect(#"["tab\there"]"#.replacingOccurrences(of: "\\t", with: "\t")) == .notJSON)
        #expect(JSONView.detect(#"["\x"]"#) == .notJSON)
        #expect(JSONView.detect("{[tag]} 로그 줄") == .notJSON)
    }

    @Test func jsonTypedColumnOnlyChecksParse() {
        #expect(JSONView.isJSONType("json"))
        #expect(JSONView.isJSONType("JSONB"))
        #expect(!JSONView.isJSONType("varchar(100)"))
        #expect(!JSONView.isJSONType(nil))
        #expect(JSONView.detect(#""text""#, columnType: "json") == .json(.string("text")))
        #expect(JSONView.detect("42", columnType: "jsonb") == .json(.number("42")))
        #expect(JSONView.detect("null", columnType: "json") == .json(.null))
        #expect(JSONView.detect("not json", columnType: "json") == .notJSON)
        #expect(JSONView.detect("   ", columnType: "json") == .notJSON)
        // 타입이 json 이 아니면 시작 글자도 본다
        #expect(JSONView.detect("42", columnType: "varchar(10)") == .notJSON)
    }

    @Test func overOneMegabyteShowsRawOnly() {
        let item = #"{"k":"0123456789012345678901234567890123456789"},"#
        let big = "[" + String(repeating: item, count: JSONView.sizeLimit / item.utf8.count + 1) + "1]"
        #expect(big.utf8.count > JSONView.sizeLimit)
        #expect(JSONView.detect(big) == .tooLarge)
        #expect(JSONView.detect(big, columnType: "json") == .tooLarge)
        #expect(JSONView.detect("x" + big) == .notJSON)
        let small = "[" + String(repeating: item, count: 100) + "1]"
        #expect(JSONView.detect(small).isJSONValue)
        #expect(JSONView.isValid(big))
    }

    // MARK: - 파싱 · 정렬 출력

    @Test func prettyKeepsOriginalKeyOrder() throws {
        let text = #"{"z":1,"a":{"y":true,"b":null},"m":[1,"two",{"k":-0.5e3}],"e":{},"f":[]}"#
        let node = try #require(JSONView.parse(text))
        #expect(JSONView.pretty(node) == """
        {
          "z": 1,
          "a": {
            "y": true,
            "b": null
          },
          "m": [
            1,
            "two",
            {
              "k": -0.5e3
            }
          ],
          "e": {},
          "f": []
        }
        """)
        #expect(JSONView.compact(node) == text)
    }

    @Test func escapesAndUnicode() throws {
        let text = #"{"name":"홍길동","quote":"say \"hi\"","path":"C:\\temp\/x","nl":"a\nb\tc","u":"\u00e9\uAC00","emoji":"\ud83d\ude00","ctl":"\u0001"}"#
        let node = try #require(JSONView.parse(text))
        guard case .object(let m) = node else { Issue.record("객체가 아님"); return }
        #expect(m.map(\.key) == ["name", "quote", "path", "nl", "u", "emoji", "ctl"])
        #expect(m[0].value == .string("홍길동"))
        #expect(m[1].value == .string(#"say "hi""#))
        #expect(m[2].value == .string(#"C:\temp/x"#))
        #expect(m[3].value == .string("a\nb\tc"))
        #expect(m[4].value == .string("é가"))
        #expect(m[5].value == .string("😀"))
        #expect(m[6].value == .string("\u{01}"))
        // 다시 출력하면 꼭 필요한 것만 이스케이프 (한글 · 이모지는 그대로)
        #expect(JSONView.compact(node) ==
                #"{"name":"홍길동","quote":"say \"hi\"","path":"C:\\temp/x","nl":"a\nb\tc","u":"é가","emoji":"😀","ctl":"\u0001"}"#)
        // 짝 없는 서로게이트는 대체 문자
        #expect(JSONView.parse(#"["\ud83d"]"#) == .array([.string("\u{FFFD}")]))
        #expect(JSONView.parse(#"["\ude00x"]"#) == .array([.string("\u{FFFD}x")]))
        #expect(JSONView.parse(#"["\u12G4"]"#) == nil)
    }

    @Test func numbersKeepTheirText() {
        #expect(JSONView.parse("[0, -1, 3.14, 1E10, 2e-3, 12345678901234567890]") ==
                .array([.number("0"), .number("-1"), .number("3.14"), .number("1E10"), .number("2e-3"),
                        .number("12345678901234567890")]))
        #expect(JSONView.parse("[-]") == nil)
        #expect(JSONView.parse("[1e]") == nil)
    }

    @Test func deepNestingIsRejectedNotCrashing() {
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        #expect(JSONView.parse(deep) == nil)
        let ok = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        #expect(JSONView.parse(ok) != nil)
    }

    @Test func copyText() throws {
        #expect(JSONView.copyText(.string("A-77")) == "A-77")
        #expect(JSONView.copyText(.number("0.1")) == "0.1")
        #expect(JSONView.copyText(.null) == "null")
        #expect(JSONView.copyText(.array([.number("1")])) == "[\n  1\n]")
    }

    // MARK: - 경로

    @Test func paths() {
        #expect(JSONView.path([]) == "$")
        #expect(JSONView.path([.key("a"), .key("b"), .index(0), .key("c")]) == "$.a.b[0].c")
        #expect(JSONView.path([.key("order"), .key("items"), .index(0), .key("sku")]) == "$.order.items[0].sku")
        #expect(JSONView.path([.index(2)]) == "$[2]")
        #expect(JSONView.path([.key("key with space")]) == #"$["key with space"]"#)
        #expect(JSONView.path([.key("a-b"), .key("1st"), .key("")]) == #"$["a-b"]["1st"][""]"#)
        #expect(JSONView.path([.key(#"say "hi""#)]) == #"$["say \"hi\""]"#)
        #expect(JSONView.path([.key("_id"), .key("이름"), .key("v2")]) == "$._id.이름.v2")
    }

    // MARK: - 편집 경고

    @Test func invalidEditsInJSONColumns() {
        let table = TableMeta(name: "t", columns: [
            ColumnMeta(name: "id", columnType: "int", nullable: false, columnKey: "PRI"),
            ColumnMeta(name: "meta", columnType: "json", nullable: true),
            ColumnMeta(name: "note", columnType: "text", nullable: true),
            ColumnMeta(name: "memo", columnType: "text", nullable: true),
        ])
        let target = EditTarget(table: table, primaryKey: ["id"], columnMap: [0: "id", 1: "meta", 2: "note", 3: "memo"])
        let rows = [QueryResult.Row(id: 0, values: ["1", #"{"a":1}"#, #"{"b":2}"#, "plain"])]
        let columns = ["id", "meta", "note", "memo"]
        var edits = PendingEdits()
        edits.updates[0] = [1: #"{"a":"#, 2: "not json", 3: "{broken"]
        // meta: json 타입 · note: 원래 값이 JSON → 경고. memo: 원래 JSON 이 아니었으니 경고 없음
        #expect(JSONView.invalidEdits(edits, target: target, columns: columns, rows: rows) == ["meta", "note"])
        edits.updates[0] = [1: nil, 2: #"[1]"#]
        #expect(JSONView.invalidEdits(edits, target: target, columns: columns, rows: rows).isEmpty)
        // 새 행은 json 타입만
        edits.inserts = [[1: "oops", 2: "x"]]
        #expect(JSONView.invalidEdits(edits, target: target, columns: columns, rows: rows) == ["meta"])
        // 삭제 표시한 행은 보지 않는다
        edits = PendingEdits()
        edits.updates[0] = [1: "bad"]
        edits.deletes = [0]
        #expect(JSONView.invalidEdits(edits, target: target, columns: columns, rows: rows).isEmpty)
    }
}

extension JSONDetection {
    var isJSONValue: Bool {
        if case .json = self { return true }
        return false
    }
}
