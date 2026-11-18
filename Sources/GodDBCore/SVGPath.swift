import CoreGraphics
import Foundation

/// SVG `<path d="…">` 를 CGPath 로 바꾼다 (브랜드 로고를 이미지 파일 없이 그리기 위해).
/// 지원: M L H V C S Q T A Z (대·소문자). 좌표계는 SVG 그대로 (y 가 아래로).
public enum SVGPath {
    public static func parse(_ d: String) -> CGPath {
        var scanner = Tokens(d)
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?   // S / T 에서 반사할 직전 제어점
        var lastCommand: Character = " "
        var command: Character = " "

        while let c = scanner.nextCommandOrNil(implicit: command) {
            command = c
            let relative = c.isLowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch c.uppercased().first! {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y); start = current
                path.move(to: current)
                lastControl = nil
                // M 다음에 이어지는 좌표쌍은 L 로 본다
                command = relative ? "l" : "L"
            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y); path.addLine(to: current); lastControl = nil
            case "H":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y); path.addLine(to: current); lastControl = nil
            case "V":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y); path.addLine(to: current); lastControl = nil
            case "C":
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                      let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = pt(x1, y1), c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; current = end
            case "S":
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = "CcSs".contains(lastCommand) ? reflect(lastControl, about: current) : current
                let c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; current = end
            case "Q":
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = pt(x1, y1), end = pt(x, y)
                path.addQuadCurve(to: end, control: c1)
                lastControl = c1; current = end
            case "T":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = "QqTt".contains(lastCommand) ? reflect(lastControl, about: current) : current
                let end = pt(x, y)
                path.addQuadCurve(to: end, control: c1)
                lastControl = c1; current = end
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rot = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = pt(x, y)
                addArc(path, from: current, to: end, rx: rx, ry: ry, rotation: rot, largeArc: large, sweep: sweep)
                current = end; lastControl = nil
            case "Z":
                path.closeSubpath(); current = start; lastControl = nil
            default:
                return path
            }
            lastCommand = c
        }
        return path
    }

    private static func reflect(_ p: CGPoint?, about c: CGPoint) -> CGPoint {
        guard let p else { return c }
        return CGPoint(x: 2 * c.x - p.x, y: 2 * c.y - p.y)
    }

    /// SVG 타원 호 → 베지어 (SVG 명세 F.6 의 끝점 → 중심 변환)
    private static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
                               rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        // 90도 이하 조각으로 나눠 베지어로
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        var a = theta1
        func point(_ ang: CGFloat) -> CGPoint {
            let ex = rx * cos(ang), ey = ry * sin(ang)
            return CGPoint(x: cosP * ex - sinP * ey + cx, y: sinP * ex + cosP * ey + cy)
        }
        func deriv(_ ang: CGFloat) -> CGPoint {
            let ex = -rx * sin(ang), ey = ry * cos(ang)
            return CGPoint(x: cosP * ex - sinP * ey, y: sinP * ex + cosP * ey)
        }
        for i in 0..<segments {
            let b = a + step
            let pa = point(a), pb = i == segments - 1 ? p1 : point(b)
            let da = deriv(a), db = deriv(b)
            path.addCurve(to: pb,
                          control1: CGPoint(x: pa.x + t * da.x, y: pa.y + t * da.y),
                          control2: CGPoint(x: pb.x - t * db.x, y: pb.y - t * db.y))
            a = b
        }
    }

    /// 숫자 · 명령 글자 읽기 (".5.5", "-1-2", "1e-3" 같은 붙은 형식 포함)
    struct Tokens {
        private let chars: [Character]
        private var i = 0
        init(_ s: String) { chars = Array(s) }

        private mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" { i += 1 }
        }

        /// 다음이 명령 글자면 그것, 숫자면 직전 명령을 되풀이 (implicit), 끝이면 nil
        mutating func nextCommandOrNil(implicit: Character) -> Character? {
            skipSeparators()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c.isLetter, c != "e", c != "E" { i += 1; return c }
            return implicit == " " ? nil : implicit
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var s = "", seenDot = false, seenExp = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { s.append(c) }
                else if (c == "-" || c == "+") && (s.isEmpty || s.last == "e" || s.last == "E") { s.append(c) }
                else if c == "." && !seenDot && !seenExp { seenDot = true; s.append(c) }
                else if (c == "e" || c == "E") && !seenExp && !s.isEmpty { seenExp = true; s.append(c) }
                else { break }
                i += 1
            }
            return Double(s).map { CGFloat($0) }
        }

        /// 호의 플래그는 "0" / "1" 한 글자 (구분자 없이 붙을 수 있음)
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }
    }
}
