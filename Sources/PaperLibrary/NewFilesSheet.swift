import AppKit

private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// 사이드바 Unlinked PDFs: workspace에 있지만 라이브러리에 없는 PDF를 골라 논문으로 넣는다.
final class NewFilesSheet: NSWindowController {
    private var boxes: [(path: String, box: NSButton)] = []
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    var onAdded: (([Int64]) -> Void)?

    init(files: [String]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)

        let heading = NSTextField(labelWithString: "Unlinked PDFs")
        heading.font = .boldSystemFont(ofSize: Style.fontSize + 1)
        let note = NSTextField(wrappingLabelWithString: "These PDFs are in your workspace folder but not in the library. "
                               + "Added papers go to the collection of their folder, and their details are looked up from the DOI or arXiv ID on the first page.")
        note.font = .systemFont(ofSize: Style.fontSize - 2)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 580

        let list = FlippedStack()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        for path in files {
            let box = NSButton(checkboxWithTitle: path, target: self, action: #selector(updateButton))
            box.font = Style.font
            box.state = .on
            box.lineBreakMode = .byTruncatingMiddle
            list.addArrangedSubview(box)
            boxes.append((path, box))
        }
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let all = NSButton(title: "Select All", target: self, action: #selector(checkAll(_:)))
        let none = NSButton(title: "Select None", target: self, action: #selector(checkNone(_:)))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        addButton.target = self
        addButton.action = #selector(add(_:))
        addButton.keyEquivalent = "\r"
        let spacer = NSView()
        let buttons = NSStackView(views: [all, none, spacer, cancel, addButton])
        buttons.spacing = 8
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [heading, note, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 8),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 10),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -10),
        ])
        updateButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func updateButton() {
        let n = boxes.filter { $0.box.state == .on }.count
        addButton.title = n == 1 ? "Add 1 Paper" : "Add \(n) Papers"
        addButton.isEnabled = n > 0
    }

    @objc private func checkAll(_ sender: Any?) { boxes.forEach { $0.box.state = .on }; updateButton() }
    @objc private func checkNone(_ sender: Any?) { boxes.forEach { $0.box.state = .off }; updateButton() }

    @objc private func cancel(_ sender: Any?) { end() }

    @objc private func add(_ sender: Any?) {
        let ids = LibraryStore.shared.addNewFiles(boxes.filter { $0.box.state == .on }.map(\.path))
        end()
        onAdded?(ids)
    }

    private func end() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
    }
}
