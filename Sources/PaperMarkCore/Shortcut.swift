import AppKit

/// 메뉴 단축키 하나. key는 NSMenuItem.keyEquivalent에 그대로 넣는 문자다.
public struct Shortcut: Codable, Hashable {
    public let key: String
    public let modifierBits: UInt

    public var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    public init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        modifierBits = modifiers.intersection(Self.relevant).rawValue
    }

    /// 눌린 키를 메뉴 단축키 형태로 바꾼다. 글자는 소문자 + Shift 표시,
    /// 기호는 Shift가 반영된 문자(⇧= → +)에서 Shift를 뺀다. 메뉴가 같은 키로 알아보게 하려는 것이다.
    public static func normalized(characters: String, modifiers: NSEvent.ModifierFlags) -> Shortcut? {
        guard characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first else { return nil }
        var mods = modifiers.intersection(relevant)
        var key = characters
        if scalar.value == 0x7F { key = "\u{8}" }   // Delete 키는 메뉴에서 백스페이스 문자로 쓴다.
        if CharacterSet.letters.contains(scalar), scalar.isASCII {
            key = key.lowercased()
        } else if !isFunctionKey(scalar) {
            mods.remove(.shift)
        }
        return Shortcut(key: key, modifiers: mods)
    }

    public static func from(_ event: NSEvent) -> Shortcut? {
        normalized(characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags)
    }

    /// 다른 키와 부딪히지 않게 ⌘·⌃·⌥ 중 하나는 있어야 한다. F1~F20만 단독으로 허용한다.
    public var isValid: Bool {
        if !modifiers.intersection([.command, .control, .option]).isEmpty { return true }
        guard let scalar = key.unicodeScalars.first else { return false }
        return (0xF704...0xF717).contains(scalar.value)
    }

    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(key)
    }

    static func isFunctionKey(_ scalar: Unicode.Scalar) -> Bool { (0xF700...0xF8FF).contains(scalar.value) }

    static func keyName(_ key: String) -> String {
        guard let v = key.unicodeScalars.first?.value else { return key }
        switch v {
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF726: return "F\(v - 0xF704 + 1)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0x08: return "⌫"
        case 0x09: return "⇥"
        case 0x0D: return "↩"
        case 0x1B: return "⎋"
        case 0x20: return "Space"
        default: return key.uppercased()
        }
    }
}
