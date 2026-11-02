import AppKit
import PaperMarkLibrary

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 라이브러리 창 오른쪽 패널: 표에서 고른 논문의 서지 정보 전체(저자, 출처, 식별자, PDF, 초록, 노트).
/// 글자는 고를 수 있어 복사할 수 있다. 고친 내용을 저장하는 편집은 아직 없다.
final class ItemInfoView: NSView {
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let placeholder = NSTextField(labelWithString: "")
    private var store: LibraryStore { .shared }
    private var shownKey: String?
    private var shownModified: String?

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
        guard items.count == 1, let item = items.first else {
            shownKey = nil
            scroll.isHidden = true
            placeholder.isHidden = false
            placeholder.stringValue = items.isEmpty ? "No Item Selected" : "\(items.count) Items Selected"
            return
        }
        scroll.isHidden = false
        placeholder.isHidden = true
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
        let title = wrapping(item.title.isEmpty ? "Untitled" : item.title, font: .systemFont(ofSize: Style.fontSize + 3, weight: .semibold))
        let header = NSStackView(views: [title])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        if fields.contains(.type) {
            let type = wrapping(itemTypeName(item.type), font: .systemFont(ofSize: Style.fontSize - 2))
            type.textColor = .secondaryLabelColor
            header.insertArrangedSubview(type, at: 0)
        }
        add(header)

        let name = { (c: Creator) in [c.given, c.family].compactMap { $0 }.joined(separator: " ") }
        for info in fields {
            switch info {
            case .type: break
            case .authors:
                let authors = item.creators.filter { $0.role == "author" }.map(name)
                field(authors.count == 1 ? "Author" : "Authors", authors.joined(separator: "\n"))
            case .editors:
                let editors = item.creators.filter { $0.role == "editor" }.map(name)
                field(editors.count == 1 ? "Editor" : "Editors", editors.joined(separator: "\n"))
            case .venue: field("Venue", item.venue)
            case .date: field("Date", item.date ?? item.year.map(String.init))
            case .volumeIssuePages:
                field(info.title, [item.fields["volume"].map { "Vol. \($0)" }, item.fields["issue"].map { "No. \($0)" },
                                   item.fields["pages"].map { "pp. \($0)" }].compactMap { $0 }.joined(separator: ", "))
            case .publisher: field("Publisher", [item.fields["publisher"], item.fields["place"]].compactMap { $0 }.joined(separator: ", "))
            case .citationKey: field("Citation Key", item.citationKey)
            case .doi: field("DOI", item.doi, link: item.doi.flatMap { URL(string: "https://doi.org/\($0)") })
            case .arxiv: field("arXiv", item.arxivID, link: item.arxivID.flatMap { URL(string: "https://arxiv.org/abs/\($0)") })
            case .url:
                if let url = item.url, url != item.doi.map({ "https://doi.org/\($0)" }) { field("URL", url, link: URL(string: url)) }
            case .collections:
                let names = store.collections.filter { item.collectionIDs.contains($0.id) }.map { path(of: $0) }.sorted()
                field("Collections", names.joined(separator: "\n"))
            case .tags:
                if !item.tags.isEmpty {
                    let pills = TagPillsView()
                    pills.tags = item.tags
                    add(section(item.tags.count == 1 ? "Tag" : "Tags", pills))
                }
            case .pdf: pdfField(item)
            case .added: field("Added", Self.displayDate(item.addedAt))
            case .modified: field("Modified", Self.displayDate(item.modifiedAt))
            case .abstract:
                if let abstract = item.abstract, !abstract.isEmpty { add(section("Abstract", wrapping(abstract, font: Style.font))) }
            case .notes:
                let notes = store.notes(of: item).map(Self.plainText).filter { !$0.isEmpty }
                if !notes.isEmpty {
                    add(section(notes.count == 1 ? "Note" : "Notes", wrapping(notes.joined(separator: "\n\n"), font: Style.font)))
                }
            }
        }
    }

    // MARK: 칸 만들기

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

    private func section(_ label: String, _ content: NSView) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: Style.fontSize - 3, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let box = NSStackView(views: [title, content])
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
