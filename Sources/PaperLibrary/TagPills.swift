import AppKit

/// 태그 색. 읽기 상태 태그는 정해 둔 색, 나머지는 태그 이름으로 정하므로 같은 태그는 어디서나, 앱을 다시 켜도 같은 색이다.
enum TagColor {
    /// 띄어쓰기·대소문자를 무시한 이름 → 색.
    private static let fixed: [String: NSColor] = [
        "todo": .systemBlue, "completed": .systemGreen, "verified": .systemPurple,
        "inprogress": .systemYellow, "inprocess": .systemYellow,
    ]

    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal,
        .systemIndigo, .systemRed, .systemBrown, .systemMint, .systemCyan, .systemYellow,
    ]

    static func color(for tag: String) -> NSColor {
        let name = displayName(tag).lowercased().filter { $0.isLetter }
        if let color = fixed[name] { return color }
        // String.hashValue는 실행마다 바뀌므로 FNV-1a를 쓴다.
        var hash: UInt32 = 2_166_136_261
        for byte in displayName(tag).lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return palette[Int(hash % UInt32(palette.count))]
    }

    /// 알약의 채움·테두리 진하기. 사이드바 태그 아이콘도 같은 값으로 그려 색을 맞춘다.
    static let fillAlpha: CGFloat = 0.22
    static let strokeAlpha: CGFloat = 0.55

    /// 사이드바의 태그 아이콘: 알약처럼 옅게 채우고 조금 진한 테두리를 두른 태그 모양.
    /// 사이드바 바탕은 회색이라 반투명으로 그리면 흐려지므로, 알약이 표(흰 바탕) 위에서 보이는 색을 불투명하게 쓴다.
    static func icon(for tag: String, pointSize: CGFloat) -> NSImage? {
        let color = color(for: tag)
        let size = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        func symbol(_ name: String, _ alpha: CGFloat) -> NSImage? {
            let shown = NSColor(name: nil) { appearance in
                var base = NSColor.white
                appearance.performAsCurrentDrawingAppearance { base = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .white }
                return base.blended(withFraction: alpha, of: color) ?? color
            }
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(size.applying(.init(paletteColors: [shown])))
        }
        guard let fill = symbol("tag.fill", fillAlpha), let outline = symbol("tag", strokeAlpha) else { return nil }
        return NSImage(size: outline.size, flipped: false) { rect in
            fill.draw(in: rect)
            outline.draw(in: rect)
            return true
        }
    }

    /// 보이는 이름. Zotero에서 위로 올리려고 붙인 앞의 "/"를 뗀다("/To Do" → "To Do").
    static func displayName(_ tag: String) -> String {
        let name = tag.drop { $0 == "/" }.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? tag : name
    }
}

/// 태그를 색 알약으로 그린다. wraps면 폭에 맞춰 줄을 바꾸고(정보 패널), 아니면 한 줄에서 넘치는 것은 잘린다(표).
final class TagPillsView: NSView {
    var tags: [String] = [] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var wraps = true
    private let font = NSFont.systemFont(ofSize: Style.fontSize - 2, weight: .medium)
    private let padding = NSSize(width: 8, height: 3)
    private let gap: CGFloat = 5
    private var laidOutWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // macOS 14부터 NSView는 기본으로 밖까지 그린다. 좁은 열에서 옆 칸을 덮지 않게 자른다.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var pillHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + padding.height * 2 }

    private func frames(width: CGFloat) -> [NSRect] {
        var frames: [NSRect] = []
        var x: CGFloat = 0, y: CGFloat = 0
        for tag in tags {
            let w = ceil((TagColor.displayName(tag) as NSString).size(withAttributes: [.font: font]).width) + padding.width * 2
            if wraps, x > 0, x + w > width { x = 0; y += pillHeight + gap }
            frames.append(NSRect(x: x, y: y, width: w, height: pillHeight))
            x += w + gap
        }
        return frames
    }

    override var intrinsicContentSize: NSSize {
        guard wraps else { return NSSize(width: NSView.noIntrinsicMetric, height: pillHeight) }
        let height = frames(width: bounds.width).last?.maxY ?? 0
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        // 폭이 정해진 뒤에야 몇 줄인지 안다.
        if wraps, bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 열 폭을 끄는 동안에도 새 폭에 맞춰 다시 그린다(예전 그림이 늘어나 남지 않게).
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let top = wraps ? 0 : floor((bounds.height - pillHeight) / 2)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let minWidth = padding.width * 2 + 16
        for (index, (tag, frame)) in zip(tags, frames(width: bounds.width)).enumerated() {
            var rect = frame.offsetBy(dx: 0, dy: top).insetBy(dx: 0.5, dy: 0.5)
            // 자리가 모자라면 알약을 줄이고 글자 끝을 …로 줄인다. 줄인 알약도 너무 좁으면 그리지 않는다.
            let room = bounds.maxX - 0.5 - rect.minX
            if rect.width > room {
                guard room >= minWidth || (index == 0 && room > padding.width * 2) else { break }
                rect.size.width = room
            }
            let color = TagColor.color(for: tag)
            let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            color.withAlphaComponent(TagColor.fillAlpha).setFill()
            pill.fill()
            color.withAlphaComponent(TagColor.strokeAlpha).setStroke()
            pill.lineWidth = 1
            pill.stroke()
            (TagColor.displayName(tag) as NSString).draw(
                in: rect.insetBy(dx: padding.width - 0.5, dy: padding.height - 0.5),
                withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncating])
            if rect.width < frame.width - 1 { break }
        }
    }
}
