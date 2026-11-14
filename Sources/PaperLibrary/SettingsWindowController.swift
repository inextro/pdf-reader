import AppKit
import AppUpdater
import PaperMarkLibrary
import Reader

/// Quillo > Settings…(⌘,). 브라우저 확장으로 논문을 넣을 때 서지 정보를 채우는 방식과 PDF 저장 위치를 고른다.
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
    private let checkUpdates = NSButton(checkboxWithTitle: "Check for updates automatically (once a day)", target: nil, action: nil)
    private let citationStyle = NSPopUpButton()
    private let columnList = ChecklistView()
    private let menuList = ChecklistView()
    private let statusList = ChecklistView()
    private let allowReferences = NSButton(checkboxWithTitle: "Allow references: a paper can also appear in other collections (⌥-drag, Add Reference to)",
                                           target: nil, action: nil)
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
        window.title = "Quillo Settings"
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
        allowReferences.target = self
        allowReferences.action = #selector(referencesChanged(_:))
        for box in [preferOnline, publishedVersion, sentenceCase] {
            box.target = self
            box.action = #selector(lookupChanged(_:))
        }
        let tokens = NSTextField(wrappingLabelWithString: "Tokens: " + Naming.tokens.joined(separator: " ")
                                 + "  ({Title2}, {Title3}: first two or three words)")
        tokens.textColor = .secondaryLabelColor
        tokens.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tokens.preferredMaxLayoutWidth = 560

        citationStyle.addItems(withTitles: CitationStyle.allCases.map(\.title))
        citationStyle.selectItem(at: CitationStyle.allCases.firstIndex(of: Settings.citationStyle) ?? 0)
        citationStyle.target = self
        citationStyle.action = #selector(citationStyleChanged(_:))
        let installExtension = NSButton(title: "Install…", target: self, action: #selector(installExtension(_:)))
        let changeLibrary = NSButton(title: "Change…", target: self, action: #selector(chooseLibraryFolder(_:)))
        let changePDF = NSButton(title: "Change…", target: self, action: #selector(choosePDFFolder(_:)))
        let grid = NSGridView(views: [
            [Self.header("Workspace folder:"), Self.row(libraryFolderLabel, changeLibrary)],
            [NSGridCell.emptyContentView, allowReferences],
            [Self.header("Save new PDFs in:"), Self.row(pdfFolderLabel, changePDF)],
            [Self.header("PDF file name:"), fileNameField],
            [NSGridCell.emptyContentView, fileNamePreview],
            [Self.header("Citation key:"), keyField],
            [NSGridCell.emptyContentView, keyPreview],
            [NSGridCell.emptyContentView, tokens],
            [Self.header("Metadata:"), preferOnline],
            [NSGridCell.emptyContentView, publishedVersion],
            [Self.header("Titles:"), sentenceCase],
            [Self.header("Copy Citation:"), citationStyle],
            [Self.header("Browser extension:"), Self.row(connectorLabel, installExtension)],
            [Self.header("Updates:"), checkUpdates],
        ])
        checkUpdates.target = self
        checkUpdates.action = #selector(checkUpdatesChanged(_:))
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for row in [2, 3, 7, 8, 10, 11, 12, 13] { grid.row(at: row).topPadding = 10 }
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

        // 탭: 논문 넣기, 보기(표의 열, 정보 패널 칸), 검색, 우클릭 메뉴, 리더(PDF 단축키).
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (view, title, symbol) in [(content, "Adding Papers", "square.and.arrow.down"),
                                      (makeDisplayTab(), "Display", "rectangle.split.3x1"),
                                      (makeSearchTab(), "Search", "magnifyingglass"),
                                      (makeMenuTab(), "Menu", "contextualmenu.and.cursorarrow"),
                                      (ReaderSettingsView(), "Reader", "highlighter")] {
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
        NotificationCenter.default.addObserver(self, selector: #selector(reloadLists), name: LibraryStore.didChange, object: nil)
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

    private func makeMenuTab() -> NSView {
        menuList.onChange = { Settings.itemMenu = $0.compactMap(ItemMenuAction.init) }
        let menu = Self.listColumn("Right-click menu", "Items shown when you right-click a paper in the list. Items that do not apply are hidden.",
                                   menuList, restore: #selector(restoreMenu(_:)), target: self, rows: ItemMenuAction.allCases.count)
        statusList.onChange = { Settings.statusTags = $0 }
        let statuses = Self.listColumn("Status tags", "Tags offered in Status ▸. A paper has at most one of them; new papers get the first. "
                                       + "Add, rename, or delete tags by right-clicking Tags in the sidebar.",
                                       statusList, restore: #selector(restoreStatuses(_:)), target: self, rows: 8)
        let column = NSStackView(views: [menu, statuses])
        column.alignment = .top
        column.spacing = 32
        column.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 700),
        ])
        return view
    }

    @objc private func restoreMenu(_ sender: Any?) { Settings.itemMenu = ItemMenuAction.defaults }
    @objc private func restoreStatuses(_ sender: Any?) { Settings.statusTags = Settings.defaultStatusTags }

    @objc private func referencesChanged(_ sender: NSButton) { Settings.allowReferences = sender.state == .on }

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

    private static func listColumn(_ title: String, _ hint: String, _ list: ChecklistView, restore: Selector, target: AnyObject,
                                   rows: Int = InfoField.allCases.count) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: Style.fontSize)
        let note = NSTextField(wrappingLabelWithString: hint + " Check to show, drag to reorder.")
        note.font = .systemFont(ofSize: Style.fontSize - 2)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 300
        let button = NSButton(title: "Restore Defaults", target: target, action: restore)
        button.font = .systemFont(ofSize: Style.fontSize - 2)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([list.widthAnchor.constraint(equalToConstant: 300), list.heightAnchor.constraint(equalToConstant: CGFloat(rows) * (Style.rowHeight + 2) + 4)])
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
        menuList.set(all: ItemMenuAction.allCases.map { ($0.rawValue, $0.title) }, shown: Settings.itemMenu.map(\.rawValue))
        // 라이브러리의 태그 전부. 상태 목록에만 있는 이름(아직 논문에 붙인 적 없음)도 보인다.
        let tags = Settings.statusTags + LibraryStore.shared.tags.filter { tag in !Settings.statusTags.contains { Library.tagKey($0) == Library.tagKey(tag) } }
        statusList.set(all: tags.map { ($0, TagColor.displayName($0)) }, shown: Settings.statusTags)
        allowReferences.state = Settings.allowReferences ? .on : .off
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
        checkUpdates.state = UpdateController.shared.checksAutomatically ? .on : .off
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

    @objc private func installExtension(_ sender: Any?) { ChromeExtension.install(in: window) }

    @objc private func checkUpdatesChanged(_ sender: NSButton) {
        UpdateController.shared.checksAutomatically = sender.state == .on
    }

    @objc private func citationStyleChanged(_ sender: NSPopUpButton) {
        Settings.citationStyle = CitationStyle.allCases[max(0, sender.indexOfSelectedItem)]
    }

    @objc private func chooseLibraryFolder(_ sender: Any?) {
        choose("Choose your workspace folder. Its subfolders are your collections, and paths in the library are stored relative to it.",
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
