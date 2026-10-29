import AppKit
import PaperMarkLibrary

private final class LibraryTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}

/// 라이브러리 창 본문: 서지 표. 사이드바에서 고른 범위(filter)와 툴바 검색어(query)로 거른다.
/// 더블클릭하면 PDF를 PaperMark로 열고, PDF가 없으면 DOI/URL을 브라우저로 연다.
final class LibraryView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var filter: LibraryFilter = .all { didSet { if filter != oldValue { refresh() } } }
    var query = "" { didSet { if query != oldValue { refresh() } } }
    /// 표에 보이는 항목 수가 바뀔 때(창 부제목에 보인다).
    var onCountChange: ((Int) -> Void)?

    private let table = LibraryTableView()
    private let scroll = NSScrollView()
    private let emptyView = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var rows: [LibraryEntry] = []
    private var store: LibraryStore { .shared }

    private enum Column: String, CaseIterable {
        case title, authors, year, venue, added

        var title: String {
            switch self {
            case .title: "Title"
            case .authors: "Authors"
            case .year: "Year"
            case .venue: "Venue"
            case .added: "Added"
            }
        }
        var width: CGFloat {
            switch self {
            case .title: 360
            case .authors: 140
            case .year: 50
            case .venue: 180
            case .added: 90
            }
        }
    }

    private static let sortKey = "librarySort"

    override init(frame: NSRect) {
        super.init(frame: frame)
        for column in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            c.title = column.title
            c.width = column.width
            c.minWidth = 40
            c.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column != .added && column != .year)
            table.addTableColumn(c)
        }
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autosaveName = "LibraryTable"
        table.autosaveTableColumns = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked(_:))
        table.onReturn = { [weak self] in self?.openSelected() }
        table.menu = NSMenu()
        table.menu?.delegate = self
        let saved = UserDefaults.standard.array(forKey: Self.sortKey)
        if let key = saved?.first as? String, let ascending = saved?.last as? Bool {
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        } else {
            table.sortDescriptors = [NSSortDescriptor(key: Column.added.rawValue, ascending: false)]
        }
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "books.vertical", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let importButton = NSButton(title: "Import from Zotero…", target: self, action: #selector(importFromZotero(_:)))
        importButton.keyEquivalent = "\r"
        for view in [icon, emptyLabel, importButton] { emptyView.addArrangedSubview(view) }
        emptyView.orientation = .vertical
        emptyView.spacing = 12

        for view in [scroll, emptyView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyView.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: LibraryStore.didChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func storeChanged() { refresh() }

    /// 고른 행은 항목 key로 기억해 두었다가 다시 고른다.
    private func refresh() {
        let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].key : nil })
        rows = sorted(store.items.filter { filter.includes($0) && $0.matches(query) })
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].key) }), byExtendingSelection: false)

        let empty = store.items.isEmpty
        scroll.isHidden = empty
        emptyView.isHidden = !empty
        emptyLabel.stringValue = store.loadError.map { "The library could not be opened.\n\($0.localizedDescription)" }
            ?? (store.isImporting ? "Importing…" : "Your library is empty. Import your Zotero library to get started.")
        onCountChange?(rows.count)
    }

    private func sorted(_ items: [LibraryEntry]) -> [LibraryEntry] {
        guard let descriptor = table.sortDescriptors.first, let key = descriptor.key,
              let column = Column(rawValue: key) else { return items }
        func value(_ item: LibraryEntry) -> String {
            switch column {
            case .title: item.title
            case .authors: item.authorSummary
            case .year: item.year.map { String(format: "%04d", $0) } ?? ""
            case .venue: item.venue ?? ""
            case .added: item.addedAt
            }
        }
        // 값이 같으면 추가한 순서(최근 먼저)로 둔다. 빈 값은 늘 아래로.
        return items.enumerated().sorted { a, b in
            let (va, vb) = (value(a.element), value(b.element))
            if va.isEmpty != vb.isEmpty { return vb.isEmpty }
            let order = va.localizedStandardCompare(vb)
            if order == .orderedSame { return a.offset < b.offset }
            return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.element)
    }

    // MARK: 열기

    @objc private func openClicked(_ sender: Any?) {
        guard rows.indices.contains(table.clickedRow) else { return }
        open(rows[table.clickedRow])
    }

    private func openSelected() {
        for row in table.selectedRowIndexes where rows.indices.contains(row) { open(rows[row]) }
    }

    private func open(_ item: LibraryEntry) {
        guard let url = store.pdfURL(of: item) else {
            if let web = store.webURL(of: item) { NSWorkspace.shared.open(web) } else { NSSound.beep() }
            return
        }
        guard !store.missingPDF.contains(item.id) else {
            let alert = NSAlert()
            alert.messageText = "The PDF is missing."
            alert.informativeText = url.path
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        PaperMark.open(url, from: window)
    }

    @objc private func importFromZotero(_ sender: Any?) {
        store.importFromZotero(in: window)
        refresh()
    }

    // MARK: 우클릭 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow) else { return }
        let item = rows[table.clickedRow]
        let pdf = store.pdfURL(of: item)
        if pdf != nil { add(menu, "Open PDF", #selector(openFromMenu(_:)), item) }
        if pdf != nil, !store.missingPDF.contains(item.id) { add(menu, "Show in Finder", #selector(showInFinder(_:)), item) }
        if store.webURL(of: item) != nil { add(menu, item.doi != nil ? "Open DOI" : "Open URL", #selector(openWeb(_:)), item) }
        menu.addItem(.separator())
        if item.citationKey != nil { add(menu, "Copy Citation Key", #selector(copyCitationKey(_:)), item) }
        if item.doi != nil { add(menu, "Copy DOI", #selector(copyDOI(_:)), item) }
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ item: LibraryEntry) {
        let menuItem = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = item.id
    }

    private func item(of sender: NSMenuItem) -> LibraryEntry? {
        rows.first { $0.id == sender.representedObject as? Int64 }
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) { item(of: sender).map(open) }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        if let url = item(of: sender).flatMap(store.pdfURL(of:)) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func openWeb(_ sender: NSMenuItem) {
        if let url = item(of: sender).flatMap(store.webURL(of:)) { NSWorkspace.shared.open(url) }
    }

    @objc private func copyCitationKey(_ sender: NSMenuItem) { copy(item(of: sender)?.citationKey) }
    @objc private func copyDOI(_ sender: NSMenuItem) { copy(item(of: sender)?.doi) }

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            UserDefaults.standard.set([key, descriptor.ascending], forKey: Self.sortKey)
        }
        refresh()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
        let item = rows[row]
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id, icon: column == .title)
        let text: String
        switch column {
        case .title: text = item.title
        case .authors: text = item.authorSummary
        case .year: text = item.year.map(String.init) ?? ""
        case .venue: text = item.venue ?? ""
        case .added: text = String(item.addedAt.prefix(10))
        }
        cell.textField?.stringValue = text
        cell.toolTip = toolTip(for: item)
        // PDF가 없는 항목은 흐리게.
        cell.textField?.textColor = item.attachments.isEmpty ? .secondaryLabelColor : .labelColor
        if column == .title {
            let missing = store.missingPDF.contains(item.id)
            cell.imageView?.image = item.attachments.isEmpty ? nil : NSImage(
                systemSymbolName: missing ? "exclamationmark.triangle" : "doc.richtext",
                accessibilityDescription: missing ? "PDF missing" : "PDF")
            cell.imageView?.contentTintColor = missing ? .systemOrange : .secondaryLabelColor
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, icon: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        var constraints = [
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
        ]
        if icon {
            let image = NSImageView()
            image.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            ]
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    /// 행에 올리면 전체 제목, 저자, 출처, citation key, 초록 앞부분을 보인다(상세 패널은 P2).
    private func toolTip(for item: LibraryEntry) -> String {
        var lines = [item.title]
        let names = item.creators.map { [$0.given, $0.family].compactMap { $0 }.joined(separator: " ") }
        if !names.isEmpty { lines.append(names.joined(separator: ", ")) }
        let source = [item.venue, item.date].compactMap { $0 }.joined(separator: ", ")
        if !source.isEmpty { lines.append(source) }
        if let key = item.citationKey { lines.append("@\(key)") }
        if let abstract = item.abstract, !abstract.isEmpty {
            lines.append("")
            lines.append(abstract.count > 600 ? abstract.prefix(600) + "…" : abstract)
        }
        if item.noteCount > 0 { lines.append("\n\(item.noteCount) note\(item.noteCount == 1 ? "" : "s")") }
        return lines.joined(separator: "\n")
    }
}
