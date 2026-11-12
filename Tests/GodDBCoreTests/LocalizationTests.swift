import Foundation
import Testing
@testable import GodDBCore

@Suite("Localization")
struct LocalizationTests {
    /// 소스의 tr("…") 문장을 모두 모은다 (Swift 문자열 이스케이프를 실제 문자로 바꿔서)
    static func sourceKeys() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let regex = try NSRegularExpression(pattern: #"\btr\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range(at: 1))
                keys.insert(raw.replacingOccurrences(of: #"\n"#, with: "\n")
                               .replacingOccurrences(of: #"\""#, with: "\"")
                               .replacingOccurrences(of: #"\\"#, with: "\\"))
            }
        }
        return keys
    }

    @Test func everyKeyHasEnglish() throws {
        let keys = try Self.sourceKeys()
        #expect(keys.count > 300)
        let missing = keys.filter { L10nEnglish.table[$0] == nil }.sorted()
        #expect(missing.isEmpty, "영어 번역이 없는 문장: \(missing)")
    }

    @Test func placeholdersMatch() {
        for (ko, en) in L10nEnglish.table {
            #expect(ko.components(separatedBy: "%@").count == en.components(separatedBy: "%@").count, "\(ko) → \(en)")
        }
    }

    @Test func englishTextHasNoHangul() {
        let hangul = try! NSRegularExpression(pattern: "[가-힣]")
        for (ko, en) in L10nEnglish.table {
            let r = NSRange(location: 0, length: (en as NSString).length)
            #expect(hangul.firstMatch(in: en, range: r) == nil, "\(ko) → \(en)")
        }
    }

    @Test func formatsArguments() {
        // GODDB_LANG=ko 로 실행되므로 한국어 그대로 + 인자 치환
        #expect(tr("%@행", "12") == "12행")
        #expect(L10nEnglish.table["%@행"].map { String(format: $0, "12") } == "12 rows")
    }
}
