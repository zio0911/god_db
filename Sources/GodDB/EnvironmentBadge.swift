import GodDBCore
import SwiftUI

extension ConnectionEnvironment {
    var color: Color {
        switch self {
        case .none: .secondary
        case .development: .green
        case .staging: .orange
        case .production: .red
        }
    }
}

/// 접속 환경 표시 (개발 · 스테이징 · 운영). 표시 안 함이면 아무것도 그리지 않는다.
struct EnvironmentBadge: View {
    let environment: ConnectionEnvironment

    var body: some View {
        if environment != .none {
            Text(environment.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(environment.color)
                .padding(.horizontal, 4)
                .background(environment.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
        }
    }
}
