import CoreGraphics
import Testing
@testable import GodDBCore

@Suite("SVG path")
struct SVGPathTests {
    @Test func basicCommands() {
        let p = SVGPath.parse("M2 2h20v20H2z")
        #expect(p.boundingBoxOfPath == CGRect(x: 2, y: 2, width: 20, height: 20))
    }

    @Test func compactNumbersRelativeAndArc() {
        // ".5.5" 같은 붙은 숫자, 상대 좌표, 플래그가 붙은 호 ("a1 1 0 011 1")
        let p = SVGPath.parse("M0 0l.5.5a1 1 0 011 1c-.5 0-1-.5-1-1z")
        let b = p.boundingBoxOfPath
        #expect(!p.isEmpty)
        #expect(b.minX >= -0.01 && b.maxX <= 2.6 && b.minY >= -0.01 && b.maxY <= 2.6, "\(b)")
    }

    @Test func fullCircleArcStaysInBounds() {
        let p = SVGPath.parse("M12 2a10 10 0 1 0 0.0001 0z")
        let b = p.boundingBoxOfPath
        #expect(abs(b.width - 20) < 0.5 && abs(b.height - 20) < 0.5, "\(b)")
    }
}
