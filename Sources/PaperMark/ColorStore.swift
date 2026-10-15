import AppKit
import PaperMarkCore

/// 형광펜 색 프리셋, 현재 색, 형광펜 모드를 UserDefaults에 보관한다. 모든 창이 공유한다.
final class ColorStore {
    static let shared = ColorStore()
    static let didChange = Notification.Name("PaperMarkColorStoreDidChange")

    private let defaults = UserDefaults.standard
    // 아이패드 PDF Expert에서 쓰는 형광펜 색과 같게 맞춘다(PDF Expert 주석의 /C 값).
    private let builtInPresets = ["#F0CCDE", "#CEF3FE", "#FFFBC5", "#C1FFD9", "#EBC4F7", "#FFC677"]
    private let paletteVersion = 2

    private init() {
        // 팔레트를 바꾼 버전에서는 예전 기본 프리셋과 현재 색을 한 번 새 팔레트로 되돌린다.
        if defaults.integer(forKey: "paletteVersion") < paletteVersion {
            defaults.removeObject(forKey: "presets")
            defaults.removeObject(forKey: "currentColor")
            defaults.set(paletteVersion, forKey: "paletteVersion")
        }
    }

    var presets: [String] {
        get { defaults.stringArray(forKey: "presets") ?? builtInPresets }
        set { defaults.set(newValue, forKey: "presets"); notify() }
    }

    var currentHex: String {
        get { defaults.string(forKey: "currentColor") ?? presets.first ?? builtInPresets[0] }
        set {
            guard newValue != currentHex else { return }
            defaults.set(newValue, forKey: "currentColor")
            notify()
        }
    }

    var currentColor: NSColor { NSColor(hex: currentHex) ?? .systemYellow }

    /// 켜져 있으면 텍스트를 드래그해 선택하는 즉시 칠한다.
    var highlightMode: Bool {
        get { defaults.object(forKey: "highlightMode") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "highlightMode"); notify() }
    }

    func addPreset(_ hex: String) {
        if !presets.contains(hex) { presets.append(hex) }
    }

    func removePreset(_ hex: String) {
        guard presets.count > 1 else { return }
        presets.removeAll { $0 == hex }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

func swatchImage(_ color: NSColor, size: CGFloat = 14) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        color.setFill()
        circle.fill()
        NSColor.separatorColor.setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
        return true
    }
}
