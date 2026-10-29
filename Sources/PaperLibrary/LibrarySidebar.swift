import AppKit
import PaperMarkLibrary

/// 사이드바의 한 줄. 머리글(Library, Collections, Tags)은 filter가 없다.
private final class LibraryNode: NSObject {
    let title: String
    let symbol: String?
    let filter: LibraryFilter?
    var children: [LibraryNode]

    init(_ title: String, symbol: String? = nil, filter: LibraryFilter? = nil, children: [LibraryNode] = []) {
        self.title = title
        self.symbol = symbol
        self.filter = filter
        self.children = children
    }

    var isGroup: Bool { filter == nil }
}

/// 라이브러리 창 사이드바: All Items, Unfiled, 컬렉션 트리, 태그. 고르면 onSelect로 표를 거른다.
final class LibrarySidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: ((LibraryFilter) -> Void)?
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
        outline.rowHeight = 22
        outline.indentationPerLevel = 10
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
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
        groups = [
            LibraryNode("Library", children: [
                LibraryNode("All Items", symbol: "books.vertical", filter: .all),
                LibraryNode("Unfiled", symbol: "tray", filter: .unfiled),
            ]),
        ]
        let collections = nodes(under: nil)
        if !collections.isEmpty { groups.append(LibraryNode("Collections", children: collections)) }
        if !store.tags.isEmpty {
            groups.append(LibraryNode("Tags", children: store.tags.map { LibraryNode($0, symbol: "tag", filter: .tag($0)) }))
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
        !((item as? LibraryNode)?.isGroup ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? LibraryNode else { return nil }
        let id = NSUserInterfaceItemIdentifier(node.isGroup ? "group" : "row")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id, icon: !node.isGroup)
        cell.textField?.stringValue = node.isGroup ? node.title.uppercased() : node.title
        if let symbol = node.symbol { cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, icon: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        if !icon {
            field.font = .systemFont(ofSize: 11, weight: .bold)
            field.textColor = .secondaryLabelColor
        }
        cell.addSubview(field)
        cell.textField = field
        var constraints = [
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        ]
        if icon {
            let image = NSImageView()
            image.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            image.contentTintColor = .secondaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            ]
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
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
