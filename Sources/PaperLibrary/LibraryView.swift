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
    /// 고른 항목이 바뀌거나 그 내용이 바뀔 때(오른쪽 정보 패널).
    var onSelectionChange: (([LibraryEntry]) -> Void)?

    var selectedItems: [LibraryEntry] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }

    private let table = LibraryTableView()
    private let scroll = NSScrollView()
    private let emptyView = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var rows: [LibraryEntry] = []
    private var store: LibraryStore { .shared }

    /// 표의 열. 머리글을 끌어 순서를 바꾸고, 머리글을 오른쪽 클릭해 켜고 끈다(순서·너비·켜짐은 저장된다).
    private enum Column: String, CaseIterable {
        case title, authors, year, venue, added, modified, type, citationKey, doi, arxiv, publisher, pages, tags

        var title: String {
            switch self {
            case .title: "Title"
            case .authors: "Authors"
            case .year: "Year"
            case .venue: "Venue"
            case .added: "Added"
            case .modified: "Modified"
            case .type: "Item Type"
            case .citationKey: "Citation Key"
            case .doi: "DOI"
            case .arxiv: "arXiv"
            case .publisher: "Publisher"
            case .pages: "Pages"
            case .tags: "Tags"
            }
        }
        var width: CGFloat {
            switch self {
            case .title: 360
            case .authors: 140
            case .year: 56
            case .venue, .publisher: 180
            case .added, .modified: 100
            case .type: 130
            case .citationKey, .doi, .tags: 160
            case .arxiv, .pages: 100
            }
        }
        /// 처음에 보이는 열. 나머지는 머리글 메뉴에서 켠다.
        var shownByDefault: Bool { [.title, .authors, .year, .venue, .added].contains(self) }

        func text(_ item: LibraryEntry) -> String {
            switch self {
            case .title: item.title
            case .authors: item.authorSummary
            case .year: item.year.map(String.init) ?? ""
            case .venue: item.venue ?? ""
            case .added: String(item.addedAt.prefix(10))
            case .modified: String(item.modifiedAt.prefix(10))
            case .type: ["journalArticle": "Journal Article", "conferencePaper": "Conference Paper", "preprint": "Preprint",
                         "book": "Book", "webpage": "Web Page"][item.type] ?? "Other"
            case .citationKey: item.citationKey ?? ""
            case .doi: item.doi ?? ""
            case .arxiv: item.arxivID ?? ""
            case .publisher: item.fields["publisher"] ?? ""
            case .pages: item.fields["pages"] ?? ""
            case .tags: item.tags.joined(separator: ", ")
            }
        }

        func sortValue(_ item: LibraryEntry) -> String {
            switch self {
            case .year: item.year.map { String(format: "%04d", $0) } ?? ""
            case .added: item.addedAt
            case .modified: item.modifiedAt
            default: text(item)
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
            c.isHidden = !column.shownByDefault
            c.headerCell.font = .systemFont(ofSize: Style.fontSize - 2)
            c.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column != .added && column != .year)
            table.addTableColumn(c)
        }
        table.style = .inset
        table.rowSizeStyle = .custom
        table.rowHeight = Style.rowHeight
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
        table.menu?.font = Style.font
        let headerMenu = NSMenu()
        headerMenu.font = Style.font
        headerMenu.delegate = self
        table.headerView?.menu = headerMenu
        table.allowsColumnReordering = true
        table.menu?.delegate = self
        let saved = UserDefaults.standard.array(forKey: Self.sortKey)
        if let key = saved?.first as? String, let ascending = saved?.last as? Bool {
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        } else {
            table.sortDescriptors = [NSSortDescriptor(key: Column.added.rawValue, ascending: false)]
        }
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        emptyLabel.font = Style.font
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

    /// 방금 넣은 항목들을 표에서 고르고 보이게 한다.
    func select(itemIDs: Set<Int64>) {
        let indexes = IndexSet(rows.indices.filter { itemIDs.contains(rows[$0].id) })
        guard let first = indexes.first else { return }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        table.scrollRowToVisible(first)
    }

    /// 고른 행은 항목 key로 기억해 두었다가 다시 고른다.
    private func refresh() {
        let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].key : nil })
        rows = sorted(store.items.filter { filter.includes($0) && $0.matches(query) })
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].key) }), byExtendingSelection: false)
        onSelectionChange?(selectedItems)

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
        let value = column.sortValue
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
        if menu === table.headerView?.menu { fillColumnMenu(menu); return }
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

    // MARK: 열 고르기

    private func fillColumnMenu(_ menu: NSMenu) {
        for column in table.tableColumns.sorted(by: { $0.title < $1.title }) where column.identifier.rawValue != Column.title.rawValue {
            let item = menu.addItem(withTitle: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column
            item.state = column.isHidden ? .off : .on
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Restore Default Columns", action: #selector(restoreColumns(_:)), keyEquivalent: "").target = self
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.isHidden.toggle()
        // 정렬하던 열을 숨기면 추가한 순서로 돌아간다.
        if column.isHidden, table.sortDescriptors.first?.key == column.identifier.rawValue {
            table.sortDescriptors = [NSSortDescriptor(key: Column.added.rawValue, ascending: false)]
        }
    }

    /// 처음 열 구성(Title, Authors, Year, Venue, Added 순서와 너비)으로 되돌린다.
    @objc private func restoreColumns(_ sender: Any?) {
        for (index, column) in Column.allCases.enumerated() {
            let id = NSUserInterfaceItemIdentifier(column.rawValue)
            let current = table.column(withIdentifier: id)
            guard current >= 0 else { continue }
            table.moveColumn(current, toColumn: index)
            let tableColumn = table.tableColumns[index]
            tableColumn.isHidden = !column.shownByDefault
            tableColumn.width = column.width
        }
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?(selectedItems)
    }

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
        cell.textField?.stringValue = column.text(item)
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
        field.font = Style.font
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
            image.symbolConfiguration = .init(pointSize: Style.fontSize - 2, weight: .regular)
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            ]
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    /// 행에 올리면 전체 제목, 저자, 출처, citation key, 초록 앞부분을 보인다.
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
