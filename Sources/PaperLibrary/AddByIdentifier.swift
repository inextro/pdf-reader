import AppKit
import PaperMarkLibrary

/// 툴바의 마술 지팡이(Zotero의 "Add Item by Identifier"): DOI·arXiv 번호를 넣으면 서지 정보만 넣는다. PDF는 받지 않는다.
/// 사이드바에서 컬렉션을 고르고 있으면 그 컬렉션에 넣는다.
final class AddByIdentifierController: NSViewController, NSTextFieldDelegate {
    /// 넣을 컬렉션(사이드바에서 고른 것).
    var collection: () -> Int64? = { nil }
    /// 다 넣은 뒤 표에서 고를 항목들.
    var onAdded: (Set<Int64>) -> Void = { _ in }
    var close: () -> Void = {}

    private let field = NSTextField()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var isAdding = false

    override func loadView() {
        let title = NSTextField(labelWithString: "Add papers by DOI or arXiv ID")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        field.controlSize = .large
        addButton.controlSize = .large
        field.placeholderString = "10.1145/3397271.3401063  2002.02126"
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 400).isActive = true
        addButton.target = self
        addButton.action = #selector(add(_:))
        addButton.keyEquivalent = "\r"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = 480
        let hint = NSTextField(wrappingLabelWithString: "Separate several with spaces. Only metadata is saved, without the PDF.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.preferredMaxLayoutWidth = 480

        let row = NSStackView(views: [field, spinner, addButton])
        row.spacing = 10
        let stack = NSStackView(views: [title, row, hint, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: title)
        // 팝오버의 루트 뷰로 스택을 바로 쓰면 edgeInsets가 먹지 않아, 여백은 감싼 뷰의 제약으로 준다.
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
        ])
        view = container
        Style.enlarge(container)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if !isAdding { show("") }
        view.window?.makeFirstResponder(field)
    }

    @objc private func add(_ sender: Any?) {
        guard !isAdding else { return }
        let seeds = PaperID.identifiers(in: field.stringValue)
        guard !seeds.isEmpty else { show("Enter a DOI (10.xxxx/…) or an arXiv ID (2002.02126)."); return }
        setAdding(true)
        show(seeds.count == 1 ? "Looking up…" : "Looking up \(seeds.count) papers…")
        let collection = collection()
        Task { @MainActor in
            var added: Set<Int64> = [], lines: [String] = [], failed: [String] = []
            var newCount = 0, existingCount = 0
            for seed in seeds {
                let label = seed.doi ?? seed.arxivID ?? ""
                let (metadata, warnings) = await MetadataLookup.complete(seed, options: Settings.lookup)
                // 찾지 못하면 제목이 비어 있다. 이름뿐인 항목은 만들지 않는다.
                guard !metadata.title.isEmpty else { failed.append(label); lines += warnings; continue }
                do {
                    let (id, existing) = try LibraryStore.shared.addPaper(metadata, to: collection)
                    added.insert(id)
                    if existing { existingCount += 1 } else { newCount += 1 }
                } catch {
                    failed.append(label)
                    lines.append(error.localizedDescription)
                }
            }
            if !added.isEmpty { LibraryStore.shared.didModify() }
            var summary: [String] = []
            if newCount > 0 { summary.append("Added \(newCount) paper\(newCount == 1 ? "" : "s").") }
            if existingCount > 0 { summary.append("\(existingCount) already in the library.") }
            if !failed.isEmpty { summary.append("Not found: " + failed.joined(separator: ", ")) }
            setAdding(false)
            onAdded(added)
            if failed.isEmpty {
                field.stringValue = ""
                show(summary.joined(separator: " "))
                if existingCount == 0 { close() }
            } else {
                // 못 찾은 것만 입력창에 남겨 고쳐 다시 넣을 수 있게 한다.
                field.stringValue = failed.joined(separator: " ")
                show((summary + lines).joined(separator: "\n"))
            }
        }
    }

    private func setAdding(_ adding: Bool) {
        isAdding = adding
        field.isEnabled = !adding
        addButton.isEnabled = !adding
        spinner.isHidden = !adding
        if adding { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func show(_ text: String) {
        message.stringValue = text
        message.isHidden = text.isEmpty
    }
}
