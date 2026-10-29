// PaperLibrary 앱 아이콘(Resources/PaperLibrary/AppIcon.icns)을 그린다. 사용법: swift scripts/make-library-icon.swift
// PaperMark 아이콘과 같은 둥근 사각형에 바탕색만 바꾸고, 형광펜 색 책등이 꽂힌 책장을 그린다.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(in ctx: CGContext) {
    // 1024 기준 좌표. macOS 아이콘 격자: 824x824 바탕, 모서리 반지름 약 185.
    let base = CGRect(x: 100, y: 100, width: 824, height: 824)
    let basePath = CGPath(roundedRect: base, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28).cgColor)
    ctx.addPath(basePath)
    ctx.setFillColor(color(0x6FC3B2).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 바탕 그라데이션(민트 → 청록)
    ctx.saveGState()
    ctx.addPath(basePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x8FDDC4).cgColor, color(0x3E8FB0).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    ctx.restoreGState()

    // 책 선반
    let shelf = CGRect(x: 200, y: 250, width: 624, height: 34)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x10283A, 0.35).cgColor)
    ctx.addPath(CGPath(roundedRect: shelf, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.setFillColor(color(0x2F3447).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 책등. (왼쪽 x, 폭, 높이, 색). 색은 PaperMark 기본 형광펜 팔레트와 흰 종이.
    let books: [(CGFloat, CGFloat, CGFloat, UInt32)] = [
        (230, 96, 470, 0xFFFFFF),
        (338, 84, 400, 0xFFFBC5),
        (434, 104, 500, 0xF0CCDE),
        (550, 80, 430, 0xC1FFD9),
    ]
    for (x, width, height, hex) in books {
        let rect = CGRect(x: x, y: shelf.maxY, width: width, height: height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x10283A, 0.30).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.setFillColor(color(hex).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // 책등의 띠 두 줄
        for y in [rect.maxY - 70, rect.minY + 60] {
            let band = CGRect(x: rect.minX + 16, y: y, width: rect.width - 32, height: 14)
            ctx.addPath(CGPath(roundedRect: band, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.setFillColor(color(0x4A4F63, 0.45).cgColor)
            ctx.fillPath()
        }
    }

    // 오른쪽에 기대 놓은 책 한 권
    ctx.saveGState()
    ctx.translateBy(x: 650, y: shelf.maxY)
    ctx.rotate(by: -16 * .pi / 180)
    let leaning = CGRect(x: 0, y: 0, width: 96, height: 440)
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x10283A, 0.30).cgColor)
    ctx.addPath(CGPath(roundedRect: leaning, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(color(0xFFFFFF).cgColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    for y in [leaning.maxY - 70, leaning.minY + 60] {
        let band = CGRect(x: 16, y: y, width: leaning.width - 32, height: 14)
        ctx.addPath(CGPath(roundedRect: band, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.setFillColor(color(0x4A4F63, 0.45).cgColor)
        ctx.fillPath()
    }
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
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/PaperLibrary/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote Resources/PaperLibrary/AppIcon.icns" : "iconutil failed")
