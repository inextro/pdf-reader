// 앱 아이콘(Resources/AppIcon.icns)을 그린다. 사용법: swift scripts/make-icon.swift
// 둥근 사각형 바탕 위에 형광펜이 칠해진 논문 한 장. 형광펜 색은 기본 팔레트(PDF Expert 색)를 쓴다.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(in ctx: CGContext) {
    // 1024 기준 좌표. macOS 아이콘 격자: 824x824 바탕, 모서리 반지름 약 185.
    let base = CGRect(x: 100, y: 100, width: 824, height: 824)
    let basePath = CGPath(roundedRect: base, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 바탕 그림자
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28).cgColor)
    ctx.addPath(basePath)
    ctx.setFillColor(color(0xB9A8F0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 바탕 그라데이션(라벤더 → 하늘)
    ctx.saveGState()
    ctx.addPath(basePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0xA98FE8).cgColor, color(0x7FB8F2).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    ctx.restoreGState()

    // 살짝 기운 종이 한 장
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: -6 * .pi / 180)
    let paper = CGRect(x: -235, y: -300, width: 470, height: 600)
    let fold: CGFloat = 110
    let paperPath = CGMutablePath()
    paperPath.move(to: CGPoint(x: paper.minX, y: paper.minY))
    paperPath.addLine(to: CGPoint(x: paper.maxX, y: paper.minY))
    paperPath.addLine(to: CGPoint(x: paper.maxX, y: paper.maxY - fold))
    paperPath.addLine(to: CGPoint(x: paper.maxX - fold, y: paper.maxY))
    paperPath.addLine(to: CGPoint(x: paper.minX, y: paper.maxY))
    paperPath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x1B1446, 0.30).cgColor)
    ctx.addPath(paperPath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 접힌 모서리
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: paper.maxX - fold, y: paper.maxY))
    flap.addLine(to: CGPoint(x: paper.maxX - fold, y: paper.maxY - fold))
    flap.addLine(to: CGPoint(x: paper.maxX, y: paper.maxY - fold))
    flap.closeSubpath()
    ctx.addPath(flap)
    ctx.setFillColor(color(0xDCE2F0).cgColor)
    ctx.fillPath()

    // 글줄과 형광펜. (y, 줄 길이 비율, 형광펜 색, 형광펜 시작·끝 비율)
    let lines: [(CGFloat, CGFloat, UInt32?, CGFloat, CGFloat)] = [
        (170, 0.62, nil, 0, 0),
        (95, 1.00, 0xF0CCDE, 0.05, 0.78),
        (20, 0.92, nil, 0, 0),
        (-55, 1.00, 0xFFFBC5, 0.30, 1.00),
        (-130, 0.96, 0xFFFBC5, 0.00, 0.55),
        (-205, 0.80, nil, 0, 0),
    ]
    let left = paper.minX + 60, width = paper.width - 120
    for (y, length, marker, from, to) in lines {
        let lineWidth = y > 140 ? width * length - fold * 0.6 : width * length
        if let marker {
            // 형광펜은 글줄보다 두껍게, 끝을 살짝 둥글게
            let r = CGRect(x: left + width * from - 8, y: y - 24, width: width * (to - from) + 16, height: 48)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.setFillColor(color(marker).blended(withFraction: 0.2, of: .black)!.cgColor)
            ctx.fillPath()
        }
        let bar = CGRect(x: left, y: y - 9, width: lineWidth, height: 18)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.setFillColor(color(0x4A4F63, 0.55).cgColor)
        ctx.fillPath()
    }
    ctx.restoreGState()

    // 오른쪽 아래에서 종이의 노란 형광펜 쪽으로 펜 끝을 댄 민트 형광펜
    ctx.saveGState()
    ctx.translateBy(x: 735, y: 290)
    ctx.rotate(by: 218 * .pi / 180)
    let body = CGRect(x: -48, y: -150, width: 96, height: 250)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x1B1446, 0.35).cgColor)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.setFillColor(color(0x2F3447).cgColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    let cap = CGRect(x: -48, y: 40, width: 96, height: 60)
    ctx.addPath(CGPath(roundedRect: cap, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(color(0xC1FFD9).blended(withFraction: 0.15, of: .black)!.cgColor)
    ctx.fillPath()
    let tip = CGMutablePath()
    tip.move(to: CGPoint(x: -40, y: -150))
    tip.addLine(to: CGPoint(x: 40, y: -150))
    tip.addLine(to: CGPoint(x: 22, y: -215))
    tip.addLine(to: CGPoint(x: -22, y: -200))
    tip.closeSubpath()
    ctx.addPath(tip)
    ctx.setFillColor(color(0xC1FFD9).blended(withFraction: 0.15, of: .black)!.cgColor)
    ctx.fillPath()
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
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
