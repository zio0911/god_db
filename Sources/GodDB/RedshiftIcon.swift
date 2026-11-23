import SwiftUI

/// Amazon Redshift 아이콘: 보라 원통 + 흰 띠 두 줄 (직접 그린 그림, AWS 로고 아님).
/// 데이터 웨어하우스(열 저장)를 나타낸다. 색은 AWS 분석 서비스 보라 계열.
struct RedshiftIcon: View {
    static let body = Color(red: 0x8C / 255, green: 0x4F / 255, blue: 0xFF / 255)   // 몸통
    static let bottom = Color(red: 0x5A / 255, green: 0x30 / 255, blue: 0xB5 / 255) // 아랫면
    static let top = Color(red: 0.75, green: 0.65, blue: 1.0)                         // 윗면

    var body: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            let w = g.size.width * 0.78, h = g.size.height * 0.9, cap = h * 0.28
            let x = (g.size.width - w) / 2, y = (g.size.height - h) / 2
            ZStack(alignment: .topLeading) {
                Ellipse().fill(Self.bottom).frame(width: w, height: cap).offset(x: x, y: y + h - cap)
                Rectangle().fill(Self.body).frame(width: w, height: h - cap).offset(x: x, y: y + cap / 2)
                // 몸통을 두르는 흰 띠 (앞쪽 반 타원)
                ForEach([0.42, 0.68], id: \.self) { t in
                    Ellipse().trim(from: 0.5, to: 1).rotation(.degrees(180))
                        .stroke(Color.white, lineWidth: max(1, size * 0.07))
                        .frame(width: w, height: cap).offset(x: x, y: y + h * t - cap / 2)
                }
                Ellipse().fill(Self.top).frame(width: w, height: cap).offset(x: x, y: y)
            }
        }
    }
}
