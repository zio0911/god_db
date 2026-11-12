import GodDBCore
import SwiftUI

/// 마우스를 올리면 배경이 생기고, 누르면 진해지며 살짝 작아지는 버튼.
/// 결과 영역처럼 작은 아이콘 버튼이 많은 곳에서 "눌렀다"는 느낌을 준다.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration)
    }
}

private struct HoverButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let active = isEnabled && hovering
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(isEnabled ? (active ? Color.accentColor : Color.primary) : Color.secondary.opacity(0.45))
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(configuration.isPressed && isEnabled ? 0.32 : (active ? 0.16 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(active ? 0.45 : 0), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.93 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerStyle(isEnabled ? .link : nil)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}

/// 누르면 클립보드에 복사하고 잠깐 "복사됨 ✓" 으로 바뀌는 버튼
struct CopyButton: View {
    let title: String
    var systemImage = "doc.on.doc"
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text())
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            Label(copied ? tr("복사됨") : title, systemImage: copied ? "checkmark.circle.fill" : systemImage)
                .foregroundStyle(copied ? Color.green : Color.primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.hover)
        .animation(.easeOut(duration: 0.15), value: copied)
    }
}
