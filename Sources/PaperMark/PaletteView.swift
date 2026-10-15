import AppKit
import PaperMarkCore

/// 툴바의 색 고르기: 프리셋 동그라미들 + 프리셋 추가 버튼.
/// 선택된 동그라미를 한 번 더 누르면 색상 패널이 열리고, 고른 색으로 그 프리셋 칸을 바꾼다(PDF Expert 방식).
final class PaletteView: NSStackView {
    private let swatches = NSStackView()
    private let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add a Preset")!,
                                     target: nil, action: nil)

    /// 색상 패널이 고치고 있는 프리셋 칸. adding이면 패널에서 처음 고른 색을 새 칸으로 추가한다.
    private enum Editing { case slot(Int), adding }
    private var editing: Editing?
    /// 색상 패널은 앱에 하나라서, 마지막으로 패널을 연 팔레트(창)만 패널 값을 받는다.
    private static weak var panelOwner: PaletteView?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        swatches.orientation = .horizontal
        swatches.spacing = 3

        addButton.target = self
        addButton.action = #selector(addPreset(_:))
        addButton.bezelStyle = .toolbar
        addButton.toolTip = "Add a Preset: pick a color in the color panel"

        addArrangedSubview(swatches)
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
            swatches.addArrangedSubview(SwatchView(hex: hex, selected: hex == store.currentHex, index: i) { [weak self] in
                self?.swatchClicked($0)
            })
        }
        followCurrentColor()
    }

    private var panelIsOurs: Bool {
        let panel = NSColorPanel.shared
        return panel.isVisible && Self.panelOwner === self
    }

    private func swatchClicked(_ index: Int) {
        let store = ColorStore.shared
        guard store.presets.indices.contains(index) else { return }
        if store.presets[index] == store.currentHex {
            openPanel(.slot(index))
        } else {
            store.currentHex = store.presets[index]
        }
    }

    /// ⌘1 등으로 현재 색이 바뀌면 열려 있는 패널도 그 칸을 고치도록 따라간다.
    private func followCurrentColor() {
        guard panelIsOurs, case .slot = editing,
              let index = ColorStore.shared.presets.firstIndex(of: ColorStore.shared.currentHex) else { return }
        editing = .slot(index)
        // 패널과 값을 주고받다 무한 반복하지 않도록 다를 때만 바꾼다.
        if NSColorPanel.shared.color.hexString != ColorStore.shared.currentHex {
            NSColorPanel.shared.color = ColorStore.shared.currentColor
        }
    }

    private func openPanel(_ mode: Editing) {
        editing = mode
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        Self.panelOwner = self
        panel.setTarget(self)
        panel.setAction(#selector(panelChanged(_:)))
        panel.color = ColorStore.shared.currentColor
        panel.orderFront(nil)
    }

    @objc private func panelChanged(_ sender: NSColorPanel) {
        let store = ColorStore.shared
        let hex = sender.color.hexString
        switch editing {
        case .adding:
            store.addPreset(hex)
            store.currentHex = hex
            if let index = store.presets.firstIndex(of: hex) { editing = .slot(index) }
        case .slot(let index):
            store.replacePreset(at: index, with: hex)
        case nil:
            break
        }
    }

    @objc private func addPreset(_ sender: Any?) {
        openPanel(.adding)
    }
}

private final class SwatchView: NSView {
    private let hex: String
    private let selected: Bool
    private let index: Int
    private let onClick: (Int) -> Void

    init(hex: String, selected: Bool, index: Int, onClick: @escaping (Int) -> Void) {
        self.hex = hex
        self.selected = selected
        self.index = index
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let shortcut = Command.color(index).flatMap(ShortcutStore.shared.shortcut(for:)).map { " \($0.display)" } ?? ""
        toolTip = "\(hex)\(shortcut). Click again to change this color, right-click to remove it"
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
        onClick(index)
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
