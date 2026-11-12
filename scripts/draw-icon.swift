// GodDB 앱 아이콘 (채택: 2번 "후광 DB · 어두운 배경")
//   swift scripts/draw-icon.swift iconset Resources/AppIcon.iconset   → 모든 크기 PNG (iconutil 로 .icns 변환)
//   swift scripts/draw-icon.swift <1|2|3|4|sheet> <출력.png>            → 시안 다시 보기
import AppKit

let args = CommandLine.arguments
let variant = args.count > 1 ? args[1] : "1"
let out = args.count > 2 ? args[2] : "icon.png"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
var ctx: CGContext { NSGraphicsContext.current!.cgContext }

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

func background(_ top: NSColor, _ bottom: NSColor, angle: CGFloat = -90, border: NSColor? = nil) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    bottom.setFill(); squircle.fill()
    ctx.restoreGState()
    ctx.saveGState(); squircle.addClip()
    NSGradient(colors: [top, bottom])!.draw(in: body, angle: angle)
    ctx.restoreGState()
    if let border {
        border.setStroke(); squircle.lineWidth = 3; squircle.stroke()
    }
}

/// 입체 원통 (단 수, 옆면 좌우 명암)
func cylinder(cx: CGFloat, bottom: CGFloat, width cw: CGFloat, tiers: Int, tier: CGFloat,
              side: [NSColor], top: [NSColor], groove: NSColor, shadow: Bool = true) -> CGFloat {
    let eh = cw * 0.28
    func oval(_ y: CGFloat) -> CGRect { CGRect(x: cx - cw / 2, y: y - eh / 2, width: cw, height: eh) }
    let height = CGFloat(tiers) * tier
    let topY = bottom + height
    let sidePath = NSBezierPath(rect: CGRect(x: cx - cw / 2, y: bottom, width: cw, height: height))
    sidePath.append(NSBezierPath(ovalIn: oval(bottom)))
    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        side[1].setFill(); sidePath.fill()
        ctx.restoreGState()
    }
    ctx.saveGState(); sidePath.addClip()
    NSGradient(colors: side, atLocations: [0, 0.45, 1], colorSpace: .deviceRGB)!
        .draw(in: CGRect(x: cx - cw / 2, y: bottom - eh, width: cw, height: height + eh * 2), angle: 0)
    ctx.restoreGState()
    groove.setStroke()
    for i in 1..<tiers {
        let y = bottom + CGFloat(i) * tier
        let arc = NSBezierPath()
        arc.appendArc(withCenter: CGPoint(x: cx, y: y), radius: cw / 2, startAngle: 180, endAngle: 360)
        var tr = AffineTransform(); tr.translate(x: 0, y: y); tr.scale(x: 1, y: eh / cw); tr.translate(x: 0, y: -y)
        arc.transform(using: tr); arc.lineWidth = cw * 0.022; arc.stroke()
    }
    ctx.saveGState()
    NSBezierPath(ovalIn: oval(topY)).addClip()
    NSGradient(colors: top)!.draw(in: oval(topY), angle: -90)
    ctx.restoreGState()
    return topY
}

/// 떠 있는 금색 후광 (아래 반쪽은 원통 뒤로, 위 반쪽은 앞으로 보이게 두 번 나눠 그림)
func halo(cx: CGFloat, y: CGFloat, width w: CGFloat, thickness: CGFloat, front: Bool) {
    let h = w * 0.3
    let rect = CGRect(x: cx - w / 2, y: y - h / 2, width: w, height: h)
    let ring = CGMutablePath()
    ring.addEllipse(in: rect)
    let stroked = ring.copy(strokingWithWidth: thickness, lineCap: .round, lineJoin: .round, miterLimit: 1)
    ctx.saveGState()
    // 앞쪽(아래 반) 또는 뒤쪽(위 반)만
    ctx.clip(to: front ? CGRect(x: 0, y: 0, width: 1024, height: y) : CGRect(x: 0, y: y, width: 1024, height: 1024))
    ctx.setShadow(offset: .zero, blur: 40, color: rgb(255, 205, 80, 0.85).cgColor)
    ctx.addPath(stroked); ctx.setFillColor(rgb(255, 200, 60).cgColor); ctx.fillPath()
    ctx.addPath(stroked); ctx.clip()
    NSGradient(colors: [rgb(255, 248, 205), rgb(255, 210, 70), rgb(230, 140, 10)])!
        .draw(in: rect.insetBy(dx: -thickness, dy: -thickness), angle: -90)
    ctx.restoreGState()
}

func sparkle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: NSColor) {
    let p = NSBezierPath(), k: CGFloat = 0.13
    p.move(to: CGPoint(x: x, y: y + r))
    p.curve(to: CGPoint(x: x + r, y: y), controlPoint1: CGPoint(x: x + r * k, y: y + r * k), controlPoint2: CGPoint(x: x + r * k, y: y + r * k))
    p.curve(to: CGPoint(x: x, y: y - r), controlPoint1: CGPoint(x: x + r * k, y: y - r * k), controlPoint2: CGPoint(x: x + r * k, y: y - r * k))
    p.curve(to: CGPoint(x: x - r, y: y), controlPoint1: CGPoint(x: x - r * k, y: y - r * k), controlPoint2: CGPoint(x: x - r * k, y: y - r * k))
    p.curve(to: CGPoint(x: x, y: y + r), controlPoint1: CGPoint(x: x - r * k, y: y + r * k), controlPoint2: CGPoint(x: x - r * k, y: y + r * k))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: r * 0.6, color: c.withAlphaComponent(0.9).cgColor)
    c.setFill(); p.fill()
    ctx.restoreGState()
}

// 1. 후광 DB (밝은 배경): 남색 원통 위에 금색 후광
func design1() {
    background(rgb(250, 251, 255), rgb(218, 226, 245), border: rgb(255, 255, 255, 0.8))
    let haloY: CGFloat = 742
    halo(cx: 512, y: haloY, width: 330, thickness: 30, front: false)
    _ = cylinder(cx: 512, bottom: 250, width: 420, tiers: 3, tier: 120,
                 side: [rgb(44, 52, 120), rgb(78, 92, 200), rgb(36, 42, 100)],
                 top: [rgb(130, 145, 240), rgb(96, 110, 220)], groove: rgb(170, 185, 255, 0.55))
    halo(cx: 512, y: haloY, width: 330, thickness: 30, front: true)
}

// 2. 후광 DB (어두운 배경): 흰 원통 + 빛나는 후광 + 별
func design2() {
    background(rgb(40, 46, 88), rgb(10, 12, 28))
    ctx.saveGState(); squircle.addClip()
    NSGradient(colors: [rgb(255, 210, 90, 0.28), rgb(255, 210, 90, 0)])!
        .draw(fromCenter: CGPoint(x: 512, y: 740), radius: 0, toCenter: CGPoint(x: 512, y: 740), radius: 360, options: [])
    ctx.restoreGState()
    let haloY: CGFloat = 742
    halo(cx: 512, y: haloY, width: 330, thickness: 30, front: false)
    _ = cylinder(cx: 512, bottom: 250, width: 420, tiers: 3, tier: 120,
                 side: [rgb(200, 208, 235), rgb(250, 251, 255), rgb(180, 188, 220)],
                 top: [rgb(255, 255, 255), rgb(226, 232, 250)], groove: rgb(120, 132, 180, 0.45))
    halo(cx: 512, y: haloY, width: 330, thickness: 30, front: true)
    sparkle(300, 820, 34, rgb(255, 236, 160))
    sparkle(745, 600, 24, .white)
    sparkle(270, 470, 18, .white)
}

// 3. 날개 달린 DB: 파란 배경, 흰 날개
func wing(_ cx: CGFloat, _ cy: CGFloat, flip: Bool) {
    let s: CGFloat = flip ? -1 : 1
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy); ctx.scaleBy(x: s, y: 1)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    for (i, len) in [CGFloat(185), 152, 118].enumerated() {
        let y = CGFloat(i) * -58
        let f = NSBezierPath()
        f.move(to: CGPoint(x: 0, y: y + 30))
        f.curve(to: CGPoint(x: len, y: y + 110 - CGFloat(i) * 20), controlPoint1: CGPoint(x: len * 0.35, y: y + 80),
                controlPoint2: CGPoint(x: len * 0.75, y: y + 130 - CGFloat(i) * 20))
        f.curve(to: CGPoint(x: 0, y: y - 30), controlPoint1: CGPoint(x: len * 0.8, y: y + 20),
                controlPoint2: CGPoint(x: len * 0.4, y: y - 30))
        f.close()
        (i == 0 ? NSColor.white : rgb(238, 243, 255)).setFill(); f.fill()
    }
    ctx.restoreGState()
}
func design3() {
    background(rgb(74, 144, 255), rgb(40, 70, 210))
    wing(512 - 175, 560, flip: true)
    wing(512 + 175, 560, flip: false)
    let top = cylinder(cx: 512, bottom: 255, width: 350, tiers: 3, tier: 105,
                       side: [rgb(210, 218, 240), rgb(255, 255, 255), rgb(196, 205, 232)],
                       top: [rgb(255, 255, 255), rgb(228, 234, 252)], groove: rgb(90, 120, 210, 0.4))
    halo(cx: 512, y: top + 120, width: 230, thickness: 22, front: false)
    halo(cx: 512, y: top + 120, width: 230, thickness: 22, front: true)
}

// 4. G 모노그램: 굵은 G 를 가로로 잘라 디스크 세 장처럼
func design4() {
    background(rgb(30, 30, 46), rgb(12, 12, 20))
    let size: CGFloat = 640
    var font = NSFont.systemFont(ofSize: size, weight: .black)
    if let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: size) ?? font }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "G", attributes: [.font: font]))
    let path = CGMutablePath()
    for run in (CTLineGetGlyphRuns(line) as! [CTRun]) {
        var g = CGGlyph(), p = CGPoint.zero
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &g)
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &p)
        let rf = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        if let gp = CTFontCreatePathForGlyph(rf, g, nil) { path.addPath(gp, transform: CGAffineTransform(translationX: p.x, y: p.y)) }
    }
    let box = path.boundingBoxOfPath
    var move = CGAffineTransform(translationX: 512 - box.midX, y: 512 - box.midY)
    let placed = path.copy(using: &move)!
    let pb = placed.boundingBoxOfPath
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 50, color: rgb(255, 200, 70, 0.55).cgColor)
    ctx.addPath(placed); ctx.setFillColor(rgb(255, 196, 50).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(placed); ctx.clip()
    NSGradient(colors: [rgb(255, 244, 190), rgb(255, 206, 70), rgb(225, 130, 10)])!.draw(in: pb, angle: -90)
    // 디스크 사이 홈 (원통 단처럼 살짝 휜 선)
    for i in 1..<3 {
        let y = pb.minY + pb.height * CGFloat(i) / 3
        let arc = NSBezierPath()
        arc.move(to: CGPoint(x: pb.minX - 20, y: y + 22))
        arc.curve(to: CGPoint(x: pb.maxX + 20, y: y + 22), controlPoint1: CGPoint(x: pb.minX + pb.width * 0.3, y: y - 30),
                  controlPoint2: CGPoint(x: pb.minX + pb.width * 0.7, y: y - 30))
        rgb(20, 20, 32).setStroke(); arc.lineWidth = 26; arc.stroke()
    }
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.4), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: pb.minX, y: pb.midY + pb.height * 0.2, width: pb.width, height: pb.height * 0.3), angle: -90)
    ctx.restoreGState()
    sparkle(pb.maxX - 10, pb.maxY - 20, 40, rgb(255, 240, 170))
}

func render(_ v: String, px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    switch v { case "1": design1(); case "2": design2(); case "3": design3(); default: design4() }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

if variant == "iconset" {
    // macOS 아이콘 세트: 크기마다 직접 그려서 작은 크기도 선명하게
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try! render("2", px: px).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
        }
    }
    print("saved: \(out)")
    exit(0)
}

if variant == "sheet" {
    let labels = ["1  후광 DB · 밝은 배경", "2  후광 DB · 어두운 배경", "3  날개 달린 DB", "4  G 모노그램"]
    let cell = 460, pad = 30, w = cell * 4 + pad * 5, h = cell + 200
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    rgb(242, 242, 247).setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: w, height: h)).fill()
    for i in 0..<4 {
        let x = pad + i * (cell + pad)
        let big = NSImage(size: NSSize(width: 1024, height: 1024)); big.addRepresentation(render("\(i + 1)", px: 1024))
        big.draw(in: CGRect(x: x, y: 170, width: cell, height: cell))
        // Dock 크기 미리보기 (64px)
        let small = NSImage(size: NSSize(width: 64, height: 64)); small.addRepresentation(render("\(i + 1)", px: 128))
        small.draw(in: CGRect(x: x + cell / 2 - 32, y: 90, width: 64, height: 64))
        let s = NSAttributedString(string: labels[i], attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.darkGray])
        s.draw(at: CGPoint(x: CGFloat(x) + (CGFloat(cell) - s.size().width) / 2, y: 30))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
} else {
    try! render(variant, px: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}
print("saved: \(out)")
