import Foundation

/// AI 어시스턴트가 "이 앱" 에 대한 질문(누가 만들었나, 사용법, 단축키…)에 답할 수 있게
/// 기능 명세(docs/FEATURES.md) 에서 질문과 관련된 절을 골라 문맥으로 붙인다.
public struct AppGuide: Sendable {
    public struct Section: Sendable, Equatable {
        public var title: String
        public var body: String
    }

    public static let about = """
    GodDB is a free, open-source (MIT license) native macOS database client written in Swift/SwiftUI.
    Author: zio0911 (GitHub). Source and releases: https://github.com/zio0911/god_db
    Supports MySQL 5.7/8.x, PostgreSQL 12+, SQL Server 2016+, Redis 6+. Local Ollama is used for AI (query tuning,
    diagram/modeling AI and this assistant); nothing is sent to external servers and row data is never shared with AI.
    Main modes (top segment): 쿼리 (query editor), 스키마 비교 (schema compare), 모델링 (data modeling).
    """

    public let sections: [Section]

    public init(markdown: String) {
        sections = Self.parse(markdown)
    }

    /// `## ` 단위로 자른다. 변경 이력·목차는 빼고, 코드 블록 안의 `##` 는 무시한다.
    static func parse(_ md: String) -> [Section] {
        var out: [Section] = []
        var title: String?
        var body: [Substring] = []
        var inCode = false
        func flush() {
            if let t = title, !skip(t) {
                out.append(Section(title: t, body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            body = []
        }
        for line in md.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { inCode.toggle() }
            if !inCode, line.hasPrefix("## ") {
                flush()
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if title != nil {
                body.append(line)
            }
        }
        flush()
        return out
    }

    static func skip(_ title: String) -> Bool {
        title.contains("목차") || title.contains("변경 이력")
    }

    /// 짧은 개요: 절 제목 목록 + 단축키 절
    public var overview: String {
        var s = "Feature sections of the GodDB manual: " + sections.map(\.title).joined(separator: " / ") + "\n"
        if let keys = sections.first(where: { $0.title.contains("단축키") }) {
            s += "\n## \(keys.title)\n\(keys.body)\n"
        }
        return s
    }

    /// 질문과 관련 있는 절 (점수 순, 글자 수 제한)
    public func relevant(to question: String, limit: Int = 3, maxChars: Int = 9_000) -> [Section] {
        let words = Self.keywords(question)
        guard !words.isEmpty else { return [] }
        let scored: [(Section, Int)] = sections.map { sec in
            let t = sec.title.lowercased(), b = sec.body.lowercased()
            var score = 0
            for w in words {
                if t.contains(w) { score += 6 }
                score += min(b.components(separatedBy: w).count - 1, 4)
            }
            return (sec, score)
        }
        var out: [Section] = []
        var total = 0
        for (sec, score) in scored.filter({ $0.1 >= 3 }).sorted(by: { $0.1 > $1.1 }).prefix(limit) {
            var s = sec
            if s.body.count > maxChars - total { s.body = String(s.body.prefix(max(0, maxChars - total))) + "\n…" }
            out.append(s)
            total += s.body.count
            if total >= maxChars { break }
        }
        return out
    }

    /// 질문에서 뜻 있는 낱말만 (조사·흔한 말 제거)
    static func keywords(_ q: String) -> [String] {
        let stop: Set<String> = ["알려줘", "알려", "주세요", "해줘", "어떻게", "방법", "사용", "사용법", "사용방법", "뭐야", "뭐", "이거",
                                 "그거", "있어", "있나", "하나", "하는", "하려면", "되나", "돼", "좀", "기능", "앱", "the", "how", "what",
                                 "use", "can", "does", "is", "a", "to", "do", "in", "i", "goddb", "갓디비"]
        let particles = ["에서는", "에서", "으로", "에게", "하고", "까지", "부터", "는", "은", "이", "가", "을", "를", "에", "로", "와", "과", "도", "의", "만"]
        var out: [String] = []
        for raw in q.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            var w = String(raw)
            for p in particles where w.count > p.count + 1 && w.hasSuffix(p) { w.removeLast(p.count); break }
            if w.count >= 2, !stop.contains(w), !out.contains(w) { out.append(w) }
        }
        return out
    }

    /// 어시스턴트 문맥에 붙일 글
    public func contextText(question: String, appState: String) -> String {
        var s = "About this app:\n" + Self.about + "\nCurrent app state:\n" + appState + "\n"
        let rel = relevant(to: question)
        if rel.isEmpty {
            s += "\n" + overview
        } else {
            s += "\nManual sections related to the question:\n"
            for sec in rel { s += "\n## \(sec.title)\n\(sec.body)\n" }
            s += "\n(Other sections: " + sections.map(\.title).joined(separator: " / ") + ")\n"
        }
        return s
    }
}
