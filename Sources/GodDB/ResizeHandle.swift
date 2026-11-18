import GodDBCore
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

/// 끌어서 바꾼 화면 경계 크기 (UserDefaults 에 저장 — 탭을 새로 열거나 다시 켜도 그대로)
enum Layout {
    static let queryEditorHeight = "GodDB.layout.queryEditorHeight"
    static let rowDetailWidth = "GodDB.layout.rowDetailWidth"
    static let logHeight = "GodDB.layout.logHeight"
    static let logDetailWidth = "GodDB.layout.logDetailWidth"
    static let assistantWidth = "GodDB.layout.assistantWidth"
    static let diagramAIWidth = "GodDB.layout.diagramAIWidth"
    static let modelListWidth = "GodDB.layout.modelListWidth"
    static let modelEditorHeight = "GodDB.layout.modelEditorHeight"
    static let redisWorkbenchHeight = "GodDB.layout.redisWorkbenchHeight"

    static let all = [queryEditorHeight, rowDetailWidth, logHeight, logDetailWidth, assistantWidth,
                      diagramAIWidth, modelListWidth, modelEditorHeight, redisWorkbenchHeight]

    /// 메뉴 "레이아웃 초기화": 저장한 크기를 지워 처음 크기로
    @MainActor static func reset(_ app: AppState) {
        for k in all { UserDefaults.standard.removeObject(forKey: k) }
        app.assistant.width = 400
        app.log(.info, .app, tr("화면 레이아웃을 처음 크기로 되돌렸어요"))
    }
}

extension Binding where Value == Double {
    /// ResizeHandle 에 넘기기 위한 CGFloat 바인딩
    var cgFloat: Binding<CGFloat> {
        Binding<CGFloat>(get: { CGFloat(wrappedValue) }, set: { wrappedValue = Double($0) })
    }
}
