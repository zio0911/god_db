import Foundation
import Testing
@testable import GodDBCore

@Suite("Inline cell edit")
struct InlineCellEditTests {
    @Test func initialTextIsValueOrEmpty() {
        #expect(InlineCellEdit.initialText("kim") == "kim")
        #expect(InlineCellEdit.initialText(nil) == "")
        #expect(InlineCellEdit.initialText("") == "")
    }

    @Test func unchangedTextRecordsNothing() {
        #expect(InlineCellEdit.committedValue(original: "kim", text: "kim", finish: .commit) == nil)
        #expect(InlineCellEdit.committedValue(original: "kim", text: "kim", finish: .next) == nil)
        // NULL 칸을 열고 아무것도 안 쓰면 NULL 그대로 (빈 문자열로 바꾸지 않는다)
        #expect(InlineCellEdit.committedValue(original: nil, text: "", finish: .commit) == nil)
    }

    @Test func changedTextIsCommitted() {
        #expect(InlineCellEdit.committedValue(original: "kim", text: "lee", finish: .commit) == "lee")
        #expect(InlineCellEdit.committedValue(original: "kim", text: "lee", finish: .previous) == "lee")
        #expect(InlineCellEdit.committedValue(original: nil, text: "x", finish: .next) == "x")
        // 지우면 빈 문자열 (NULL 아님)
        #expect(InlineCellEdit.committedValue(original: "kim", text: "", finish: .commit) == "")
        // 바이너리 · JSON 도 글자 그대로
        #expect(InlineCellEdit.committedValue(original: "0x00", text: "0xFF", finish: .commit) == "0xFF")
        #expect(InlineCellEdit.committedValue(original: "{}", text: "{\"a\":1}", finish: .commit) == "{\"a\":1}")
    }

    @Test func cancelRecordsNothing() {
        #expect(InlineCellEdit.committedValue(original: "kim", text: "lee", finish: .cancel) == nil)
    }

    @Test func multilineValuesGoToPanel() {
        #expect(InlineCellEdit.canEditInline("one line"))
        #expect(InlineCellEdit.canEditInline(nil))
        #expect(!InlineCellEdit.canEditInline("a\nb"))
        #expect(!InlineCellEdit.canEditInline("a\r\nb"))
    }

    @Test func tabMovesWithinEditableColumns() {
        let editable = [3, 0, 1]   // 2 는 테이블 컬럼이 아님 (계산 컬럼 등)
        #expect(InlineCellEdit.neighbor(of: 0, editable: editable, finish: .next) == 1)
        #expect(InlineCellEdit.neighbor(of: 1, editable: editable, finish: .next) == 3)
        #expect(InlineCellEdit.neighbor(of: 3, editable: editable, finish: .next) == nil)
        #expect(InlineCellEdit.neighbor(of: 3, editable: editable, finish: .previous) == 1)
        #expect(InlineCellEdit.neighbor(of: 0, editable: editable, finish: .previous) == nil)
        #expect(InlineCellEdit.neighbor(of: 1, editable: editable, finish: .commit) == nil)
    }
}
