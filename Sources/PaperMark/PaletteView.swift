import AppKit
import PaperMarkCore

/// 툴바의 색 고르기: 프리셋 동그라미들 + 직접 고르는 색상 웰 + 프리셋 추가 버튼.
final class PaletteView: NSStackView {
    private let swatches = NSStackView()
    private let well = NSColorWell(style: .minimal)
    private let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add to Presets")!,
                                     target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        swatches.orientation = .horizontal
        swatches.spacing = 3

        well.target = self
        well.action = #selector(wellChanged(_:))
        well.toolTip = "Pick a Custom Color"
        addButton.target = self
        addButton.action = #selector(addCurrentColor(_:))
        addButton.bezelStyle = .toolbar
        addButton.toolTip = "Add the Current Color to Presets"

        addArrangedSubview(swatches)
        addArrangedSubview(well)
        addArrangedSubview(addButton)

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ColorStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ShortcutStore.didChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func refresh() {
        let store = ColorStore.shared
        swatches.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, hex) in store.presets.enumerated() {
            swatches.addArrangedSubview(SwatchView(hex: hex, selected: hex == store.currentHex, index: i))
        }
        // 색상 패널과 값을 주고받다 무한 반복하지 않도록 다를 때만 바꾼다.
        if well.color.hexString != store.currentHex { well.color = store.currentColor }
    }

    @objc private func wellChanged(_ sender: NSColorWell) {
        ColorStore.shared.currentHex = sender.color.hexString
    }

    @objc private func addCurrentColor(_ sender: Any?) {
        ColorStore.shared.addPreset(ColorStore.shared.currentHex)
    }
}

private final class SwatchView: NSView {
    private let hex: String
    private let selected: Bool

    init(hex: String, selected: Bool, index: Int) {
        self.hex = hex
        self.selected = selected
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let shortcut = Command.color(index).flatMap(ShortcutStore.shared.shortcut(for:)).map { " \($0.display)" } ?? ""
        toolTip = "\(hex)\(shortcut) (right-click to remove from presets)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
        (NSColor(hex: hex) ?? .clear).setFill()
        dot.fill()
        NSColor.separatorColor.setStroke()
        dot.lineWidth = 0.5
        dot.stroke()
        if selected {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        ColorStore.shared.currentHex = hex
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard ColorStore.shared.presets.count > 1 else { return nil }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Remove from Presets", action: #selector(removePreset(_:)), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func removePreset(_ sender: Any?) {
        ColorStore.shared.removePreset(hex)
    }
}
