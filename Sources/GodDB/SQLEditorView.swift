import AppKit
import GodDBCore
import SwiftUI

/// 실행할 SQL 을 에디터에서 꺼내오기 위한 핸들.
@MainActor
final class EditorController {
    weak var textView: NSTextView?

    /// 선택 영역 (없으면 nil)
    func selectedSQL() -> String? {
        guard let tv = textView else { return nil }
        let sel = tv.selectedRange()
        guard sel.length > 0, let r = Range(sel, in: tv.string) else { return nil }
        let text = String(tv.string[r])
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// 선택 영역이 있으면 선택 영역, 없으면 커서가 위치한 구문. (실행 계획용)
    func sqlToRun() -> String? {
        guard let tv = textView else { return nil }
        let text = tv.string
        let sel = tv.selectedRange()
        if sel.length > 0, let r = Range(sel, in: text) {
            return String(text[r])
        }
        return SQLText.statement(in: text, at: sel.location)
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// 자동완성에 쓸 현재 스키마 (테이블, 뷰/프로시저)
    var schemaProvider: () -> ([TableMeta], [RoutineMeta]) = { ([], []) }

    static let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))

    /// 커서 앞에서 입력 중인 단어 범위와, 바로 앞의 `qualifier.` 를 찾는다.
    static func completionContext(in text: NSString, cursor: Int) -> (range: NSRange, qualifier: String?) {
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let u = UnicodeScalar(text.character(at: i)) else { return false }
            return wordChars.contains(u)
        }
        var start = cursor
        while isWord(start - 1) { start -= 1 }
        var qualifier: String? = nil
        if start > 0, text.character(at: start - 1) == UInt16(UInt8(ascii: ".")) {
            var qs = start - 1
            while isWord(qs - 1) { qs -= 1 }
            if qs < start - 1 { qualifier = text.substring(with: NSRange(location: qs, length: start - 1 - qs)) }
        }
        return (NSRange(location: start, length: cursor - start), qualifier)
    }

    func suggestions(for tv: NSTextView, range: NSRange) -> [String] {
        let text = tv.string as NSString
        let ctx = Self.completionContext(in: text, cursor: range.location + range.length)
        let prefix = text.substring(with: range)
        let cursor = range.location + range.length
        let upToCursor = text.substring(to: cursor)
        let statement = SQLText.statement(in: tv.string, at: cursor) ?? upToCursor
        // 별칭 해석은 구문 전체, "FROM 뒤인지" 판단은 커서 앞부분 기준
        let lastStmtStart = SQLText.statements(in: upToCursor).last?.range.lowerBound ?? 0
        let before = (upToCursor as NSString).substring(from: min(lastStmtStart, (upToCursor as NSString).length))
        let (tables, routines) = schemaProvider()
        var result = SQLCompleter.suggestions(prefix: prefix, qualifier: ctx.qualifier, statement: statement + "\n" + before,
                                              tables: tables, routines: routines)
        // "FROM 뒤" 판단을 위해 before 로 한 번 더 (테이블 우선 정렬)
        if ctx.qualifier == nil {
            let ordered = SQLCompleter.suggestions(prefix: prefix, qualifier: nil, statement: before,
                                                   tables: tables, routines: routines)
            let extra = result.filter { !ordered.contains($0) }
            result = ordered + extra
        }
        return result
    }
}

struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 로 직접 만든다 (INSERT 컬럼 힌트를 글자 위치에 그리기 위해)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let tv = HintTextView(frame: .zero, textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isEditable = true
        tv.isSelectable = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.tablesProvider = { [weak controller] in controller?.schemaProvider().0 ?? [] }
        scroll.documentView = tv
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.font = SQLHighlighter.font
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.backgroundColor = .textBackgroundColor
        tv.string = text
        SQLHighlighter.apply(to: tv)
        controller.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        controller.textView = tv
        if tv.string != text {
            tv.string = text
            SQLHighlighter.apply(to: tv)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        init(_ parent: SQLEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            SQLHighlighter.apply(to: tv)
        }

        /// Tab: 입력 중인 단어가 있으면 자동완성, 없으면 공백 4칸
        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertTab(_:)) else { return false }
            let sel = tv.selectedRange()
            guard sel.length == 0 else { return false }
            let ctx = EditorController.completionContext(in: tv.string as NSString, cursor: sel.location)
            guard ctx.range.length > 0 || ctx.qualifier != nil else {
                tv.insertText("    ", replacementRange: sel)
                return true
            }
            let candidates = parent.controller.suggestions(for: tv, range: ctx.range)
            switch candidates.count {
            case 0:
                NSSound.beep()
            case 1:
                tv.insertText(candidates[0], replacementRange: ctx.range)
            default:
                // 공통 접두어가 더 길면 먼저 채우고, 그래도 여러 개면 목록을 띄운다.
                let common = Self.commonPrefix(candidates)
                let typed = (tv.string as NSString).substring(with: ctx.range)
                if common.count > typed.count {
                    tv.insertText(common, replacementRange: ctx.range)
                } else {
                    tv.complete(nil)
                }
            }
            return true
        }

        func textView(_ tv: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            index?.pointee = 0
            return parent.controller.suggestions(for: tv, range: charRange)
        }

        static func commonPrefix(_ words: [String]) -> String {
            guard var prefix = words.first?.lowercased() else { return "" }
            for w in words.dropFirst() {
                let lw = w.lowercased()
                while !lw.hasPrefix(prefix) { prefix.removeLast() }
            }
            return String(words[0].prefix(prefix.count))
        }
    }
}

enum SQLHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private static let keywords = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "AS", "ON", "JOIN", "LEFT", "RIGHT",
        "INNER", "OUTER", "CROSS", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "ALTER", "DROP", "TABLE", "INDEX",
        "VIEW", "DATABASE", "SCHEMA", "PRIMARY", "KEY", "UNIQUE", "FOREIGN", "REFERENCES", "DEFAULT", "COLUMN",
        "ADD", "MODIFY", "CHANGE", "RENAME", "TRUNCATE", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "USE", "WITH",
        "CASE", "WHEN", "THEN", "ELSE", "END", "LIKE", "BETWEEN", "EXISTS", "ASC", "COUNT", "SUM", "AVG", "MIN",
        "MAX", "IFNULL", "COALESCE", "NOW", "TRUE", "FALSE", "AFTER", "FIRST", "COMMENT", "AUTO_INCREMENT",
    ]
    private static let keywordRegex = try! NSRegularExpression(
        pattern: "\\b(" + keywords.joined(separator: "|") + ")\\b", options: [.caseInsensitive])
    private static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
    private static let stringRegex = try! NSRegularExpression(pattern: "'(?:[^'\\\\]|\\\\.|'')*'|\"(?:[^\"\\\\]|\\\\.)*\"")
    private static let identRegex = try! NSRegularExpression(pattern: "`[^`]*`")
    private static let commentRegex = try! NSRegularExpression(pattern: "(--|#)[^\\n]*|/\\*[\\s\\S]*?\\*/")

    static func apply(to tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length < 300_000 else { return }   // 아주 큰 텍스트는 하이라이트 생략
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
        let color: [(NSRegularExpression, NSColor)] = [
            (keywordRegex, .systemBlue),
            (numberRegex, .systemPurple),
            (identRegex, .systemTeal),
            (stringRegex, .systemOrange),
            (commentRegex, .systemGray),
        ]
        for (regex, c) in color {
            regex.enumerateMatches(in: text, range: full) { m, _, _ in
                if let r = m?.range { storage.addAttribute(.foregroundColor, value: c, range: r) }
            }
        }
        (tv as? HintTextView)?.applyHints(storage)
        storage.endEditing()
        tv.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
    }
}

/// INSERT … VALUES 의 값 앞에 컬럼 이름을 회색으로 보여주는 편집기.
/// 글자 사이 간격(kern)만 벌리고 그 자리에 그리므로, 편집기 글자(실행하는 SQL)는 바뀌지 않는다.
final class HintTextView: NSTextView {
    var tablesProvider: () -> [TableMeta] = { [] }
    private(set) var hints: [InsertHints.Hint] = []
    static let hintFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let showHintsKey = "GodDB.editor.insertHints"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: showHintsKey) as? Bool ?? true
    }

    static func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: hintFont]).width + 10
    }

    /// 하이라이트 직후 (beginEditing 안에서) 호출된다.
    func applyHints(_ storage: NSTextStorage) {
        let s = storage.string as NSString
        hints = Self.enabled ? InsertHints.hints(in: storage.string, tables: tablesProvider()) : []
        // 바로 앞 글자가 줄바꿈이면 그 줄 첫 글자라 간격을 벌릴 수 없어 표시하지 않는다.
        hints = hints.filter { $0.location > 0 && s.character(at: $0.location - 1) != 0x0A }
        for h in hints {
            storage.addAttribute(.kern, value: Self.width(h.column), range: NSRange(location: h.location - 1, length: 1))
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !hints.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.hintFont, .foregroundColor: NSColor.secondaryLabelColor]
        let length = (string as NSString).length
        for h in hints where h.location < length {
            let glyph = lm.glyphIndexForCharacter(at: h.location)
            var rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            guard rect.intersects(dirtyRect.insetBy(dx: -200, dy: -20)) else { continue }
            let w = Self.width(h.column)
            let size = (h.column as NSString).size(withAttributes: attrs)
            let box = NSRect(x: rect.minX - w + 1, y: rect.midY - size.height / 2 - 1, width: w - 4, height: size.height + 2)
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            (h.column as NSString).draw(at: NSPoint(x: box.minX + 3, y: box.minY + 1), withAttributes: attrs)
        }
    }

    /// 복사할 때 간격(kern) 같은 서식이 따라가지 않도록 글자만 복사
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let r = selectedRange()
        guard r.length > 0 else { return false }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString((string as NSString).substring(with: r), forType: .string)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}
