import AppKit
import PaperMarkCore

/// 설정 창(⌘,): 명령마다 단축키 칸을 누르고 새 키를 누르면 바뀐다.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var recorders: [ShortcutRecorder] = []
    private let message = NSTextField(labelWithString: "")

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: ShortcutStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeContent() -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 16
        for command in Command.allCases {
            let label = NSTextField(labelWithString: command.title)
            let recorder = ShortcutRecorder(command: command) { [weak self] text in self?.show(text) }
            recorders.append(recorder)
            grid.addRow(with: [label, recorder])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 140

        let hint = NSTextField(wrappingLabelWithString:
            "Click a shortcut and press the new keys. Delete clears it, Esc cancels.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .systemOrange
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))
        let updates = NSButton(checkboxWithTitle: "Check for updates automatically", target: self,
                               action: #selector(toggleUpdateChecks(_:)))
        updates.state = UpdateController.shared.checksAutomatically ? .on : .off

        let stack = NSStackView(views: [updates, grid, hint, message, reset])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        hint.preferredMaxLayoutWidth = 360
        return stack
    }

    @objc private func refresh() {
        recorders.forEach { $0.refresh() }
    }

    private func show(_ text: String) {
        message.stringValue = text
    }

    @objc private func toggleUpdateChecks(_ sender: NSButton) {
        UpdateController.shared.checksAutomatically = sender.state == .on
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        ShortcutStore.shared.resetAll()
        show("")
    }
}

/// 누르면 녹음 상태가 되어 다음 키 조합을 단축키로 지정하는 버튼.
private final class ShortcutRecorder: NSButton {
    private let command: Command
    private let report: (String) -> Void
    private var recording = false { didSet { refresh() } }

    init(command: Command, report: @escaping (String) -> Void) {
        self.command = command
        self.report = report
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        widthAnchor.constraint(equalToConstant: 140).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    func refresh() {
        if recording { title = "Type shortcut…"; return }
        title = ShortcutStore.shared.shortcut(for: command)?.display ?? "None"
    }

    @objc private func startRecording() {
        recording = true
        report("")
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    // ⌘가 들어간 키는 keyDown 전에 이쪽으로 온다. 녹음 중에는 메뉴가 실행되지 않게 여기서 가로챈다.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let bare = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        defer { window?.makeFirstResponder(nil) }
        if bare && event.keyCode == 53 { return }                      // Esc: 취소
        if bare && (event.keyCode == 51 || event.keyCode == 117) {     // Delete: 비우기
            ShortcutStore.shared.set(nil, for: command)
            return
        }
        guard let shortcut = Shortcut.from(event), shortcut.isValid else {
            NSSound.beep()
            report("Use at least one of ⌘, ⌃, ⌥ (or an F-key).")
            return
        }
        if let owner = ShortcutStore.reserved[shortcut] {
            NSSound.beep()
            report("\(shortcut.display) is used by \(owner).")
            return
        }
        if let displaced = ShortcutStore.shared.set(shortcut, for: command) {
            report("\(shortcut.display) was moved from \(displaced.title).")
        }
    }
}
