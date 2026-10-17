import AppKit
import PDFKit
import PaperMarkCore

/// 파일 트리의 root 폴더(모든 창이 같이 쓴다). 정하지 않으면 각 창은 자기 PDF가 있는 폴더를 보여 준다.
enum FileTreeRoot {
    static let didChange = Notification.Name("FileTreeRootDidChange")
    private static let rootKey = "fileTreeRoot", expandedKey = "fileTreeExpanded"

    static var url: URL? {
        get { UserDefaults.standard.string(forKey: rootKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: rootKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// 펼쳐 둔 폴더 경로들. 창을 다시 열거나 새로 고쳐도 그대로 펼친다.
    static var expanded: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: expandedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: expandedKey) }
    }
}

/// 트리의 항목 하나. 폴더는 처음 펼칠 때 내용을 읽는다.
private final class FileNode: NSObject {
    let url: URL
    let isFolder: Bool
    private var loaded: [FileNode]?

    init(url: URL, isFolder: Bool) {
        self.url = url
        self.isFolder = isFolder
    }

    var children: [FileNode] {
        if loaded == nil { loaded = FileTree.children(of: url).map { FileNode(url: $0, isFolder: FileTree.isFolder($0)) } }
        return loaded ?? []
    }

    func child(at url: URL) -> FileNode? {
        children.first { $0.url.standardizedFileURL == url.standardizedFileURL }
    }
}

/// Return으로도 여는 트리.
private final class FileOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}

/// 안내선 한 줄. 다크 모드에서도 맞는 색이 되도록 draw에서 칠한다.
private final class GuideLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        bounds.fill()
    }
}

/// VS Code 탐색기처럼 단계마다 세로 안내선을 그리는 행.
/// 안내선은 조상 폴더의 펼침 화살표 가운데를 지나 그 폴더의 하위 항목들 옆으로 이어진다.
/// (source list 행은 drawBackground가 불리지 않아서 얇은 하위 뷰로 그린다.)
private final class GuideRowView: NSTableRowView {
    var level = 0
    var indent: CGFloat = 0
    private var lines: [GuideLine] = []
    /// 셀 왼쪽 끝에서 펼침 화살표 가운데까지의 거리. 화살표가 있는 행에서 재서 화살표 없는 행(PDF)도 같이 쓴다.
    private static var chevronOffset: CGFloat?

    override func layout() {
        super.layout()
        guard let cell = subviews.first(where: { $0 is NSTableCellView }) else { return }
        if let chevron = subviews.first(where: { $0.identifier == NSOutlineView.disclosureButtonIdentifier }) {
            Self.chevronOffset = cell.frame.minX - chevron.frame.midX
        }
        let count = Self.chevronOffset == nil ? 0 : level
        while lines.count < count { lines.append(GuideLine()); addSubview(lines.last!, positioned: .below, relativeTo: nil) }
        while lines.count > count { lines.removeLast().removeFromSuperview() }
        guard let offset = Self.chevronOffset else { return }
        for (depth, line) in lines.enumerated() {
            let x = cell.frame.minX - offset - CGFloat(level - depth) * indent
            line.frame = NSRect(x: x.rounded(.down), y: 0, width: 1, height: bounds.height)
        }
    }
}

/// 트리의 한 행: [PDF 아이콘] 이름 [열려 있으면 점]. 폴더는 아이콘 없이 화살표만 둔다.
private final class FileCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("FileCell")
    let openDot = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        image.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail   // 논문 제목은 앞부분이 중요하다
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Open")
        openDot.symbolConfiguration = .init(pointSize: 6, weight: .regular)
        openDot.contentTintColor = .tertiaryLabelColor
        openDot.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [image, text, openDot])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = image
        textField = text
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// 사이드바의 Files 탭: root 폴더 아래의 폴더와 PDF를 VS Code 탐색기처럼 보여 주고,
/// 두 번 클릭하거나 Return을 누르면 연다. 창의 PDF까지 자동으로 펼쳐서 강조한다.
final class FileTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    /// 이 창에서 보고 있는 PDF. root를 정하지 않았으면 이 파일의 폴더가 root다.
    var documentURL: URL?
    /// 트리에서 PDF를 연 뒤 할 일(새 탭은 자기를 닫는다).
    var didOpen: (() -> Void)?

    private let outline = FileOutlineView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var upButton: NSButton!
    private var root: FileNode?
    private var openURLs: Set<URL> = []
    private var restoring = false

    /// 정한 root, 없으면 이 창 PDF의 폴더. PDF 없는 새 탭은 가장 최근에 연 PDF의 폴더, 그것도 없으면 홈 폴더.
    private var rootURL: URL? {
        FileTreeRoot.url
            ?? (documentURL ?? NSDocumentController.shared.recentDocumentURLs.first)?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        titleLabel.font = .systemFont(ofSize: 11, weight: .bold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        upButton = headerButton("arrow.up", "Enclosing Folder", #selector(goUp(_:)))
        let header = NSStackView(views: [
            titleLabel, NSView(),
            upButton,
            headerButton("arrow.clockwise", "Refresh", #selector(refresh(_:))),
            headerButton("rectangle.compress.vertical", "Collapse All", #selector(collapseAll(_:))),
            headerButton("folder", "Choose Folder", #selector(showFolderMenu(_:))),
        ])
        header.spacing = 2
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)

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
        outline.target = self
        outline.doubleAction = #selector(openClicked(_:))
        outline.onReturn = { [weak self] in self?.openSelected() }
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for view in [header, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(rootChanged),
                                               name: FileTreeRoot.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func headerButton(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    // MARK: 읽기

    /// 폴더를 다시 읽는다. 펼친 폴더, 선택, 스크롤 위치는 그대로 두고,
    /// revealDocument면(창으로 돌아올 때, root가 바뀔 때) 이 창의 PDF까지 펼쳐서 선택한다.
    func reload(revealDocument: Bool = false) {
        guard let url = rootURL else { return }
        let rootChanged = root?.url.standardizedFileURL != url.standardizedFileURL
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.url
        let scrollOrigin = outline.enclosingScrollView?.contentView.bounds.origin

        titleLabel.stringValue = FileManager.default.displayName(atPath: url.path).uppercased()
        titleLabel.toolTip = url.path
        upButton.isEnabled = url.path != "/"
        openURLs = Set(NSDocumentController.shared.documents.compactMap { $0.fileURL?.standardizedFileURL })
        root = FileNode(url: url, isFolder: true)
        restoring = true
        outline.reloadData()
        expandSaved(root?.children ?? [])
        restoring = false

        if !rootChanged, let scrollOrigin { outline.scroll(scrollOrigin) }
        if revealDocument || rootChanged {
            if let documentURL { reveal(documentURL) }
        } else if let selected, let node = node(at: selected) {
            select(node)
        }
    }

    private func expandSaved(_ nodes: [FileNode]) {
        let expanded = FileTreeRoot.expanded
        for node in nodes where node.isFolder && expanded.contains(node.url.path) {
            outline.expandItem(node)
            expandSaved(node.children)
        }
    }

    /// 이미 펼쳐 놓은 범위에서 url의 항목을 찾는다.
    private func node(at url: URL) -> FileNode? {
        guard let root, let folders = FileTree.folders(from: root.url, to: url) else { return nil }
        var parent = root
        for folder in folders {
            guard let next = parent.child(at: folder), outline.isItemExpanded(next) else { return nil }
            parent = next
        }
        return parent.child(at: url)
    }

    /// url까지 폴더를 펼치고 선택한다.
    private func reveal(_ url: URL) {
        guard let root, let folders = FileTree.folders(from: root.url, to: url) else { return }
        var parent = root
        for folder in folders {
            guard let next = parent.child(at: folder) else { return }
            outline.expandItem(next)
            parent = next
        }
        if let node = parent.child(at: url) { select(node) }
    }

    private func select(_ node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    @objc private func rootChanged() { reload(revealDocument: true) }

    // MARK: 헤더 버튼

    @objc private func goUp(_ sender: Any?) {
        guard let url = rootURL, url.path != "/" else { return }
        FileTreeRoot.url = url.deletingLastPathComponent()
    }

    @objc private func refresh(_ sender: Any?) { reload() }

    @objc private func collapseAll(_ sender: Any?) {
        guard let root else { return }
        let prefix = root.url.path + "/"
        FileTreeRoot.expanded = FileTreeRoot.expanded.filter { !$0.hasPrefix(prefix) }
        restoring = true
        outline.collapseItem(nil, collapseChildren: true)
        restoring = false
    }

    @objc private func showFolderMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Choose Folder…", action: #selector(chooseFolder(_:)), keyEquivalent: "").target = self
        let reset = menu.addItem(withTitle: "Use This Document's Folder", action: #selector(useDocumentFolder(_:)),
                                 keyEquivalent: "")
        reset.target = self
        reset.isEnabled = FileTreeRoot.url != nil
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Show Folder"
        panel.directoryURL = rootURL
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { FileTreeRoot.url = url }
        }
    }

    @objc private func useDocumentFolder(_ sender: Any?) { FileTreeRoot.url = nil }

    // MARK: 열기

    @objc private func openClicked(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        open(node)
    }

    private func openSelected() {
        guard let node = outline.item(atRow: outline.selectedRow) as? FileNode else { return }
        open(node)
    }

    /// PDF는 열고(이미 열려 있으면 그 창을 앞으로), 폴더는 펼치거나 접는다.
    private func open(_ node: FileNode) {
        if node.isFolder {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
            return
        }
        let current = window
        NSDocumentController.shared.openDocument(withContentsOf: node.url, display: true) { [weak self] document, _, error in
            if let error { NSApp.presentError(error) }
            guard let document else { return }
            // 다른 창으로 떨어졌으면 이 창의 탭으로 붙인다(이미 열려 있던 PDF도 이 창으로 데려온다).
            if let current, let opened = document.windowControllers.first?.window, opened !== current,
               current.tabGroup?.windows.contains(opened) != true {
                current.addTabbedWindow(opened, ordered: .above)
                opened.makeKeyAndOrderFront(nil)
            }
            self?.didOpen?()
        }
    }

    // MARK: 우클릭 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if !node.isFolder { add(menu, "Open", #selector(openFromMenu(_:)), node) }
        add(menu, "Show in Finder", #selector(showInFinder(_:)), node)
        if node.isFolder { add(menu, "Use as Root Folder", #selector(useAsRoot(_:)), node) }
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ node: FileNode) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = node
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode { open(node) }
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
    }

    @objc private func useAsRoot(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode { FileTreeRoot.url = node.url }
    }

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? root)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell ?? FileCell()
        let url = node.url.standardizedFileURL
        let isCurrent = url == documentURL?.standardizedFileURL
        cell.textField?.stringValue = FileManager.default.displayName(atPath: node.url.path)
        cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize, weight: isCurrent ? .semibold : .regular)
        cell.imageView?.isHidden = node.isFolder
        cell.openDot.isHidden = !openURLs.contains(url)
        cell.toolTip = node.url.lastPathComponent
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = GuideRowView()
        row.level = outlineView.level(forItem: item)
        row.indent = outlineView.indentationPerLevel
        return row
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        FileTreeRoot.expanded.insert(node.url.path)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        FileTreeRoot.expanded.remove(node.url.path)
    }
}

/// 사이드바: 위쪽 Contents | Files 전환, 아래에 목차 또는 파일 트리.
final class SidebarViewController: NSViewController {
    // 예전 Pages(썸네일) 탭 자리를 Contents가 이어받아서, 저장된 탭 번호 0은 Contents로 연다.
    private enum Tab: Int { case contents, files }
    private static let tabKey = "sidebarTab"

    let files = FileTreeView()
    private let contents: ContentsView
    private let tabs = NSSegmentedControl(labels: ["Contents", "Files"], trackingMode: .selectOne, target: nil, action: nil)

    init(pdfView: PDFView) {
        contents = ContentsView(pdfView: pdfView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 사이드바는 창 꼭대기(신호등·툴바 뒤)까지 깔린다. Pages/Files는 오른쪽 탭 막대와 같은 줄 가운데에 두고,
    /// 탭 막대가 없으면(전체 화면 등) 툴바 바로 아래(콘텐츠 영역 맨 위)에 둔다.
    private var tabsTop: NSLayoutConstraint!

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let window = view.window, let tabsTop else { return }
        let top: CGFloat
        if let bar = tabBarFrame(in: window) {
            top = view.bounds.maxY - (bar.midY + tabs.fittingSize.height / 2)
        } else {
            top = view.bounds.maxY - view.convert(window.contentLayoutRect, from: nil).maxY + 8
        }
        // 레이아웃 중에 상수를 바꾸면 다시 레이아웃되므로 값이 달라질 때만 바꾼다.
        if abs(tabsTop.constant - top) > 0.5 { tabsTop.constant = top }
    }

    /// 창의 탭 막대(시스템 뷰)를 이 뷰 좌표로. 안 보이면 nil. 공개 API가 없어 뷰 계층에서 클래스 이름으로 찾는다.
    private func tabBarFrame(in window: NSWindow) -> NSRect? {
        guard let frameView = window.contentView?.superview else { return nil }
        func find(_ v: NSView) -> NSView? {
            if v === window.contentView { return nil }
            if NSStringFromClass(type(of: v)).contains("TabBar"), !v.isHiddenOrHasHiddenAncestor, v.frame.height > 0 {
                return v
            }
            return v.subviews.lazy.compactMap(find).first
        }
        guard let bar = find(frameView) else { return nil }
        return view.convert(bar.bounds, from: bar)
    }

    var showsFiles: Bool { tabs.selectedSegment == Tab.files.rawValue }
    /// PDF 없는 새 탭: 넘겨 볼 페이지가 없으니 Files만 보인다(고른 탭으로 기억하지는 않음).
    var isStartPage = false

    override func loadView() {
        let view = NSView()
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        tabs.controlSize = .small
        tabs.segmentDistribution = .fillEqually
        for sub in [tabs, contents, files] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        // self.view는 아직 없으므로(접근하면 loadView가 다시 불린다) 지역 view에 건다.
        tabsTop = tabs.topAnchor.constraint(equalTo: view.topAnchor, constant: 8)
        var constraints = [
            tabsTop!,
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
        ]
        for content in [contents, files] as [NSView] {
            constraints += [
                content.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        self.view = view
        tabs.setEnabled(!isStartPage, forSegment: Tab.contents.rawValue)
        show(isStartPage ? .files : Tab(rawValue: UserDefaults.standard.integer(forKey: Self.tabKey)) ?? .contents)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let tab = Tab(rawValue: sender.selectedSegment) ?? .contents
        UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey)
        show(tab)
    }

    private func show(_ tab: Tab) {
        tabs.selectedSegment = tab.rawValue
        contents.isHidden = tab != .contents
        files.isHidden = tab != .files
        if tab == .files { files.reload(revealDocument: true) }
    }
}
