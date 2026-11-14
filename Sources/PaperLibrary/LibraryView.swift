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
final class LibraryView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSMenuItemValidation {
    var filter: LibraryFilter = .all { didSet { if filter != oldValue { refresh() } } }
    var query = "" { didSet { if query != oldValue { refresh() } } }
    /// 표에 보이는 항목 수가 바뀔 때(창 부제목에 보인다).
    var onCountChange: ((Int) -> Void)?
    /// 고른 항목이 바뀌거나 그 내용이 바뀔 때(오른쪽 정보 패널).
    var onSelectionChange: (([LibraryEntry]) -> Void)?

    var selectedItems: [LibraryEntry] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }

    private let table = LibraryTableView()
    /// 서재 칸을 고르면 키 입력을 받는 표.
    var tableView: NSTableView { table }
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
            c.minWidth = column == .title ? 160 : column.minWidth
            // 표 너비에 맞추는 일은 fitColumns가 한다.
            c.resizingMask = .userResizingMask
            c.headerCell.font = .systemFont(ofSize: Style.fontSize - 2)
            c.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column != .added && column != .year)
            table.addTableColumn(c)
        }
        table.style = .inset
        table.rowSizeStyle = .custom
        table.rowHeight = Style.rowHeight + 5  // 논문 표는 줄 사이를 넉넉히 둔다.
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.autosaveName = "LibraryTable"
        table.autosaveTableColumns = true
        applyColumns()
        resetOversizedColumns()
        // 정보 패널을 연 채 끄면 줄인 너비가 표에 저장되므로, 사용자가 정한 너비는 따로 기억한다.
        let savedWidths = UserDefaults.standard.dictionary(forKey: Self.widthsKey) as? [String: Double] ?? [:]
        for column in table.tableColumns {
            preferredWidths[column.identifier.rawValue] = savedWidths[column.identifier.rawValue].map { CGFloat($0) } ?? column.width
        }
        savePreferredWidths()
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(fitColumns),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
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
        PDFOpener.open(url, from: window)
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
            case .copyCitation:
                menuItem = menu.addItem(withTitle: (targets.count > 1 ? "Copy Citations" + count : "Copy Citation") + " (\(Settings.citationStyle.title))",
                                        action: #selector(copyCitationFromMenu(_:)), keyEquivalent: "")
                menuItem?.target = self
                menuItem?.representedObject = ids
            case .copyDOI: menuItem = item.doi == nil ? nil : add(menu, "Copy DOI", #selector(copyDOI(_:)), item)
            case .status: menuItem = statusSubmenu(menu, "Status" + count, targets)
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
            case .delete:
                menuItem = menu.addItem(withTitle: "Delete" + count + "…", action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
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

    /// 읽기 상태 고르기. 고른 논문이 모두 그 상태면 체크, 일부만이면 대시. None은 상태 태그를 모두 뗀다.
    private func statusSubmenu(_ menu: NSMenu, _ title: String, _ targets: [LibraryEntry]) -> NSMenuItem? {
        guard let submenu = statusMenu(targets) else { return nil }
        let parent = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private static func isStatus(_ tag: String) -> Bool { Settings.statusTags.contains { Library.tagKey($0) == Library.tagKey(tag) } }

    /// 표의 상태 알약을 눌렀을 때. 그 줄이 고른 줄 가운데 하나면 고른 줄 전부를 바꾼다.
    private func showStatusMenu(from pills: TagPillsView, at rect: NSRect) {
        let row = table.row(for: pills)
        guard rows.indices.contains(row) else { return }
        let targets = table.selectedRowIndexes.contains(row) ? selectedItems : [rows[row]]
        guard let menu = statusMenu(targets) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: pills)
    }

    private func statusMenu(_ targets: [LibraryEntry]) -> NSMenu? {
        let statuses = Settings.statusTags
        guard !statuses.isEmpty else { return nil }
        let submenu = NSMenu()
        submenu.font = Style.font
        let ids = targets.map(\.id)
        func has(_ item: LibraryEntry, _ tag: String) -> Bool { item.tags.contains { Library.tagKey($0) == Library.tagKey(tag) } }
        for tag in statuses {
            let entry = submenu.addItem(withTitle: TagColor.displayName(tag), action: #selector(statusFromMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.image = TagColor.icon(for: tag, pointSize: Style.fontSize - 1)
            entry.representedObject = StatusTarget(ids: ids, tag: tag)
            let count = targets.filter { has($0, tag) }.count
            entry.state = count == 0 ? .off : count == targets.count ? .on : .mixed
        }
        submenu.addItem(.separator())
        let none = submenu.addItem(withTitle: "None", action: #selector(statusFromMenu(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = StatusTarget(ids: ids, tag: nil)
        return submenu
    }

    private final class StatusTarget: NSObject {
        let ids: [Int64]
        let tag: String?
        init(ids: [Int64], tag: String?) { self.ids = ids; self.tag = tag }
    }

    @objc private func statusFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? StatusTarget else { return }
        do { try store.setStatus(target.tag, of: target.ids) } catch { NSApp.presentError(error) }
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
        fitColumns()
        saveColumns()
    }

    /// 처음 열 구성(Title, Authors, Year, Venue, Added)과 너비로 되돌린다.
    @objc private func restoreColumns(_ sender: Any?) {
        for column in table.tableColumns {
            column.width = Column(rawValue: column.identifier.rawValue)?.width ?? column.width
            preferredWidths[column.identifier.rawValue] = column.width
        }
        savePreferredWidths()
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
        if shown.contains(where: { wasHidden.contains($0.rawValue) }) { fitColumns() }
    }

    /// 예전 방식(마지막 열이 남는 너비를 모두 가짐)으로 저장된, 지나치게 넓은 열을 기본 너비로 되돌린다.
    private func resetOversizedColumns() {
        for column in table.tableColumns {
            guard let kind = Column(rawValue: column.identifier.rawValue), kind != .title, column.width > max(400, kind.width * 3) else { continue }
            column.width = kind.width
        }
    }

    /// Title 밖의 열이 사용자가 정한 너비. 자리가 모자라 줄였다가도 자리가 나면 이 너비로 돌아간다.
    private var preferredWidths: [String: CGFloat] = [:]
    private static let widthsKey = "libraryColumnWidths"
    private var fitting = false

    private func savePreferredWidths() {
        UserDefaults.standard.set(preferredWidths.mapValues(Double.init), forKey: Self.widthsKey)
    }

    /// 보이는 열이 모두 표 안에 들어가도록 너비를 정한다(정보 패널을 열어 표가 좁아져도 Tags까지 보인다).
    /// Title이 남는 자리를 갖고, 모자라면 Title을 최소 너비까지 줄인 뒤 나머지 열을 같은 비율로 줄인다.
    @objc private func fitColumns() {
        let available = scroll.contentView.bounds.width
        guard available > 0, !fitting, let title = table.tableColumns.first(where: { $0.identifier.rawValue == Column.title.rawValue }) else { return }
        fitting = true
        defer { fitting = false }
        let others = table.tableColumns.filter { !$0.isHidden && $0 !== title }
        for column in others { column.width = preferredWidths[column.identifier.rawValue] ?? column.width }
        // 표 너비에는 열 사이 간격과 inset 스타일의 좌우 여백이 들어 있어, 맞춘 뒤 남는 만큼 다시 고친다.
        // 첫 열 왼쪽 여백만큼 마지막 열 오른쪽에도 여백을 둔다.
        func excess() -> CGFloat {
            table.tile()
            let shown = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
            guard let first = shown.first, let last = shown.last else { return 0 }
            return table.rect(ofColumn: last).maxX + table.rect(ofColumn: first).minX - available
        }
        for _ in 0..<2 {
            let over = excess()
            guard abs(over) > 0.5 else { return }
            title.width = max(title.minWidth, title.width - over)
        }
        let over = excess()
        let shrinkable = others.reduce(0) { $0 + $1.width - $1.minWidth }
        guard over > 0.5, shrinkable > 0 else { return }
        let ratio = min(1, over / shrinkable)
        for column in others { column.width -= (column.width - column.minWidth) * ratio }
        table.tile()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        // 사용자가 머리글 경계를 끌어 바꾼 것만 기억한다(fitColumns가 바꾼 것은 알림이 늦게 와도 무시).
        guard !fitting, (table.headerView?.resizedColumn ?? -1) >= 0,
              let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              column.identifier.rawValue != Column.title.rawValue else { return }
        preferredWidths[column.identifier.rawValue] = column.width
        savePreferredWidths()
        fitColumns()
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

    @objc private func copyCitationFromMenu(_ sender: NSMenuItem) {
        let ids = Set(sender.representedObject as? [Int64] ?? [])
        copyCitations(rows.filter { ids.contains($0.id) })
    }

    /// Edit > Copy Citation (⌘⇧C).
    @objc func copyCitation(_ sender: Any?) { copyCitations(selectedItems) }

    /// 참고문헌 문장을 복사한다. 서식 있는 글(기울임)과 일반 글을 함께 넣어 Word·Docs·메모 어디에 붙여도 된다.
    private func copyCitations(_ items: [LibraryEntry]) {
        guard !items.isEmpty else { return }
        let lines = Citation.list(items, style: Settings.citationStyle)
        let font = NSFont(name: "Times New Roman", size: 12) ?? .systemFont(ofSize: 12)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let rich = NSMutableAttributedString()
        for (n, line) in lines.enumerated() {
            if n > 0 { rich.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            for piece in line { rich.append(NSAttributedString(string: piece.text, attributes: [.font: piece.italic ? italic : font])) }
        }
        NSPasteboard.general.clearContents()
        if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length)) { NSPasteboard.general.setData(rtf, forType: .rtf) }
        NSPasteboard.general.setString(rich.string, forType: .string)
        let what = items.count == 1 ? "Citation" : "\(items.count) citations"
        showToast("\(what) copied (\(Settings.citationStyle.title))")
    }

    private var toast: NSView?

    /// 표 아래쪽 가운데에 잠깐 떴다 사라지는 작은 알림.
    private func showToast(_ text: String) {
        toast?.removeFromSuperview()
        let box = NSVisualEffectView()
        box.material = .hudWindow
        box.blendingMode = .withinWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: Style.fontSize, weight: .semibold)
        icon.contentTintColor = .systemGreen
        let label = NSTextField(labelWithString: text)
        label.font = Style.font
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
        toast = box
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self, weak box] in
            guard let box else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; box.animator().alphaValue = 0 }) {
                box.removeFromSuperview()
                if self?.toast === box { self?.toast = nil }
            }
        }
    }

    @objc private func deleteFromMenu(_ sender: NSMenuItem) {
        let ids = Set(sender.representedObject as? [Int64] ?? [])
        confirmDelete(rows.filter { ids.contains($0.id) })
    }

    /// Edit > Delete (⌘⌫). 표가 키 입력을 받을 때만 켜진다.
    @objc func deletePapers(_ sender: Any?) { confirmDelete(selectedItems) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(deletePapers(_:)) || menuItem.action == #selector(copyCitation(_:)) ? !selectedItems.isEmpty : true
    }

    /// 확인을 받고 라이브러리에서 지운다. PDF는 휴지통으로 간다.
    private func confirmDelete(_ items: [LibraryEntry]) {
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1 ? "Delete “\(items[0].title)”?" : "Delete \(items.count) papers?"
        let pdfs = items.filter { !$0.attachments.isEmpty }.count
        alert.informativeText = "The paper\(items.count == 1 ? "" : "s") will be removed from the library"
            + (pdfs == 0 ? "." : ", and \(pdfs == 1 && items.count == 1 ? "its PDF" : "\(pdfs) PDF\(pdfs == 1 ? "" : "s")") will go to the Trash.")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        // ⌘⌫ 다음 Return으로 바로 지운다. hasDestructiveAction을 켜면 Return이 버튼에서 빠지므로 쓰지 않는다.
        let ids = items.map(\.id)
        let run = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            do { try self.store.deleteItems(ids) } catch { self.store.presentError(error, in: self.window) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
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
                pills.opensMenu = { Self.isStatus($0) }
                pills.onPillClick = { [weak self, weak pills] _, rect in
                    guard let self, let pills else { return }
                    self.showStatusMenu(from: pills, at: rect)
                }
                return pills
            }()
            // 읽기 상태를 맨 앞에: 누르면 상태를 고르는 메뉴가 뜬다.
            cell.tags = item.tags.filter(Self.isStatus) + item.tags.filter { !Self.isStatus($0) }
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
