import SwiftUI

/// SQL Server 아이콘: 주황 DB 원통 + 렌치 · 드라이버 (GodDB 자체 그림 — SQL Server 공식 로고는 쓰지 않는다)
struct MSSQLIcon: View {
    var size: CGFloat = 16

    static let body = Color(red: 1.0, green: 0.69, blue: 0.23)      // 주황
    static let shine = Color(red: 1.0, green: 0.84, blue: 0.55)     // 원통 밝은 띠
    static let top = Color(red: 0.84, green: 0.84, blue: 0.86)      // 윗면
    static let tool = Color(red: 0.24, green: 0.24, blue: 0.26)     // 도구

    var body: some View {
        ZStack(alignment: .topLeading) {
            Cylinder()
                .frame(width: size * 0.66, height: size * 0.78)
            // 원통 오른쪽 아래에 걸치는 렌치 · 드라이버 (겹치는 곳은 흰 테두리로 구분)
            ZStack {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: size * 0.46, weight: .black))
                    .foregroundStyle(.white)
                    .scaleEffect(1.2)
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(Self.tool)
            }
            .frame(width: size * 0.56, height: size * 0.56)
            .offset(x: size * 0.44, y: size * 0.44)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    /// 윗면 타원 + 몸통 + 아랫면 타원 + 밝은 띠
    private struct Cylinder: View {
        var body: some View {
            GeometryReader { g in
                let w = g.size.width, h = g.size.height, cap = h * 0.3
                ZStack(alignment: .top) {
                    Ellipse().fill(MSSQLIcon.body).frame(width: w, height: cap).offset(y: h - cap)
                    Rectangle().fill(MSSQLIcon.body).frame(width: w, height: h - cap).offset(y: cap / 2)
                    // 오른쪽 밝은 띠
                    Rectangle().fill(MSSQLIcon.shine)
                        .frame(width: w * 0.16, height: h - cap)
                        .offset(x: w * 0.24, y: cap / 2)
                    Ellipse().fill(MSSQLIcon.body).frame(width: w, height: cap)
                    Ellipse().fill(MSSQLIcon.top).frame(width: w * 0.8, height: cap * 0.62).offset(y: cap * 0.19)
                }
            }
        }
    }
}
