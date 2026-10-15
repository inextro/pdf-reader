import AppKit
import PaperMarkCore

/// 단축키를 바꿀 수 있는 명령들.
enum Command: String, CaseIterable {
    case highlightSelection, highlightMode, eraserMode, removeCurrentColor
    case color1, color2, color3, color4, color5, color6, color7, color8, color9
    case toggleSidebar, zoomIn, zoomOut, zoomToFit
    case find, findNext, findPrevious

    static func color(_ index: Int) -> Command? { Command(rawValue: "color\(index + 1)") }

    var title: String {
        switch self {
        case .highlightSelection: "Highlight Selection"
        case .highlightMode: "Highlight Mode"
        case .eraserMode: "Eraser Mode"
        case .removeCurrentColor: "Remove Current Color"
        case .toggleSidebar: "Show/Hide Sidebar"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomToFit: "Zoom to Fit"
        case .find: "Find"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        default: "Color \(rawValue.dropFirst("color".count))"
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .highlightSelection: Shortcut(key: "d", modifiers: .command)
        case .highlightMode: Shortcut(key: "d", modifiers: [.command, .shift])
        case .eraserMode: Shortcut(key: "e", modifiers: [.command, .shift])
        case .removeCurrentColor: nil
        case .toggleSidebar: Shortcut(key: "s", modifiers: [.command, .control])
        case .zoomIn: Shortcut(key: "=", modifiers: .command)
        case .zoomOut: Shortcut(key: "-", modifiers: .command)
        case .zoomToFit: Shortcut(key: "0", modifiers: .command)
        case .find: Shortcut(key: "f", modifiers: .command)
        case .findNext: Shortcut(key: "g", modifiers: .command)
        case .findPrevious: Shortcut(key: "g", modifiers: [.command, .shift])
        default: Shortcut(key: String(rawValue.dropFirst("color".count)), modifiers: .command)
        }
    }
}

/// 사용자가 바꾼 단축키를 UserDefaults에 보관하고 메뉴 항목에 적용한다.
final class ShortcutStore {
    static let shared = ShortcutStore()
    static let didChange = Notification.Name("PaperMarkShortcutStoreDidChange")

    /// 바꿀 수 없는 기본 메뉴 단축키(종료, 닫기, 실행 취소 등).
    static let reserved: [Shortcut: String] = {
        let cmd: NSEvent.ModifierFlags = .command
        return [
            Shortcut(key: "q", modifiers: cmd): "Quit", Shortcut(key: "w", modifiers: cmd): "Close",
            Shortcut(key: "o", modifiers: cmd): "Open", Shortcut(key: "s", modifiers: cmd): "Save",
            Shortcut(key: "z", modifiers: cmd): "Undo", Shortcut(key: "z", modifiers: [.command, .shift]): "Redo",
            Shortcut(key: "c", modifiers: cmd): "Copy", Shortcut(key: "a", modifiers: cmd): "Select All",
            Shortcut(key: "h", modifiers: cmd): "Hide", Shortcut(key: "h", modifiers: [.command, .option]): "Hide Others",
            Shortcut(key: "m", modifiers: cmd): "Minimize", Shortcut(key: ",", modifiers: cmd): "Settings",
        ]
    }()

    /// 저장 형식: 기본값과 다르게 지정한 키, 그리고 비워 둔 명령.
    private struct Stored: Codable {
        var assigned: [String: Shortcut] = [:]
        var cleared: Set<String> = []
    }

    private let defaults = UserDefaults.standard
    private var stored: Stored

    private init() {
        stored = (defaults.data(forKey: "shortcuts")).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    func shortcut(for command: Command) -> Shortcut? {
        if stored.cleared.contains(command.rawValue) { return nil }
        return stored.assigned[command.rawValue] ?? command.defaultShortcut
    }

    /// 단축키를 지정한다(nil이면 비움). 같은 키를 쓰던 다른 명령은 비우고 그 명령을 돌려준다.
    @discardableResult
    func set(_ shortcut: Shortcut?, for command: Command) -> Command? {
        var displaced: Command?
        if let shortcut {
            for other in Command.allCases where other != command && self.shortcut(for: other) == shortcut {
                clear(other)
                displaced = other
            }
            stored.cleared.remove(command.rawValue)
            if shortcut == command.defaultShortcut { stored.assigned[command.rawValue] = nil }
            else { stored.assigned[command.rawValue] = shortcut }
        } else {
            clear(command)
        }
        save()
        return displaced
    }

    func resetAll() {
        stored = Stored()
        save()
    }

    func apply(_ command: Command, to item: NSMenuItem) {
        let shortcut = shortcut(for: command)
        item.keyEquivalent = shortcut?.key ?? ""
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
    }

    private func clear(_ command: Command) {
        stored.assigned[command.rawValue] = nil
        stored.cleared.insert(command.rawValue)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(stored), forKey: "shortcuts")
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
