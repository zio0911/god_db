import Foundation

/// 기능 명세(FEATURES.md)의 "변경 이력" 절에서 버전별 변경 내용을 읽는다.
/// 릴리스 노트 창, 업데이트 목록(appcast) 설명, AI 어시스턴트의 "버전별 차이" 답변에 쓴다.
public enum ReleaseNotes {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var version: String
        /// "- " 로 시작하는 줄들 (Markdown)
        public var lines: [String]
        public var id: String { version }
    }

    public static func parse(_ markdown: String) -> [Entry] {
        var inLog = false
        var out: [Entry] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                inLog = line.contains("변경 이력") || line.lowercased().contains("changelog")
                continue
            }
            guard inLog else { continue }
            if line.hasPrefix("### ") {
                let v = String(line.dropFirst(4)).replacingOccurrences(of: "(개발 중)", with: "").trimmingCharacters(in: .whitespaces)
                out.append(Entry(version: v, lines: []))
            } else if !line.isEmpty, !out.isEmpty {
                out[out.count - 1].lines.append(line)
            }
        }
        return out.filter { !$0.lines.isEmpty }
    }

    /// a 보다 새롭고 b 이하인 버전들 (예: 1.0.0 → 1.1.0 사이 변경)
    public static func between(_ entries: [Entry], after old: String, upTo new: String) -> [Entry] {
        entries.filter { compare($0.version, old) == .orderedDescending && compare($0.version, new) != .orderedDescending }
    }

    /// 1.10.0 > 1.9.2 처럼 숫자로 비교
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// 업데이트 창(appcast description)용 간단한 HTML
    public static func html(_ entry: Entry) -> String {
        func inline(_ s: String) -> String {
            var t = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            t = t.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
            t = t.replacingOccurrences(of: "`(.+?)`", with: "<code>$1</code>", options: .regularExpression)
            return t
        }
        let items = entry.lines.map { l -> String in
            let text = l.hasPrefix("- ") ? String(l.dropFirst(2)) : l
            return "<li>\(inline(text))</li>"
        }.joined()
        return "<h3>GodDB \(entry.version)</h3><ul>\(items)</ul>"
    }
}
