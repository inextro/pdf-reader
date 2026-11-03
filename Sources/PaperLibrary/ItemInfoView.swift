import AppKit
import PaperMarkLibrary

/// 고칠 수 있는 칸은 줄바꿈 높이를 스스로 셈하지 않으므로, 폭이 정해지면 그 폭으로 줄을 바꿔 높이를 다시 잰다.
private final class EditableField: NSTextField {
    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let cell, preferredMaxLayoutWidth > 0 else { return super.intrinsicContentSize }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: preferredMaxLayoutWidth, height: .greatestFiniteMagnitude))
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(size.height))
    }
}

/// 고칠 수 있는 칸을 두르는 상자. 고치는 중에는 테두리를 강조색으로.
private final class FieldBox: NSView {
    let field: EditableField
    var isActive = false { didSet { needsDisplay = true } }

    init(_ field: EditableField) {
        self.field = field
        super.init(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        (isActive ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isActive ? 1.5 : 1
        path.stroke()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 라이브러리 창 오른쪽 패널: 표에서 고른 논문의 서지 정보 전체(저자, 출처, 식별자, PDF, 초록, 노트).
/// Zotero처럼 값을 눌러 바로 고치고, 칸을 떠나면(Return, Tab, 다른 곳 누르기) 저장한다. Esc는 고치기 전으로 되돌린다.
/// 고친 칸은 확장이 다시 저장해도 덮어쓰지 않는다(Library.edit).
final class ItemInfoView: NSView, NSTextFieldDelegate {
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let placeholder = NSTextField(labelWithString: "")
    private var store: LibraryStore { .shared }
    private var shownKey: String?
    private var shownModified: String?
    /// 고칠 수 있는 칸마다: 원래 값과 저장하는 방법.
    private struct Edit {
        var original: String
        var rebuild = false
        var isNew = false
        var apply: (inout PaperMetadata, inout String?, String?) -> Void
    }
    private var edits: [ObjectIdentifier: Edit] = [:]
    /// 칸 하나를 저장한 뒤 패널을 다시 그리지 않는다(Tab으로 옮겨 간 칸이 그대로 있게).
    private var keepView = false
    /// + 로 더하는 저자·편집자 빈 줄.
    private var newCreatorRole: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        placeholder.font = Style.font
        placeholder.textColor = .tertiaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show([])
        NotificationCenter.default.addObserver(self, selector: #selector(fieldsChanged), name: Settings.displayDidChange, object: nil)
    }

    /// 설정에서 보일 칸을 바꾸면 지금 항목을 다시 그린다.
    @objc private func fieldsChanged() {
        guard let item = store.items.first(where: { $0.key == shownKey }) else { return }
        shownKey = nil
        show([item])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 표에서 고른 항목들. 하나일 때만 내용을 보인다.
    func show(_ items: [LibraryEntry]) {
        newCreatorRole = items.first?.key == shownKey ? newCreatorRole : nil
        guard items.count == 1, let item = items.first else {
            shownKey = nil
            scroll.isHidden = true
            placeholder.isHidden = false
            placeholder.stringValue = items.isEmpty ? "No Item Selected" : "\(items.count) Items Selected"
            return
        }
        scroll.isHidden = false
        placeholder.isHidden = true
        if keepView, item.key == shownKey {
            keepView = false
            shownModified = item.modifiedAt
            return
        }
        // 같은 항목이 그대로면 다시 그리지 않는다(스크롤 위치를 지킨다).
        guard item.key != shownKey || item.modifiedAt != shownModified else { return }
        let scrollToTop = item.key != shownKey
        (shownKey, shownModified) = (item.key, item.modifiedAt)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        build(item)
        if scrollToTop { scroll.contentView.scroll(to: .zero) }
    }

    private func build(_ item: LibraryEntry) {
        let fields = Settings.infoFields
        edits.removeAll()
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        if fields.contains(.type) { header.addArrangedSubview(typePicker(item)) }
        let title = editable(item.title, font: .systemFont(ofSize: Style.fontSize + 3, weight: .semibold)) { m, _, value in
            m.title = value ?? ""
        }
        header.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        add(header)

        for info in fields {
            switch info {
            case .type: break
            case .authors: creators(item, role: "author")
            case .editors: creators(item, role: "editor")
            case .venue: edit(Self.venueTitle(item.type), item.venue) { m, _, v in m.venue = v }
            case .date: edit("Date", item.date ?? item.year.map(String.init)) { m, _, v in m.date = v }
            case .volumeIssuePages:
                let row = NSStackView(views: ["volume", "issue", "pages"].map { key in
                    section(Self.fieldTitle(key), editable(item.fields[key] ?? "") { m, _, v in m.fields[key] = v })
                })
                row.orientation = .horizontal
                row.alignment = .top
                row.distribution = .fillEqually
                row.spacing = 12
                add(row)
            case .publisher:
                edit("Publisher", item.fields["publisher"]) { m, _, v in m.fields["publisher"] = v }
                otherFields(item)
            case .citationKey: edit("Citation Key", item.citationKey) { _, key, v in key = v }
            case .doi:
                edit("DOI", item.doi, link: item.doi.flatMap { URL(string: "https://doi.org/\($0)") }) { m, _, v in
                    m.doi = v.map(Self.bareDOI)
                }
            case .arxiv:
                edit("arXiv", item.arxivID, link: item.arxivID.flatMap { URL(string: "https://arxiv.org/abs/\($0)") }) { m, _, v in
                    m.arxivID = v
                }
            case .url: edit("URL", item.url, link: item.url.flatMap(URL.init(string:))) { m, _, v in m.url = v }
            case .collections:
                let names = store.collections.filter { item.collectionIDs.contains($0.id) }.map { path(of: $0) }.sorted()
                field("Collections", names.joined(separator: "\n"))
            case .tags:
                if let picker = statusPicker(item) { add(section("Status", picker)) }
                let others = item.tags.filter { tag in !Settings.statusTags.contains { Library.tagKey($0) == Library.tagKey(tag) } }
                if !others.isEmpty {
                    let pills = TagPillsView()
                    pills.tags = others
                    add(section(others.count == 1 ? "Tag" : "Tags", pills))
                }
            case .pdf: pdfField(item)
            case .added: field("Added", Self.displayDate(item.addedAt))
            case .modified: field("Modified", Self.displayDate(item.modifiedAt))
            case .abstract: edit("Abstract", item.abstract) { m, _, v in m.abstract = v }
            case .notes:
                let notes = store.notes(of: item).map(Self.plainText).filter { !$0.isEmpty }
                if !notes.isEmpty {
                    add(section(notes.count == 1 ? "Note" : "Notes", wrapping(notes.joined(separator: "\n\n"), font: Style.font)))
                }
            }
        }
    }

    // MARK: 바로 고치기

    /// 고칠 수 있는 글자 칸(상자). 누르면 고친다. 비어 있으면 빈 상자.
    private func editable(_ value: String, font: NSFont = Style.font, rebuild: Bool = false, isNew: Bool = false,
                          apply: @escaping (inout PaperMetadata, inout String?, String?) -> Void) -> NSView {
        let field = EditableField(wrappingLabelWithString: value)
        field.font = font
        field.isEditable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = self
        field.focusRingType = .none
        edits[ObjectIdentifier(field)] = Edit(original: value, rebuild: rebuild, isNew: isNew, apply: apply)
        return FieldBox(field)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        ((notification.object as? NSView)?.superview as? FieldBox)?.isActive = true
    }

    /// 이름과 고칠 수 있는 값 한 칸. link가 있으면 옆에 여는 단추를 둔다.
    private func edit(_ label: String, _ value: String?, link: URL? = nil,
                      apply: @escaping (inout PaperMetadata, inout String?, String?) -> Void) {
        let field = editable(value ?? "", apply: apply)
        guard let link else { add(section(label, field)); return }
        let open = NSButton(image: NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Open")!,
                            target: self, action: #selector(openLink(_:)))
        open.isBordered = false
        open.toolTip = link.absoluteString
        open.identifier = NSUserInterfaceItemIdentifier(link.absoluteString)
        let row = NSStackView(views: [field, open])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        open.setContentHuggingPriority(.required, for: .horizontal)
        add(section(label, row))
    }

    @objc private func openLink(_ sender: NSButton) {
        if let url = sender.identifier.flatMap({ URL(string: $0.rawValue) }) { NSWorkspace.shared.open(url) }
    }

    func controlTextDidChange(_ notification: Notification) {
        // 줄이 늘면 칸도 바로 늘어나게.
        (notification.object as? NSTextField)?.invalidateIntrinsicContentSize()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), let edit = edits[ObjectIdentifier(control)] else { return false }
        // Esc: 고치기 전으로.
        textView.string = edit.original
        window?.makeFirstResponder(nil)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let edit = edits[ObjectIdentifier(field)] else { return }
        (field.superview as? FieldBox)?.isActive = false
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != edit.original.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return
        }
        edits[ObjectIdentifier(field)]?.original = value
        if edit.isNew { newCreatorRole = nil }
        commit(rebuild: edit.rebuild) { m, key in edit.apply(&m, &key, value.isEmpty ? nil : value) }
    }

    private func commit(rebuild: Bool, _ change: (inout PaperMetadata, inout String?) -> Void) {
        guard let item = shownItem else { return }
        var m = PaperMetadata(item), key = item.citationKey
        let oldVenueField = m.venueField
        change(&m, &key)
        // venue는 종류에 맞는 Zotero 필드 하나에만 둔다(표·참고문헌이 옛 필드를 읽지 않게).
        if m.venue != item.venue || m.venueField != oldVenueField {
            for name in Self.venueFields { m.fields[name] = nil }
            if let venue = m.venue { m.fields[m.venueField] = venue }
        }
        keepView = !rebuild && m.creators.count >= item.creators.count
        do {
            try store.editItem(item.id, to: m, citationKey: key)
        } catch {
            keepView = false
            store.presentError(error, in: window)
            redraw()
        }
    }

    /// 지금 논문을 스크롤 위치를 지키며 다시 그린다.
    private func redraw() {
        guard let item = shownItem else { return }
        shownModified = item.modifiedAt
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        build(item)
    }

    private func typePicker(_ item: LibraryEntry) -> NSView {
        let popup = NSPopUpButton()
        popup.isBordered = false
        popup.font = .systemFont(ofSize: Style.fontSize - 2)
        popup.contentTintColor = .secondaryLabelColor
        var types = Self.types
        if !types.contains(where: { $0.id == item.type }) { types.append((item.type, itemTypeName(item.type))) }
        for type in types {
            popup.addItem(withTitle: type.title)
            popup.lastItem?.representedObject = type.id
        }
        popup.selectItem(at: types.firstIndex { $0.id == item.type } ?? 0)
        popup.target = self
        popup.action = #selector(typeChanged(_:))
        return popup
    }

    @objc private func typeChanged(_ sender: NSPopUpButton) {
        guard let type = sender.selectedItem?.representedObject as? String else { return }
        commit(rebuild: true) { m, _ in m.type = type }
    }

    /// 저자·편집자: 줄마다 이름·성 상자. 둘 다 비우면 빠진다. + 로 더한다.
    private func creators(_ item: LibraryEntry, role: String) {
        let people = item.creators.enumerated().filter { $0.element.role == role }
        guard !people.isEmpty || role == "author" || newCreatorRole == role else { return }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        // 줄마다 이름(First)·성(Last) 두 상자. 둘 다 비우면 그 사람이 빠진다.
        func row(_ index: Int, _ c: Creator?, isNew: Bool) -> NSView {
            let family = editable(c?.family ?? "", isNew: isNew) { m, _, v in
                if index < m.creators.count { m.creators[index].family = v ?? "" } else if let v { m.creators.append(Creator(role: role, family: v, given: nil)) }
                Self.dropEmpty(&m, index)
            }
            let given = editable(c?.given ?? "", isNew: isNew) { m, _, v in
                if index < m.creators.count { m.creators[index].given = v } else if let v { m.creators.append(Creator(role: role, family: "", given: v)) }
                Self.dropEmpty(&m, index)
            }
            let row = NSStackView(views: [given, family])
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 6
            if isNew { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder((given as? FieldBox)?.field) } }
            return row
        }
        var rows = people.map { row($0.offset, $0.element, isNew: false) }
        if newCreatorRole == role { rows.append(row(item.creators.count, nil, isNew: true)) }
        let heading = NSStackView(views: [Self.smallLabel("First Name"), Self.smallLabel("Last Name")])
        heading.orientation = .horizontal
        heading.distribution = .fillEqually
        heading.spacing = 6
        for view in (rows.isEmpty ? [] : [heading]) + rows {
            column.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: self, action: #selector(addCreator(_:)))
        plus.isBordered = false
        plus.toolTip = "Add an author or editor"
        let count = rows.count
        let label = role == "author" ? (count == 1 ? "Author" : "Authors") : (count == 1 ? "Editor" : "Editors")
        add(section(label, column, accessory: plus))
    }

    /// 성·이름이 다 빈 사람은 뺀다.
    private static func dropEmpty(_ m: inout PaperMetadata, _ index: Int) {
        guard m.creators.indices.contains(index), m.creators[index].family.isEmpty, (m.creators[index].given ?? "").isEmpty else { return }
        m.creators.remove(at: index)
    }

    private static func smallLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Style.fontSize - 4)
        label.textColor = .tertiaryLabelColor
        return label
    }

    @objc private func addCreator(_ sender: NSButton) {
        let menu = NSMenu()
        menu.font = Style.font
        for (title, role) in [("Add Author", "author"), ("Add Editor", "editor")] {
            let item = menu.addItem(withTitle: title, action: #selector(addCreatorRow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = role
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func addCreatorRow(_ sender: NSMenuItem) {
        newCreatorRole = sender.representedObject as? String
        redraw()
    }

    /// 위 칸에 없는 Zotero 필드(series, ISBN …). 비우면 빠지고, Add Field…로 더한다.
    private func otherFields(_ item: LibraryEntry) {
        let shown: Set<String> = ["volume", "issue", "pages", "publisher", Library.editedKey]
        for key in item.fields.keys.sorted() where !shown.contains(key) && !Self.venueFields.contains(key) {
            edit(Self.fieldTitle(key), item.fields[key]) { m, _, v in m.fields[key] = v }
        }
        let button = NSButton(title: "Add Field…", target: self, action: #selector(addField(_:)))
        button.font = .systemFont(ofSize: Style.fontSize - 2)
        let row = NSStackView(views: [button])
        row.orientation = .horizontal
        add(row)
    }

    @objc private func addField(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Add Field"
        alert.informativeText = "Use a Zotero field name, such as series, edition, ISBN, or place."
        let name = NSTextField(string: "")
        name.placeholderString = "Field name"
        let value = NSTextField(string: "")
        value.placeholderString = "Value"
        let fields = NSStackView(views: [name, value])
        fields.orientation = .vertical
        fields.spacing = 6
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        for field in [name, value] {
            field.font = Style.font
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        alert.accessoryView = fields
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        let run = { (response: NSApplication.ModalResponse) in
            let key = name.stringValue.trimmingCharacters(in: .whitespaces), text = value.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !key.isEmpty, !text.isEmpty else { return }
            self.commit(rebuild: true) { m, _ in m.fields[key] = text }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    static let types: [(id: String, title: String)] = [
        ("journalArticle", "Journal Article"), ("conferencePaper", "Conference Paper"), ("preprint", "Preprint"),
        ("book", "Book"), ("bookSection", "Book Section"), ("thesis", "Thesis"), ("report", "Report"), ("webpage", "Web Page"),
    ]
    /// venue를 담는 Zotero 필드. 패널에서는 Venue 칸 하나로 보인다.
    private static let venueFields: Set<String> = ["publicationTitle", "proceedingsTitle", "repository", "websiteTitle", "bookTitle"]

    private static func venueTitle(_ type: String) -> String {
        switch type {
        case "journalArticle": "Journal"
        case "conferencePaper": "Proceedings"
        case "preprint": "Repository"
        case "webpage": "Website"
        case "bookSection": "Book Title"
        default: "Venue"
        }
    }

    /// "conferenceName" → "Conference name"
    private static func fieldTitle(_ key: String) -> String {
        guard key.first?.isLowercase == true else { return key }
        var out = ""
        for c in key { out += c.isUppercase ? " " + c.lowercased() : String(c) }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    /// "https://doi.org/10.1145/…"를 붙여 넣어도 DOI만 남긴다.
    private static func bareDOI(_ text: String) -> String {
        guard let range = text.range(of: #"10\.\d{4,9}/\S+"#, options: .regularExpression) else { return text }
        return String(text[range])
    }

    // MARK: 칸 만들기

    /// 읽기 상태 고르기(Settings의 Status tags). 고르면 다른 상태 태그를 떼고 붙인다.
    private func statusPicker(_ item: LibraryEntry) -> NSView? {
        let statuses = Settings.statusTags
        guard !statuses.isEmpty else { return nil }
        let popup = NSPopUpButton()
        popup.font = Style.font
        popup.target = self
        popup.action = #selector(statusChanged(_:))
        popup.addItem(withTitle: "None")
        popup.menu?.addItem(.separator())
        for tag in statuses {
            popup.addItem(withTitle: TagColor.displayName(tag))
            popup.lastItem?.representedObject = tag
            popup.lastItem?.image = TagColor.icon(for: tag, pointSize: Style.fontSize - 1)
        }
        let current = statuses.first { tag in item.tags.contains { Library.tagKey($0) == Library.tagKey(tag) } }
        popup.selectItem(at: current.flatMap { tag in statuses.firstIndex(of: tag).map { $0 + 2 } } ?? 0)
        popup.tag = Int(item.id)
        let row = NSStackView(views: [popup])
        row.orientation = .horizontal
        return row
    }

    @objc private func statusChanged(_ sender: NSPopUpButton) {
        do { try store.setStatus(sender.selectedItem?.representedObject as? String, of: [Int64(sender.tag)]) } catch { NSApp.presentError(error) }
    }

    private func field(_ label: String, _ value: String?, link: URL? = nil) {
        guard let value, !value.isEmpty else { return }
        let text = wrapping(value, font: Style.font)
        if let link {
            // 고를 수 있는 글자에 링크를 걸면 눌러서 열린다.
            text.allowsEditingTextAttributes = true
            text.attributedStringValue = NSAttributedString(string: value, attributes: [
                .link: link, .font: Style.font, .foregroundColor: NSColor.linkColor,
            ])
        }
        add(section(label, text))
    }

    private func pdfField(_ item: LibraryEntry) {
        guard let url = store.pdfURL(of: item) else { return }
        let missing = store.missingPDF.contains(item.id)
        let name = wrapping(url.lastPathComponent, font: Style.font)
        if missing { name.textColor = .systemOrange }
        let open = NSButton(title: missing ? "Missing" : "Open in PaperMark", target: self, action: #selector(openPDF(_:)))
        open.font = .systemFont(ofSize: Style.fontSize - 2)
        open.isEnabled = !missing
        open.controlSize = .regular
        let finder = NSButton(title: "Show in Finder", target: self, action: #selector(showInFinder(_:)))
        finder.font = open.font
        finder.isHidden = missing
        let buttons = NSStackView(views: [open, finder])
        buttons.spacing = 8
        let column = NSStackView(views: [name, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        add(section("PDF", column))
        name.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func section(_ label: String, _ content: NSView, accessory: NSView? = nil) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: Style.fontSize - 3, weight: .semibold)
        title.textColor = .secondaryLabelColor
        var heading: NSView = title
        if let accessory {
            let row = NSStackView(views: [title, accessory])
            row.orientation = .horizontal
            row.spacing = 4
            heading = row
        }
        let box = NSStackView(views: [heading, content])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 3
        content.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        return box
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func wrapping(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func path(of collection: LibraryCollection) -> String {
        var names = [collection.name]
        var parent = collection.parentID
        while let id = parent, let c = store.collections.first(where: { $0.id == id }) {
            names.insert(c.name, at: 0)
            parent = c.parentID
        }
        return names.joined(separator: " › ")
    }

    /// "2026-02-09T05:30:49Z" → 이 Mac의 시간대로 "2026-02-09 14:30".
    private static func displayDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Zotero 노트 HTML을 글자만 남긴다.
    private static func plainText(_ html: String) -> String {
        let text = (try? NSAttributedString(data: Data(html.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue,
        ], documentAttributes: nil))?.string ?? html
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: PDF

    private var shownItem: LibraryEntry? { store.items.first { $0.key == shownKey } }

    @objc private func openPDF(_ sender: Any?) {
        if let item = shownItem, let url = store.pdfURL(of: item) { PaperMark.open(url, from: window) }
    }

    @objc private func showInFinder(_ sender: Any?) {
        if let item = shownItem, let url = store.pdfURL(of: item) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
