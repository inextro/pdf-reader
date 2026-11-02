import AppKit
import PaperMarkLibrary

extension NSPasteboard.PasteboardType {
    /// 표에서 끄는 논문(id 문자열).
    static let libraryItem = NSPasteboard.PasteboardType("com.inextro.paperlibrary.item")
}

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

    private typealias Column = LibraryColumn

    private static let sortKey = "librarySort"

    override init(frame: NSRect) {
        super.init(frame: frame)
        for column in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            c.title = column.title
            c.width = column.width
            c.minWidth = column.minWidth
            c.headerCell.font = .systemFont(ofSize: Style.fontSize - 2)
            c.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column != .added && column != .year)
            table.addTableColumn(c)
        }
        table.style = .inset
        table.rowSizeStyle = .custom
        table.rowHeight = Style.rowHeight + 5  // 논문 표는 줄 사이를 넉넉히 둔다.
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autosaveName = "LibraryTable"
        table.autosaveTableColumns = true
        applyColumns()
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked(_:))
        // 사이드바 컬렉션으로 끌어 옮긴다(⌥ 누르면 참조 넣기).
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.verticalMotionCanBeginDrag = false
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
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

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
        NotificationCenter.default.addObserver(self, selector: #selector(applyColumns),
                                               name: Settings.displayDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: Settings.searchDidChange, object: nil)
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
        // 검색어가 있으면 기본으로 사이드바 범위와 관계없이 전체에서 찾는다.
        let scoped = query.isEmpty || Settings.searchWithinSelection
        let fields = Settings.searchFields
        rows = sorted(store.items.filter { (!scoped || filter.includes($0)) && SearchField.matches($0, query, in: fields) })
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
        // 우클릭한 줄이 고른 줄 가운데 하나면 고른 줄 전부, 아니면 그 줄만.
        let targets = table.selectedRowIndexes.contains(table.clickedRow) ? selectedItems : [item]
        let ids = targets.map(\.id)
        let count = targets.count > 1 ? " (\(targets.count))" : ""
        let pdf = store.pdfURL(of: item)
        var lastGroup: Int?
        for action in Settings.itemMenu {
            let menuItem: NSMenuItem?
            switch action {
            case .openPDF: menuItem = pdf == nil ? nil : add(menu, "Open PDF", #selector(openFromMenu(_:)), item)
            case .showInFinder:
                menuItem = pdf == nil || store.missingPDF.contains(item.id) ? nil : add(menu, "Show in Finder", #selector(showInFinder(_:)), item)
            case .openWeb:
                menuItem = store.webURL(of: item) == nil ? nil : add(menu, item.doi != nil ? "Open DOI" : "Open URL", #selector(openWeb(_:)), item)
            case .copyCitationKey: menuItem = item.citationKey == nil ? nil : add(menu, "Copy Citation Key", #selector(copyCitationKey(_:)), item)
            case .copyDOI: menuItem = item.doi == nil ? nil : add(menu, "Copy DOI", #selector(copyDOI(_:)), item)
            case .moveTo: menuItem = collectionSubmenu(menu, "Move to" + count, #selector(moveFromMenu(_:)), ids, unfiled: true)
            case .addReference:
                menuItem = Settings.allowReferences ? collectionSubmenu(menu, "Add Reference to" + count, #selector(referenceFromMenu(_:)), ids, unfiled: false) : nil
            case .removeFromCollection:
                if case .collection(let c) = filter, targets.contains(where: { store.isReference($0, in: c) || store.pdfURL(of: $0) == nil }) {
                    let name = store.collections.first { $0.id == c }?.name ?? "Collection"
                    menuItem = menu.addItem(withTitle: "Remove from “\(name)”" + count, action: #selector(removeFromCollection(_:)), keyEquivalent: "")
                    menuItem?.target = self
                    menuItem?.representedObject = ids
                } else { menuItem = nil }
            case .regenerateCitationKey:
                menuItem = menu.addItem(withTitle: targets.count > 1 ? "Regenerate Citation Keys" + count : "Regenerate Citation Key",
                                        action: #selector(regenerateCitationKeys(_:)), keyEquivalent: "")
                menuItem?.target = self
                menuItem?.representedObject = ids
            }
            guard let menuItem else { continue }
            if let lastGroup, lastGroup != action.group {
                menu.insertItem(.separator(), at: menu.index(of: menuItem))
            }
            lastGroup = action.group
        }
    }

    /// 컬렉션 트리를 들여쓴 하위 메뉴. 고르면 action이 (논문 id들, 컬렉션 id 또는 nil=Unfiled)를 받는다.
    private func collectionSubmenu(_ menu: NSMenu, _ title: String, _ action: Selector, _ ids: [Int64], unfiled: Bool) -> NSMenuItem? {
        guard !store.collections.isEmpty else { return nil }
        let parent = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.font = Style.font
        if unfiled {
            let top = submenu.addItem(withTitle: "Unfiled", action: action, keyEquivalent: "")
            top.target = self
            top.representedObject = MenuTarget(ids: ids, collection: nil)
            top.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
            submenu.addItem(.separator())
        }
        let byParent = Dictionary(grouping: store.collections, by: \.parentID)
        func addChildren(of parent: Int64?, depth: Int) {
            for c in byParent[parent] ?? [] {
                let entry = submenu.addItem(withTitle: c.name, action: action, keyEquivalent: "")
                entry.target = self
                entry.indentationLevel = depth
                entry.representedObject = MenuTarget(ids: ids, collection: c.id)
                entry.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                addChildren(of: c.id, depth: depth + 1)
            }
        }
        addChildren(of: nil, depth: 0)
        parent.submenu = submenu
        return parent
    }

    private final class MenuTarget: NSObject {
        let ids: [Int64]
        let collection: Int64?
        init(ids: [Int64], collection: Int64?) { (self.ids, self.collection) = (ids, collection) }
    }

    private var viewingCollection: Int64? {
        if case .collection(let c) = filter { return c }
        return nil
    }

    @objc private func moveFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MenuTarget else { return }
        store.move(target.ids, viewing: viewingCollection, to: target.collection, in: window)
    }

    @objc private func referenceFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MenuTarget, let collection = target.collection else { return }
        store.addReferences(target.ids, to: collection, in: window)
    }

    @objc private func removeFromCollection(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [Int64], let c = viewingCollection else { return }
        store.removeReferences(ids, from: c, in: window)
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
        if !column.isHidden { makeRoom() }
        saveColumns()
    }

    /// 처음 열 구성(Title, Authors, Year, Venue, Added)과 너비로 되돌린다.
    @objc private func restoreColumns(_ sender: Any?) {
        for column in table.tableColumns { column.width = Column(rawValue: column.identifier.rawValue)?.width ?? column.width }
        Settings.columns = Column.defaults
    }

    private var applyingColumns = false

    /// 설정의 열 구성(보이는 열과 순서)을 표에 맞춘다. 설정 창에서 바꾸면 바로 따라간다.
    @objc private func applyColumns() {
        applyingColumns = true
        defer { applyingColumns = false }
        let shown = Settings.columns
        let wasHidden = Set(table.tableColumns.filter(\.isHidden).map(\.identifier.rawValue))
        for (index, column) in shown.enumerated() {
            let current = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
            guard current >= 0 else { continue }
            if current != index { table.moveColumn(current, toColumn: index) }
            table.tableColumns[index].isHidden = false
        }
        for column in table.tableColumns where !shown.contains(where: { $0.rawValue == column.identifier.rawValue }) {
            column.isHidden = true
        }
        // 정렬하던 열을 숨기면 추가한 순서로 돌아간다.
        if let key = table.sortDescriptors.first?.key, !shown.contains(where: { $0.rawValue == key }) {
            table.sortDescriptors = [NSSortDescriptor(key: Column.added.rawValue, ascending: false)]
        }
        if shown.contains(where: { wasHidden.contains($0.rawValue) }) { makeRoom() }
    }

    /// 새로 켠 열이 창 밖으로 밀리지 않게 Title 열을 줄인다. Title이 240보다 좁아져야 하면 가로로 스크롤한다.
    private func makeRoom() {
        let available = scroll.contentView.bounds.width
        guard available > 0, let title = table.tableColumns.first(where: { $0.identifier.rawValue == Column.title.rawValue }) else { return }
        let visible = table.tableColumns.filter { !$0.isHidden }
        let used = visible.reduce(0) { $0 + $1.width } + table.intercellSpacing.width * CGFloat(visible.count) + 20
        let overflow = used - available
        if overflow > 0 { title.width = max(240, title.width - overflow) }
    }

    /// 머리글을 끌거나 켜고 끄면 그 구성을 설정에 적는다.
    private func saveColumns() {
        guard !applyingColumns else { return }
        Settings.columns = table.tableColumns.filter { !$0.isHidden }.compactMap { Column(rawValue: $0.identifier.rawValue) }
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        saveColumns()
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ item: LibraryEntry) -> NSMenuItem {
        let menuItem = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = item.id
        return menuItem
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

    @objc private func regenerateCitationKeys(_ sender: NSMenuItem) {
        let ids = Set(sender.representedObject as? [Int64] ?? [])
        do { try store.regenerateCitationKeys(of: rows.filter { ids.contains($0.id) }) } catch { NSApp.presentError(error) }
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(rows[row].id), forType: .libraryItem)
        return item
    }

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
        if column == .tags {
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TagPillsView ?? {
                let pills = TagPillsView()
                pills.identifier = id
                pills.wraps = false
                return pills
            }()
            cell.tags = item.tags
            return cell
        }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id, icon: column == .title)
        cell.textField?.stringValue = column.text(item)
        // PDF가 없는 항목은 흐리게.
        cell.textField?.textColor = item.attachments.isEmpty ? .secondaryLabelColor : .labelColor
        if column == .title {
            let missing = store.missingPDF.contains(item.id)
            // 보고 있는 컬렉션에서 참조인 논문은 화살표 아이콘(원본 PDF는 다른 폴더에 있다).
            let reference = viewingCollection.map { store.isReference(item, in: $0) } ?? false
            cell.imageView?.image = item.attachments.isEmpty ? nil : NSImage(
                systemSymbolName: missing ? "exclamationmark.triangle" : reference ? "arrow.up.right.square" : "doc.richtext",
                accessibilityDescription: missing ? "PDF missing" : reference ? "Reference" : "PDF")
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
        // 열을 좁히면 글자를 줄인다. 글자 폭이 칸을 밀어내 옆 열을 덮지 않게.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
}
