import SwiftUI

/// 도구 막대: 자리가 넉넉하면 그대로, 모자라면 아이콘만(compact), 그래도 모자라면 가로 스크롤.
/// AI 패널을 열거나 이름이 길어도 버튼이 잘리지 않게 한다.
struct AdaptiveBar<Content: View>: View {
    @ViewBuilder let content: (_ compact: Bool) -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(false)
            content(true).labelStyle(.iconOnly)
            ScrollView(.horizontal, showsIndicators: false) {
                content(true).labelStyle(.iconOnly)
            }
        }
    }
}
