import AppKit
import SwiftUI

/// NSSplitView(VSplitView/HSplitView) 대신 쓰는 드래그 경계선.
/// NavigationSplitView 안에서 AppKit 분할 뷰를 겹치면 사이드바 크기 조절이 꼬여서 직접 구현한다.
struct ResizeHandle: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    @Binding var size: CGFloat
    let range: ClosedRange<CGFloat>
    /// true 면 위/왼쪽으로 끌 때 size 가 커진다 (아래/오른쪽 패널을 조절하는 경우)
    var growsTowardStart = true

    @State private var startSize: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .padding(axis == .vertical ? .horizontal : .vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = startSize ?? size
                        if startSize == nil { startSize = size }
                        let delta = axis == .vertical ? value.translation.width : value.translation.height
                        let next = growsTowardStart ? base - delta : base + delta
                        size = min(max(next, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startSize = nil }
            )
    }
}
