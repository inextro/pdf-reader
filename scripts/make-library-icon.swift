// Quillo 앱 아이콘(Resources/PaperLibrary/AppIcon.icns)과 Chrome 확장 아이콘(Extension/Chrome/icons)을 그린다.
// 사용법: swift scripts/make-library-icon.swift
// 청록 둥근 사각형 위에, 위에서 비스듬히 내려다본 누운 남색 책과 그 위에 대각선으로 놓인 깃펜.
// 종이 사이로 형광펜 색(노랑·분홍) 책갈피가 늘어진다. 그림 전체를 가운데에 두고 1.22배로 키운다.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let shadowInk = color(0x10283A, 0.30).cgColor

func base(_ ctx: CGContext, _ top: UInt32 = 0x8FDDC4, _ bottom: UInt32 = 0x3E8FB0) {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28).cgColor)
    ctx.addPath(path); ctx.setFillColor(color(bottom).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [color(top).cgColor, color(bottom).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    ctx.restoreGState()
}

/// 깃펜. 펜촉 끝이 (0,0), 깃 끝이 (0,length) 방향. 호출하는 쪽에서 옮기고 돌린다.
/// 대(rachis)가 살짝 휘고, 깃 가장자리에 갈라진 틈이 몇 개 있다.
func quill(_ ctx: CGContext, length L: CGFloat, width w: CGFloat, vane: UInt32 = 0xFFFFFF, barbs: UInt32 = 0xC9DCE6,
           nib: UInt32 = 0x2F3447, shadow: Bool = true) {
    // 대의 중심선: 아래는 곧고 위로 갈수록 오른쪽으로 휜다.
    func spine(_ t: CGFloat) -> CGPoint { CGPoint(x: 0.10 * w * t * t, y: t * L) }
    let v = CGMutablePath()
    let startT: CGFloat = 0.24
    v.move(to: spine(startT))
    // 왼쪽 가장자리(넓다)
    v.addCurve(to: spine(1.0), control1: CGPoint(x: -0.95 * w, y: 0.40 * L), control2: CGPoint(x: -0.55 * w, y: 0.95 * L))
    // 오른쪽 가장자리(좁다)
    v.addCurve(to: spine(startT), control1: CGPoint(x: 0.55 * w, y: 0.90 * L), control2: CGPoint(x: 0.42 * w, y: 0.42 * L))
    v.closeSubpath()

    ctx.saveGState()
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: shadowInk) }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(v); ctx.setFillColor(color(vane).cgColor); ctx.fillPath()
    // 깃 결: 대에서 비스듬히 위로 뻗는 옅은 선
    ctx.saveGState()
    ctx.addPath(v); ctx.clip()
    ctx.setStrokeColor(color(barbs, 0.8).cgColor); ctx.setLineWidth(0.010 * L); ctx.setLineCap(.round)
    for t in stride(from: 0.34, through: 0.92, by: 0.075) {
        let p = spine(t)
        ctx.move(to: p); ctx.addLine(to: CGPoint(x: p.x - 1.2 * w, y: p.y + 0.16 * L))
        ctx.move(to: p); ctx.addLine(to: CGPoint(x: p.x + 1.0 * w, y: p.y + 0.18 * L))
    }
    ctx.strokePath()
    ctx.restoreGState()
    // 가장자리의 갈라진 틈: 바탕이 비치게 지운다.
    ctx.setBlendMode(.clear)
    ctx.setLineCap(.butt)
    for (t, side, len) in [(0.46, -1.0, 0.55), (0.70, -1.0, 0.45), (0.58, 1.0, 0.40)] as [(CGFloat, CGFloat, CGFloat)] {
        let p = spine(t)
        ctx.setLineWidth(0.016 * L)
        ctx.move(to: CGPoint(x: p.x + side * 0.12 * w, y: p.y + 0.02 * L))
        ctx.addLine(to: CGPoint(x: p.x + side * (0.12 + len * 1.4) * w, y: p.y + (0.02 + len * 0.22) * L))
        ctx.strokePath()
    }
    ctx.setBlendMode(.normal)
    // 대(rachis): 아래쪽 맨 대(quill)는 굵고 위로 갈수록 가늘다.
    let r = CGMutablePath()
    r.move(to: spine(0.08))
    for i in 1...20 { r.addLine(to: spine(0.08 + 0.90 * CGFloat(i) / 20)) }
    ctx.addPath(r); ctx.setStrokeColor(color(0x9FB3C0).cgColor); ctx.setLineWidth(0.022 * L); ctx.setLineCap(.round); ctx.strokePath()
    // 펜촉
    let n = CGMutablePath()
    n.move(to: .zero)
    n.addLine(to: CGPoint(x: -0.034 * L, y: 0.13 * L))
    n.addQuadCurve(to: CGPoint(x: 0.034 * L, y: 0.13 * L), control: CGPoint(x: 0, y: 0.15 * L))
    n.closeSubpath()
    ctx.addPath(n); ctx.setFillColor(color(nib).cgColor); ctx.fillPath()
    ctx.setStrokeColor(color(0xFFFFFF, 0.6).cgColor); ctx.setLineWidth(0.007 * L)
    ctx.move(to: CGPoint(x: 0, y: 0.02 * L)); ctx.addLine(to: CGPoint(x: 0, y: 0.10 * L)); ctx.strokePath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func placeQuill(_ ctx: CGContext, tip: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: tip.x, y: tip.y)
    ctx.rotate(by: angle * .pi / 180)
    quill(ctx, length: length, width: width)
    ctx.restoreGState()
}



func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
func mul(_ a: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { add(a, mul(CGPoint(x: b.x - a.x, y: b.y - a.y), t)) }

/// 모서리가 둥근 다각형
func roundedPoly(_ pts: [CGPoint], _ r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let n = pts.count
    p.move(to: lerp(pts[n - 1], pts[0], 0.5))
    for i in 0..<n { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: r) }
    p.closeSubpath()
    return p
}

/// 위에서 비스듬히 내려다본, 누워 있는 책. 표지 네 모서리 A(왼아래) B(오른아래) C(오른위) D(왼위), 두께는 아래로.
/// 책등은 A–D 쪽, 종이 단면은 A–B와 B–C 쪽에 보인다.
func lyingBook(_ ctx: CGContext, center: CGPoint, u: CGPoint, v: CGPoint, thickness: CGFloat,
               cover: UInt32, spine: UInt32, edge: UInt32, ribbons: [UInt32] = []) {
    let A = add(center, mul(add(u, v), -0.5)), B = add(A, u), C = add(B, v), D = add(A, v)
    let t = CGPoint(x: 0, y: -thickness)
    let board = CGPoint(x: 0, y: -thickness - 14)
    // 뒤표지(가장 아래 판)와 그림자
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: shadowInk)
    ctx.addPath(roundedPoly([add(A, board), add(B, board), add(C, board), add(C, mul(board, 0.3)), add(D, mul(board, 0.3)), D, A].map { $0 }, 22))
    ctx.setFillColor(color(edge).cgColor); ctx.fillPath()
    ctx.restoreGState()
    // 종이 단면(앞쪽 A–B, 오른쪽 B–C). 표지보다 조금 안쪽으로 들어가 있다.
    let inset: CGFloat = 0.03
    let a2 = lerp(A, B, inset), b2 = lerp(lerp(B, A, inset), lerp(C, D, inset), inset), c2 = lerp(C, B, inset)
    let pagesFront = [a2, b2, add(b2, t), add(a2, t)]
    let pagesSide = [b2, c2, add(c2, t), add(b2, t)]
    for face in [pagesFront, pagesSide] {
        ctx.addPath(roundedPoly(face, 6)); ctx.setFillColor(color(0xF4F1E8).cgColor); ctx.fillPath()
    }
    // 종이 결
    ctx.setStrokeColor(color(0xD8D1BE).cgColor); ctx.setLineWidth(4)
    for k in 1...3 {
        let f = CGFloat(k) / 4
        let o = mul(t, f)
        ctx.move(to: add(a2, o)); ctx.addLine(to: add(b2, o))
        ctx.move(to: add(b2, o)); ctx.addLine(to: add(c2, o))
    }
    ctx.strokePath()
    // 책갈피: 앞쪽 종이 사이로 늘어진다
    for (i, hex) in ribbons.enumerated() {
        let top = lerp(a2, b2, 0.55 + 0.14 * CGFloat(i))
        let r = CGMutablePath()
        let w = CGPoint(x: 34, y: -12)
        let drop = CGPoint(x: -8, y: -thickness - 70 + CGFloat(i) * 22)
        r.move(to: top); r.addLine(to: add(top, w)); r.addLine(to: add(add(top, w), drop))
        r.addLine(to: add(add(top, mul(w, 0.5)), add(drop, CGPoint(x: 0, y: 24)))); r.addLine(to: add(top, drop)); r.closeSubpath()
        ctx.addPath(r); ctx.setFillColor(color(hex).cgColor); ctx.fillPath()
    }
    // 앞표지
    let coverPath = roundedPoly([A, B, C, D], 26)
    ctx.addPath(coverPath); ctx.setFillColor(color(cover).cgColor); ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(coverPath); ctx.clip()
    // 책등 띠(A–D 쪽)
    let s1 = lerp(A, B, 0.15), s2 = lerp(D, C, 0.15)
    ctx.addPath(roundedPoly([add(A, CGPoint(x: -40, y: 0)), s1, s2, add(D, CGPoint(x: -40, y: 0))], 0))
    ctx.setFillColor(color(spine).cgColor); ctx.fillPath()
    ctx.setStrokeColor(color(0xFFFFFF, 0.14).cgColor); ctx.setLineWidth(8)
    ctx.move(to: lerp(A, B, 0.17)); ctx.addLine(to: lerp(D, C, 0.17)); ctx.strokePath()
    // 표지 가장자리 빛
    ctx.setStrokeColor(color(0xFFFFFF, 0.10).cgColor); ctx.setLineWidth(10)
    ctx.addPath(coverPath); ctx.strokePath()
    ctx.restoreGState()
}

func content(_ ctx: CGContext) {
    lyingBook(ctx, center: CGPoint(x: 500, y: 530), u: CGPoint(x: 330, y: -150), v: CGPoint(x: 170, y: 320),
              thickness: 64, cover: 0x2B3A5C, spine: 0x1F2A44, edge: 0x1F2A44, ribbons: [0xFFE066, 0xF6A5C8])
    placeQuill(ctx, tip: CGPoint(x: 640, y: 310), angle: 28, length: 600, width: 165)
}


/// 책과 깃펜이 차지하는 범위(그림자 제외, 1024 기준). 이 범위의 가운데를 아이콘 가운데에 둔다.
let artBounds = CGRect(x: 250, y: 224, width: 499, height: 623)
let artScale: CGFloat = 1.22

func drawIcon(in ctx: CGContext) {
    base(ctx)
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: artScale, y: artScale); ctx.translateBy(x: -artBounds.midX, y: -artBounds.midY)
    content(ctx)
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: ctx.cgContext)
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/PaperLibraryIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let extensionIcons = root.appendingPathComponent("Extension/Chrome/icons")
try FileManager.default.createDirectory(at: extensionIcons, withIntermediateDirectories: true)
for size in [16, 32, 48, 128] {
    try png(size: size).write(to: extensionIcons.appendingPathComponent("icon-\(size).png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/PaperLibrary/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote Resources/PaperLibrary/AppIcon.icns" : "iconutil failed")
