import AppKit
import PaperMarkLibrary

/// 사이드바의 한 줄. 머리글(Library, Collections, Tags)은 filter가 없다.
private final class LibraryNode: NSObject {
    let title: String
    let symbol: String?
    let filter: LibraryFilter?
    var children: [LibraryNode]
    /// Unlinked PDFs: 고르지 않고 누르면 추가할 파일 목록을 연다.
    var isNewFiles = false

    init(_ title: String, symbol: String? = nil, filter: LibraryFilter? = nil, children: [LibraryNode] = []) {
        self.title = title
        self.symbol = symbol
        self.filter = filter
        self.children = children
    }

    var isGroup: Bool { filter == nil && !isNewFiles }
    var collectionID: Int64? { if case .collection(let id)? = filter { id } else { nil } }
}

/// 머리글 글자. 소스 목록은 머리글의 글자 칸(NSTextField)을 흐리게 그리므로 글자를 직접 그려 검정으로 둔다.
private final class HeaderLabel: NSView {
    var text = "" { didSet { needsDisplay = true } }
    let font = NSFont.systemFont(ofSize: Style.fontSize - 3, weight: .bold)
    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(font.ascender - font.descender))
    }
    override func draw(_ dirtyRect: NSRect) {
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: bounds, withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncating])
    }
}

/// 라이브러리 창 사이드바: All Items, Unfiled, 컬렉션 트리(= workspace 폴더), 태그. 고르면 onSelect로 표를 거른다.
/// 우클릭으로 컬렉션을 만들고 이름을 바꾸고 지우며, 표에서 끌어 온 논문을 컬렉션에 놓으면 옮긴다(⌥: 참조 넣기).
final class LibrarySidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onSelect: ((LibraryFilter) -> Void)?
    /// Unlinked PDFs를 눌렀을 때.
    var onNewFiles: (() -> Void)?
    private(set) var selection: LibraryFilter = .all

    private let outline = NSOutlineView()
    private var groups: [LibraryNode] = []
    private static let collapsedKey = "libraryCollapsedCollections"

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.rowHeight = Style.rowHeight + 2
        outline.indentationPerLevel = 10
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.menu = NSMenu()
        outline.menu?.font = Style.font
        outline.menu?.delegate = self
        outline.registerForDraggedTypes([.libraryItem])
        outline.setDraggingSourceOperationMask([], forLocal: false)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: LibraryStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: LibraryStore.newFilesDidChange, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func reload() {
        let store = LibraryStore.shared
        let byParent = Dictionary(grouping: store.collections, by: \.parentID)
        func nodes(under parent: Int64?) -> [LibraryNode] {
            (byParent[parent] ?? []).map {
                LibraryNode($0.name, symbol: "folder", filter: .collection($0.id), children: nodes(under: $0.id))
            }
        }
        let library = LibraryNode("Library", children: [
            LibraryNode("All Items", symbol: "books.vertical", filter: .all),
            LibraryNode("Unfiled", symbol: "tray", filter: .unfiled),
        ])
        // 늘 보인다. 라이브러리에 없는 PDF가 workspace에 생기면 수가 늘어난다.
        let newFiles = LibraryNode("Unlinked PDFs (\(store.newFiles.count))", symbol: "doc.badge.plus")
        newFiles.isNewFiles = true
        library.children.append(newFiles)
        // 비어 있어도 둔다: 우클릭으로 첫 컬렉션을 만든다.
        groups = [library, LibraryNode("Collections", children: nodes(under: nil))]
        if !store.tags.isEmpty {
            groups.append(LibraryNode("Tags", children: store.tags.map { LibraryNode(TagColor.displayName($0), symbol: "tag", filter: .tag($0)) }))
        }
        outline.reloadData()
        restoring = true
        let collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
        func expand(_ nodes: [LibraryNode]) {
            for node in nodes where !node.children.isEmpty && !collapsed.contains(collapseID(node)) {
                outline.expandItem(node)
                expand(node.children)
            }
        }
        expand(groups)
        restoring = false
        // 고른 컬렉션이 사라졌으면 All Items로.
        if !select(selection) { selection = .all; _ = select(.all); onSelect?(.all) }
    }

    @discardableResult
    private func select(_ filter: LibraryFilter) -> Bool {
        func find(_ nodes: [LibraryNode]) -> LibraryNode? {
            for node in nodes {
                if node.filter == filter { return node }
                if let found = find(node.children) { return found }
            }
            return nil
        }
        guard let node = find(groups) else { return false }
        var parent = outline.parent(forItem: node)
        while let p = parent { outline.expandItem(p); parent = outline.parent(forItem: p) }
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: node)), byExtendingSelection: false)
        return true
    }

    // 펼침 상태는 머리글·컬렉션 이름 경로로 기억한다.
    private var restoring = false
    private func collapseID(_ node: LibraryNode) -> String {
        var names = [node.title]
        var parent = outline.parent(forItem: node) as? LibraryNode
        while let p = parent { names.insert(p.title, at: 0); parent = outline.parent(forItem: p) as? LibraryNode }
        return names.joined(separator: "/")
    }

    private func setCollapsed(_ node: LibraryNode, _ collapsed: Bool) {
        guard !restoring else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
        if collapsed { set.insert(collapseID(node)) } else { set.remove(collapseID(node)) }
        UserDefaults.standard.set(Array(set), forKey: Self.collapsedKey)
    }

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? LibraryNode)?.children.count ?? groups.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? LibraryNode)?.children[index] ?? groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? LibraryNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? LibraryNode)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? LibraryNode else { return false }
        return !node.isGroup && !node.isNewFiles
    }

    @objc private func clicked(_ sender: Any?) {
        if (outline.item(atRow: outline.clickedRow) as? LibraryNode)?.isNewFiles == true { onNewFiles?() }
    }

    // MARK: 우클릭: 컬렉션 만들기·이름 바꾸기·지우기

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let node = outline.item(atRow: outline.clickedRow) as? LibraryNode
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node?.collectionID.map(NSNumber.init(value:))
        }
        guard let id = node?.collectionID, let name = node?.title else {
            add("New Collection…", #selector(newCollection(_:)))
            return
        }
        add("New Subcollection in “\(name)”…", #selector(newCollection(_:)))
        add("Rename “\(name)”…", #selector(renameCollection(_:)))
        if LibraryStore.shared.folderURL(of: id) != nil { add("Show in Finder", #selector(showCollectionInFinder(_:))) }
        menu.addItem(.separator())
        add("Delete “\(name)”…", #selector(deleteCollection(_:)))
    }

    private func collection(of sender: NSMenuItem) -> Int64? { (sender.representedObject as? NSNumber)?.int64Value }

    @objc private func newCollection(_ sender: NSMenuItem) {
        let parent = collection(of: sender)
        askName(title: parent == nil ? "New Collection" : "New Subcollection", initial: "", button: "Create") { name in
            let id = try LibraryStore.shared.createCollection(name, parent: parent)
            self.selection = .collection(id)
            self.select(.collection(id))
            self.onSelect?(.collection(id))
        }
    }

    @objc private func renameCollection(_ sender: NSMenuItem) {
        guard let id = collection(of: sender), let current = LibraryStore.shared.collections.first(where: { $0.id == id }) else { return }
        askName(title: "Rename Collection", initial: current.name, button: "Rename") { name in
            try LibraryStore.shared.renameCollection(id, to: name)
        }
    }

    @objc private func showCollectionInFinder(_ sender: NSMenuItem) {
        if let url = collection(of: sender).flatMap(LibraryStore.shared.folderURL(of:)) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func deleteCollection(_ sender: NSMenuItem) {
        let store = LibraryStore.shared
        guard let id = collection(of: sender), let name = store.collections.first(where: { $0.id == id })?.name,
              let summary = try? store.workspace?.deletionSummary(id) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(name)”?"
        var lines = ["The folder and its subcollections move to the Trash."]
        if summary.pdfs > 0 { lines.append("\(summary.pdfs) PDF\(summary.pdfs == 1 ? "" : "s") inside will go to the Trash too.") }
        if summary.items > 0 { lines.append("\(summary.items) paper\(summary.items == 1 ? "" : "s") stored there will be removed from the library.") }
        lines.append("References to papers stored elsewhere are only removed from this collection.")
        alert.informativeText = lines.joined(separator: " ")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let run = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            do { try store.deleteCollection(id) } catch { store.presentError(error, in: self.window) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    /// 이름을 묻는 창. done이 실패하면 오류를 보이고 다시 묻는다.
    private func askName(title: String, initial: String, button: String, done: @escaping (String) throws -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "The folder in your workspace changes too."
        let field = NSTextField(string: initial)
        field.font = Style.font
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let run = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != initial else { return }
            do { try done(name) } catch {
                LibraryStore.shared.presentError(error, in: nil)
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    // MARK: 끌어 놓기: 표의 논문을 컬렉션(또는 Unfiled)에

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? LibraryNode, index == NSOutlineViewDropOnItemIndex else { return [] }
        switch node.filter {
        case .collection?:
            // ⌥를 누르면 끄는 쪽이 복사만 허용한다.
            return info.draggingSourceOperationMask == .copy && Settings.allowReferences ? .copy : .move
        case .unfiled?: return .move
        default: return []
        }
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? LibraryNode else { return false }
        let ids = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .libraryItem).flatMap(Int64.init) }
        guard !ids.isEmpty else { return false }
        let store = LibraryStore.shared
        let viewing: Int64? = if case .collection(let c) = selection { c } else { nil }
        if let target = node.collectionID, info.draggingSourceOperationMask == .copy, Settings.allowReferences {
            store.addReferences(ids, to: target, in: window)
        } else {
            store.move(ids, viewing: viewing, to: node.collectionID, in: window)
        }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? LibraryNode else { return nil }
        let id = NSUserInterfaceItemIdentifier(node.isGroup ? "group" : "row")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id, icon: !node.isGroup)
        cell.textField?.stringValue = node.title
        (cell.subviews.first as? HeaderLabel)?.text = node.title.uppercased()
        if let symbol = node.symbol { cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        // 아이콘마다 색을 둔다. 태그는 표·정보 패널의 알약과 같은 색으로.
        switch node.filter {
        case .tag(let name)?:
            cell.imageView?.image = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil)
            cell.imageView?.contentTintColor = TagColor.color(for: name)
        case .all?: cell.imageView?.contentTintColor = .systemIndigo
        case .unfiled?: cell.imageView?.contentTintColor = .systemOrange
        case .collection?: cell.imageView?.contentTintColor = .systemBlue
        case nil: cell.imageView?.contentTintColor = .systemGreen
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, icon: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        guard icon else {
            let header = HeaderLabel()
            header.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(header)
            NSLayoutConstraint.activate([
                header.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                header.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                header.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            ])
            return cell
        }
        let field = NSTextField(labelWithString: "")
        field.font = Style.font
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        let image = NSImageView()
        image.symbolConfiguration = .init(pointSize: Style.fontSize - 1, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 22),
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outline.item(atRow: outline.selectedRow) as? LibraryNode, let filter = node.filter,
              filter != selection else { return }
        selection = filter
        onSelect?(filter)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? LibraryNode { setCollapsed(node, false) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? LibraryNode { setCollapsed(node, true) }
    }
}
