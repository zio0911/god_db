import Foundation

/// 결과 표 칸을 그 자리에서 고칠 때의 규칙 (화면과 상관없는 부분)
public enum InlineCellEdit {
    /// 편집을 끝낸 방법
    public enum Finish: Equatable, Sendable {
        /// ↩ 또는 다른 곳 클릭: 값을 넣고 끝
        case commit
        /// Tab: 값을 넣고 같은 행 다음 칸으로
        case next
        /// ⇧Tab: 값을 넣고 같은 행 앞 칸으로
        case previous
        /// Esc: 넣지 않고 끝
        case cancel
    }

    /// 편집을 시작할 때 칸에 넣을 글자. NULL · (기본값) 칸은 빈 글자로 시작한다.
    public static func initialText(_ value: String?) -> String { value ?? "" }

    /// 그 자리에서 고칠 수 있는 값인지 (여러 줄 값은 한 줄 입력란에서 망가지므로 오른쪽 패널에서 고친다)
    public static func canEditInline(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.contains(where: \.isNewline)
    }

    /// 끝낼 때 기록할 값. 바꾸지 않았으면 nil (변경을 남기지 않는다).
    /// 빈 글자는 NULL 이 아니라 빈 문자열이다 (NULL 은 우클릭 "NULL 로 설정" 으로).
    public static func committedValue(original: String?, text: String, finish: Finish) -> String? {
        guard finish != .cancel, text != initialText(original) else { return nil }
        return text
    }

    /// Tab / ⇧Tab 으로 옮겨 갈 칸 (화면 순서의 편집 가능한 컬럼 중). 끝이면 nil.
    public static func neighbor(of column: Int, editable: [Int], finish: Finish) -> Int? {
        let sorted = editable.sorted()
        switch finish {
        case .next: return sorted.first { $0 > column }
        case .previous: return sorted.last { $0 < column }
        case .commit, .cancel: return nil
        }
    }
}
