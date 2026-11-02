import AppKit
import PaperMarkLibrary

/// PaperLibrary > Settings…(⌘,). 브라우저 확장으로 논문을 넣을 때 서지 정보를 채우는 방식과 PDF 저장 위치를 고른다.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let libraryFolderLabel = NSTextField(labelWithString: "")
    private let pdfFolderLabel = NSTextField(labelWithString: "")
    private let fileNameField = NSTextField()
    private let fileNamePreview = NSTextField(labelWithString: "")
    private let keyField = NSTextField()
    private let keyPreview = NSTextField(labelWithString: "")
    private let preferOnline = NSButton(checkboxWithTitle: "Prefer CrossRef and arXiv over the web page’s own metadata", target: nil, action: nil)
    private let publishedVersion = NSButton(checkboxWithTitle: "For arXiv papers, use the published version (conference or journal) when one is found",
                                            target: nil, action: nil)
    private let sentenceCase = NSButton(checkboxWithTitle: "Write titles in sentence case (only the first word capitalized)", target: nil, action: nil)
    private let connectorLabel = NSTextField(labelWithString: "")
    private let columnList = ChecklistView()
    private let infoList = ChecklistView()
    private var searchBoxes: [SearchField: NSButton] = [:]
    private let searchScope = NSButton(checkboxWithTitle: "Search only in the selected collection or tag", target: nil, action: nil)

    /// 미리보기에 쓰는 예시 논문.
    private static let sample: PaperMetadata = {
        var m = PaperMetadata()
        m.type = "conferencePaper"
        m.title = "LightGCN: Simplifying and Powering Graph Convolution Network for Recommendation"
        m.creators = [Creator(role: "author", family: "He", given: "Xiangnan"), Creator(role: "author", family: "Deng", given: "Kuan"),
                      Creator(role: "author", family: "Wang", given: "Xiang")]
        m.date = "2020-07-25"
        m.venue = "Proceedings of the 43rd International ACM SIGIR Conference on Research and Development in Information Retrieval"
        return m
    }()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PaperLibrary Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        for field in [fileNameField, keyField] {
            field.delegate = self
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        for label in [fileNamePreview, keyPreview, connectorLabel, libraryFolderLabel, pdfFolderLabel] {
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 560).isActive = true
        }
        for box in [preferOnline, publishedVersion, sentenceCase] {
            box.target = self
            box.action = #selector(lookupChanged(_:))
        }
        let tokens = NSTextField(wrappingLabelWithString: "Tokens: " + Naming.tokens.joined(separator: " ")
                                 + "  ({Title2}, {Title3}: first two or three words)")
        tokens.textColor = .secondaryLabelColor
        tokens.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tokens.preferredMaxLayoutWidth = 560

        let changeLibrary = NSButton(title: "Change…", target: self, action: #selector(chooseLibraryFolder(_:)))
        let changePDF = NSButton(title: "Change…", target: self, action: #selector(choosePDFFolder(_:)))
        let grid = NSGridView(views: [
            [Self.header("Library folder:"), Self.row(libraryFolderLabel, changeLibrary)],
            [Self.header("Save new PDFs in:"), Self.row(pdfFolderLabel, changePDF)],
            [Self.header("PDF file name:"), fileNameField],
            [NSGridCell.emptyContentView, fileNamePreview],
            [Self.header("Citation key:"), keyField],
            [NSGridCell.emptyContentView, keyPreview],
            [NSGridCell.emptyContentView, tokens],
            [Self.header("Metadata:"), preferOnline],
            [NSGridCell.emptyContentView, publishedVersion],
            [Self.header("Titles:"), sentenceCase],
            [Self.header("Browser extension:"), connectorLabel],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for row in [2, 6, 7, 9, 10] { grid.row(at: row).topPadding = 10 }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        Style.enlarge(content)

        // 탭 두 개: 논문 넣기(지금까지의 설정), 보기(표의 열, 정보 패널 칸).
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (view, title, symbol) in [(content, "Adding Papers", "square.and.arrow.down"),
                                      (makeDisplayTab(), "Display", "rectangle.split.3x1"),
                                      (makeSearchTab(), "Search", "magnifyingglass")] {
            let controller = NSViewController()
            controller.view = view
            controller.title = title
            view.layoutSubtreeIfNeeded()
            controller.preferredContentSize = view.fittingSize
            let item = NSTabViewItem(viewController: controller)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.toolbarStyle = .preference
        NotificationCenter.default.addObserver(self, selector: #selector(reloadLists), name: Settings.displayDidChange, object: nil)
        reloadLists()
        NotificationCenter.default.addObserver(self, selector: #selector(reloadSearch), name: Settings.searchDidChange, object: nil)
        reloadSearch()

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Connector.statusDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: LibraryStore.didChange, object: nil)
        fileNameField.stringValue = Settings.fileNamePattern
        keyField.stringValue = Settings.citationKeyPattern
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeDisplayTab() -> NSView {
        columnList.onChange = { Settings.columns = $0.compactMap(LibraryColumn.init) }
        infoList.onChange = { Settings.infoFields = $0.compactMap(InfoField.init) }
        let columns = Self.listColumn("Library columns", "Columns shown in the paper list. You can also drag column headers and right-click them.",
                                      columnList, restore: #selector(restoreColumns(_:)), target: self)
        let info = Self.listColumn("Info panel", "Fields shown on the right when you select a paper. The title is always shown.",
                                   infoList, restore: #selector(restoreInfoFields(_:)), target: self)
        let row = NSStackView(views: [columns, info])
        row.alignment = .top
        row.spacing = 28
        row.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        return view
    }

    private func makeSearchTab() -> NSView {
        let heading = NSTextField(labelWithString: "Search in")
        heading.font = .boldSystemFont(ofSize: Style.fontSize)
        let note = NSTextField(wrappingLabelWithString: "Fields the toolbar search looks in. Every word you type must appear in one of them. "
                               + "You can also change these from the magnifying glass in the search field.")
        note.font = .systemFont(ofSize: Style.fontSize - 2)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 520
        var views: [NSView] = [heading, note]
        for field in SearchField.allCases {
            let box = NSButton(checkboxWithTitle: field.title, target: self, action: #selector(searchChanged(_:)))
            box.font = Style.font
            searchBoxes[field] = box
            views.append(box)
        }
        searchScope.font = Style.font
        searchScope.target = self
        searchScope.action = #selector(searchChanged(_:))
        let scopeNote = NSTextField(wrappingLabelWithString: "When off, search always looks through all items, whatever is selected in the sidebar.")
        scopeNote.font = note.font
        scopeNote.textColor = .secondaryLabelColor
        scopeNote.preferredMaxLayoutWidth = 520
        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreSearch(_:)))
        restore.font = .systemFont(ofSize: Style.fontSize - 2)
        views += [searchScope, scopeNote, restore]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: note)
        if let last = searchBoxes[SearchField.allCases.last!] { stack.setCustomSpacing(18, after: last) }
        stack.setCustomSpacing(14, after: scopeNote)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        return view
    }

    @objc private func reloadSearch() {
        let fields = Settings.searchFields
        for (field, box) in searchBoxes { box.state = fields.contains(field) ? .on : .off }
        searchScope.state = Settings.searchWithinSelection ? .on : .off
    }

    @objc private func searchChanged(_ sender: NSButton) {
        let fields = SearchField.allCases.filter { searchBoxes[$0]?.state == .on }
        // 칸을 모두 끄면 검색이 아무것도 못 찾으니 마지막 하나는 남긴다.
        if fields.isEmpty { sender.state = .on; return }
        if sender === searchScope { Settings.searchWithinSelection = sender.state == .on } else { Settings.searchFields = fields }
    }

    @objc private func restoreSearch(_ sender: Any?) {
        Settings.searchFields = SearchField.defaults
        Settings.searchWithinSelection = false
    }

    private static func listColumn(_ title: String, _ hint: String, _ list: ChecklistView, restore: Selector, target: AnyObject) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: Style.fontSize)
        let note = NSTextField(wrappingLabelWithString: hint + " Check to show, drag to reorder.")
        note.font = .systemFont(ofSize: Style.fontSize - 2)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 300
        let button = NSButton(title: "Restore Defaults", target: target, action: restore)
        button.font = .systemFont(ofSize: Style.fontSize - 2)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([list.widthAnchor.constraint(equalToConstant: 300), list.heightAnchor.constraint(equalToConstant: CGFloat(InfoField.allCases.count) * (Style.rowHeight + 2) + 4)])
        let stack = NSStackView(views: [heading, note, list, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: note)
        return stack
    }

    @objc private func reloadLists() {
        columnList.set(all: LibraryColumn.allCases.map { ($0.rawValue, $0.title) }, shown: Settings.columns.map(\.rawValue),
                       locked: [LibraryColumn.title.rawValue])
        infoList.set(all: InfoField.allCases.map { ($0.rawValue, $0.title) }, shown: Settings.infoFields.map(\.rawValue))
    }

    @objc private func restoreColumns(_ sender: Any?) { Settings.columns = LibraryColumn.defaults }
    @objc private func restoreInfoFields(_ sender: Any?) { Settings.infoFields = InfoField.defaults }

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private static func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }

    @objc private func refresh() {
        libraryFolderLabel.stringValue = LibraryStore.shared.folder?.path ?? "Not set"
        pdfFolderLabel.stringValue = Settings.pdfFolder?.path ?? "Not set"
        let lookup = Settings.lookup
        preferOnline.state = lookup.preferOnline ? .on : .off
        publishedVersion.state = lookup.usePublishedVersion ? .on : .off
        sentenceCase.state = lookup.sentenceCase ? .on : .off
        connectorLabel.stringValue = Connector.shared.status
        updatePreviews()
    }

    private func updatePreviews() {
        var sample = Self.sample
        if Settings.lookup.sentenceCase { sample.title = PaperMetadata.sentenceCase(sample.title) }
        fileNamePreview.stringValue = "e.g. " + Naming.fileName(pattern: Settings.fileNamePattern, metadata: sample) + ".pdf"
        keyPreview.stringValue = "e.g. " + Naming.citationKey(pattern: Settings.citationKeyPattern, metadata: sample, taken: [])
    }

    func controlTextDidChange(_ notification: Notification) {
        let fileName = fileNameField.stringValue.trimmingCharacters(in: .whitespaces)
        let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        Settings.fileNamePattern = fileName.isEmpty ? Naming.defaultFileName : fileName
        Settings.citationKeyPattern = key.isEmpty ? Naming.defaultCitationKey : key
        updatePreviews()
    }

    @objc private func lookupChanged(_ sender: NSButton) {
        Settings.lookup = LookupOptions(preferOnline: preferOnline.state == .on, usePublishedVersion: publishedVersion.state == .on,
                                        sentenceCase: sentenceCase.state == .on)
        updatePreviews()
    }

    @objc private func chooseLibraryFolder(_ sender: Any?) {
        choose("Choose the folder that holds your library PDFs. Paths in the library are stored relative to it.",
               from: LibraryStore.shared.folder ?? LibraryStore.googleDriveFolder()) { LibraryStore.shared.folder = $0 }
    }

    @objc private func choosePDFFolder(_ sender: Any?) {
        choose("Choose where PDFs saved from the browser go. A folder inside the library folder keeps paths portable.",
               from: Settings.pdfFolder ?? LibraryStore.shared.folder) { folder in
            Settings.pdfFolder = folder
            if LibraryStore.shared.folder == nil { LibraryStore.shared.folder = folder }
        }
    }

    private func choose(_ message: String, from directory: URL?, then done: @escaping (URL) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { done(url) }
            self?.refresh()
        }
    }
}
