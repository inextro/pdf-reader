import AppKit
import PaperMarkCore

/// Quillo 설정 창의 Reader 탭: 명령마다 단축키 칸을 누르고 새 키를 누르면 바뀐다.
@MainActor
public final class ReaderSettingsView: NSStackView {
    private var recorders: [ShortcutRecorder] = []
    private let message = NSTextField(labelWithString: "")

    public init() {
        super.init(frame: .zero)
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
            "Shortcuts for reading PDFs. Click a shortcut and press the new keys. Delete clears it, Esc cancels.")
        hint.textColor = .secondaryLabelColor
        message.textColor = .systemOrange
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))

        for view in [grid, hint, message, reset] { addArrangedSubview(view) }
        orientation = .vertical
        alignment = .centerX
        spacing = 12
        edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        hint.preferredMaxLayoutWidth = 380
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: ShortcutStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func refresh() {
        recorders.forEach { $0.refresh() }
    }

    private func show(_ text: String) {
        message.stringValue = text
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
