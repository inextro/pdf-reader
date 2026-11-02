import AppKit
import PaperMarkLibrary

extension NSPasteboard.PasteboardType {
    /// 사이드바 안에서 컬렉션 순서를 바꿀 때 끄는 컬렉션 id.
    static let libraryCollection = NSPasteboard.PasteboardType("com.inextro.paperlibrary.collection")
}

/// 사이드바의 한 줄. 머리글(Library, Collections, Tags)은 filter가 없다.
private final class LibraryNode: NSObject {
    let title: String
    let symbol: String?
    let filter: LibraryFilter?
    var children: [LibraryNode]
    /// Unlinked PDFs: 고르지 않고 누르면 추가할 파일 목록을 연다.
    var isNewFiles = false
    /// 오른쪽에 흐리게 보이는 논문 수(Zotero처럼). 컬렉션은 자기 논문 수(참조 포함)에 하위 컬렉션의 수를 그대로 더한다(사용자 선택: 겹치는 논문도 따로 센다).
    var count: Int?

    init(_ title: String, symbol: String? = nil, filter: LibraryFilter? = nil, children: [LibraryNode] = []) {
        self.title = title
        self.symbol = symbol
        self.filter = filter
        self.children = children
    }

    var isGroup: Bool { filter == nil && !isNewFiles }
    var collectionID: Int64? { if case .collection(let id)? = filter { id } else { nil } }
}

/// 줄 하나: 아이콘, 이름, 오른쪽 끝의 논문 수.
private final class RowCell: NSTableCellView {
    let countField = NSTextField(labelWithString: "")
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
        outline.registerForDraggedTypes([.libraryItem, .libraryCollection])
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // Library 머리글 위의 단추 줄: 새 컬렉션, 컬렉션 정렬.
        let bar = NSStackView(views: [
            barButton(Self.folderIcon(sorting: false, "New Collection"), "New Collection", #selector(addCollection(_:))),
            barButton(Self.folderIcon(sorting: true, "Sort Collections"), "Sort Collections", #selector(showSortMenu(_:))),
        ])
        bar.spacing = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),
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

    private func barButton(_ image: NSImage?, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        // 단추가 그림보다 작으면 그림을 줄여 그리므로, 단추를 그림 크기에 맞춘다.
        button.imageScaling = .scaleNone
        let size = image?.size ?? .zero
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size.width + 8),
            button.heightAnchor.constraint(equalToConstant: size.height + 8),
        ])
        return button
    }

    /// 단추 줄의 폴더 아이콘. 둘 다 folder.badge.plus를 같은 크기로 그린 그림이라 크기가 똑같다
    /// (기호를 단추에 그대로 주면 단추가 기호만 따로 키워 그린다). 정렬 아이콘은 SF Symbols에 없어서
    /// 배지 원의 + 자리를 채운 뒤 화살표 모양으로 다시 뚫는다. 원의 위치는 그 기호에서 잰 비율이다.
    private static func folderIcon(sorting: Bool, _ description: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: Style.fontSize + 2, weight: .regular)
        guard let base = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)?.withSymbolConfiguration(config),
              let mark = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: Style.fontSize * 0.34, weight: .heavy)) else { return nil }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            guard sorting else { return true }
            let d = rect.height * 0.42
            let circle = NSRect(x: rect.width * 0.783 - d / 2, y: rect.height * 0.65 - d / 2, width: d, height: d)
            NSBezierPath(ovalIn: circle.insetBy(dx: -0.3, dy: -0.3)).fill()
            mark.draw(in: NSRect(x: circle.midX - mark.size.width / 2, y: circle.midY - mark.size.height / 2,
                                 width: mark.size.width, height: mark.size.height),
                      from: .zero, operation: .destinationOut, fraction: 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    @objc private func addCollection(_ sender: Any?) { askNewCollection(parent: nil) }

    @objc private func showSortMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.font = Style.font
        for sort in CollectionSort.allCases {
            let item = menu.addItem(withTitle: sort.title, action: #selector(chooseSort(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sort.rawValue
            item.state = Settings.collectionSort == sort ? .on : .off
            if sort == .custom { item.toolTip = "Drag collections in the sidebar to reorder them." }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func chooseSort(_ sender: NSMenuItem) {
        guard let sort = (sender.representedObject as? String).flatMap(CollectionSort.init) else { return }
        // Custom을 처음 고르면 지금 보이는 순서에서 시작한다.
        if sort == .custom, Settings.collectionOrder.isEmpty { Settings.collectionOrder = displayedCollectionKeys() }
        Settings.collectionSort = sort
        reload()
    }

    /// 사이드바에 보이는 순서대로 모든 컬렉션 key.
    private func displayedCollectionKeys() -> [String] {
        let keys = Dictionary(LibraryStore.shared.collections.map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        func walk(_ nodes: [LibraryNode]) -> [String] {
            nodes.flatMap { node in (node.collectionID.flatMap { keys[$0] }.map { [$0] } ?? []) + walk(node.children) }
        }
        return walk(groups)
    }

    @objc private func reload() {
        let store = LibraryStore.shared
        let byParent = Dictionary(grouping: store.collections, by: \.parentID)
        let position = Dictionary(Settings.collectionOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // store.collections는 이름순(A→Z)이다.
        func sorted(_ list: [LibraryCollection]) -> [LibraryCollection] {
            switch Settings.collectionSort {
            case .nameAscending: list
            case .nameDescending: list.reversed()
            case .custom:
                list.enumerated().sorted { (position[$0.element.key] ?? .max, $0.offset) < (position[$1.element.key] ?? .max, $1.offset) }
                    .map(\.element)
            }
        }
        // 논문 수는 한 번 훑어 센다.
        var collectionCounts: [Int64: Int] = [:], tagCounts: [String: Int] = [:], unfiled = 0
        for item in store.items {
            if item.collectionIDs.isEmpty { unfiled += 1 }
            for id in item.collectionIDs { collectionCounts[id, default: 0] += 1 }
            for tag in item.tags { tagCounts[tag, default: 0] += 1 }
        }
        func counted(_ node: LibraryNode, _ count: Int) -> LibraryNode { node.count = count; return node }
        func nodes(under parent: Int64?) -> [LibraryNode] {
            sorted(byParent[parent] ?? []).map {
                let children = nodes(under: $0.id)
                let count = (collectionCounts[$0.id] ?? 0) + children.reduce(0) { $0 + ($1.count ?? 0) }
                return counted(LibraryNode($0.name, symbol: "folder", filter: .collection($0.id), children: children), count)
            }
        }
        let collectionNodes = nodes(under: nil)
        let library = LibraryNode("Library", children: [
            counted(LibraryNode("All Items", symbol: "books.vertical", filter: .all), store.items.count),
            counted(LibraryNode("Unfiled", symbol: "tray", filter: .unfiled), unfiled),
        ])
        // 늘 보인다. 라이브러리에 없는 PDF가 workspace에 생기면 수가 늘어난다.
        let newFiles = LibraryNode("Unlinked PDFs", symbol: "doc.badge.plus")
        newFiles.count = store.newFiles.count
        newFiles.isNewFiles = true
        library.children.append(newFiles)
        // 비어 있어도 둔다: 우클릭으로 첫 컬렉션을 만든다.
        groups = [library, LibraryNode("Collections", children: collectionNodes)]
        if !store.tags.isEmpty {
            groups.append(LibraryNode("Tags", children: store.tags.map {
                counted(LibraryNode(TagColor.displayName($0), symbol: "tag", filter: .tag($0)), tagCounts[$0] ?? 0)
            }))
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

    private func find(_ filter: LibraryFilter) -> LibraryNode? {
        func search(_ nodes: [LibraryNode]) -> LibraryNode? {
            for node in nodes {
                if node.filter == filter { return node }
                if let found = search(node.children) { return found }
            }
            return nil
        }
        return search(groups)
    }

    @discardableResult
    private func select(_ filter: LibraryFilter) -> Bool {
        guard let node = find(filter) else { return false }
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

    @objc private func newCollection(_ sender: NSMenuItem) { askNewCollection(parent: collection(of: sender)) }

    private func askNewCollection(parent: Int64?) {
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

    // MARK: 끌어 놓기: 표의 논문을 컬렉션(또는 Unfiled)에, Custom 순서에서는 컬렉션을 형제 사이로

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard Settings.collectionSort == .custom, let id = (item as? LibraryNode)?.collectionID else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(String(id), forType: .libraryCollection)
        return writer
    }

    private func draggedCollection(_ info: NSDraggingInfo) -> LibraryNode? {
        guard let id = info.draggingPasteboard.string(forType: .libraryCollection).flatMap(Int64.init) else { return nil }
        return find(.collection(id))
    }

    /// 컬렉션 순서 바꾸기: 같은 부모 안에서 줄 사이에만 놓는다(부모 바꾸기는 아직 없다).
    private func validateReorder(_ dragged: LibraryNode, onto item: Any?, at index: Int) -> NSDragOperation {
        guard index != NSOutlineViewDropOnItemIndex, let item = item as? LibraryNode,
              outline.parent(forItem: dragged) as? LibraryNode === item else { return [] }
        return .move
    }

    private func acceptReorder(_ dragged: LibraryNode, onto parent: LibraryNode, at index: Int) {
        guard let from = parent.children.firstIndex(where: { $0 === dragged }) else { return }
        var siblings = parent.children
        siblings.remove(at: from)
        siblings.insert(dragged, at: from < index ? index - 1 : index)
        parent.children = siblings
        Settings.collectionOrder = displayedCollectionKeys()
        reload()
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        if let dragged = draggedCollection(info) { return validateReorder(dragged, onto: item, at: index) }
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
        if let dragged = draggedCollection(info) {
            acceptReorder(dragged, onto: node, at: index)
            return true
        }
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
        (cell as? RowCell)?.countField.stringValue = node.count.map(String.init) ?? ""
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
        let cell: NSTableCellView = icon ? RowCell() : NSTableCellView()
        cell.identifier = id
        guard let cell = cell as? RowCell else {
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
        let count = cell.countField
        count.font = .monospacedDigitSystemFont(ofSize: Style.fontSize - 2, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.translatesAutoresizingMaskIntoConstraints = false
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        cell.addSubview(count)
        NSLayoutConstraint.activate([
            count.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            count.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 22),
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            field.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -6),
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
