import AppKit
import PaperMarkLibrary
import Reader

/// 서재 칸: 왼쪽 사이드바(컬렉션·태그), 가운데 서지 표, 오른쪽 정보 패널, 툴바 검색.
/// Quillo 창의 탭 막대 맨 앞에 고정된다.
final class LibraryPane: Pane, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    private let sidebar = LibrarySidebarView()
    private let libraryView = LibraryView()
    private let infoView = ItemInfoView()
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .init("search"))
    private let addItem = NSToolbarItem(itemIdentifier: .init("addByIdentifier"))
    private let addPopover = NSPopover()
    /// 정보 패널 버튼. 기본 아이콘(sidebar.right)은 왼쪽 사이드바 버튼을 뒤집은 모양이라 구별되는 info 아이콘을 쓴다.
    private let infoToggleItem = NSToolbarItem(itemIdentifier: .init("toggleInfo"))
    private var newFilesSheet: NewFilesSheet?
    private var infoItem: NSSplitViewItem!
    /// 고른 논문이 없어 정보 패널을 접었다. 다시 고르면 편다(사용자가 직접 접은 것은 그대로 둔다).
    /// 정보 패널을 펴는 것은 고른 논문이 바뀔 때만이다(내용만 바뀌었을 때는 정보 버튼으로 접은 상태를 둔다).
    private var shownIDs: Set<Int64> = []

    private let split = NSSplitViewController()

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Quillo"

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: Self.controller(for: sidebar))
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 360
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: Self.controller(for: libraryView)))
        // 오른쪽 정보 패널. 툴바 버튼이나 View > Show Inspector(⌥⌘I)로 접고 편다.
        infoItem = NSSplitViewItem(inspectorWithViewController: Self.controller(for: infoView))
        infoItem.minimumThickness = 280
        infoItem.maximumThickness = 560
        infoItem.preferredThicknessFraction = 0.28
        split.addSplitViewItem(infoItem)
        split.splitView.autosaveName = "LibrarySplit"
        addChild(split)

        let toolbar = NSToolbar(identifier: "PaperLibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        self.toolbar = toolbar
        searchItem.searchField.font = Style.font
        searchItem.searchField.controlSize = .large
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.searchField.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(searchSettingsChanged),
                                               name: Settings.searchDidChange, object: nil)
        searchSettingsChanged()

        infoToggleItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Show Info")
        infoToggleItem.label = "Info"
        infoToggleItem.toolTip = "Show or hide paper info"
        infoToggleItem.action = #selector(NSSplitViewController.toggleInspector(_:))
        infoToggleItem.isNavigational = false

        addItem.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Add by Identifier")
        addItem.label = "Add by Identifier"
        addItem.toolTip = "Add papers by DOI or arXiv ID (metadata only)"
        addItem.target = self
        addItem.action = #selector(addByIdentifier(_:))
        let adder = AddByIdentifierController()
        adder.collection = { [weak self] in
            if case .collection(let id) = self?.sidebar.selection { return id }
            return nil
        }
        adder.onAdded = { [weak self] ids in self?.libraryView.select(itemIDs: ids) }
        adder.close = { [weak self] in self?.addPopover.performClose(nil) }
        addPopover.contentViewController = adder
        addPopover.behavior = .transient

        sidebar.onSelect = { [weak self] in
            self?.libraryView.filter = $0
            LibraryStore.shared.selectedCollection = if case .collection(let id) = $0 { id } else { nil }
        }
        sidebar.onNewFiles = { [weak self] in self?.showNewFiles() }
        libraryView.onSelectionChange = { [weak self] in
            self?.infoView.show($0)
            self?.updateInfoPanel(selection: Set($0.map(\.id)))
        }
        libraryView.onCountChange = { [weak self] count in
            self?.windowSubtitle = "\(count) item\(count == 1 ? "" : "s")"
        }
        libraryView.filter = sidebar.selection
        LibraryStore.shared.selectedCollection = if case .collection(let id) = sidebar.selection { id } else { nil }
        windowSubtitle = "\(LibraryStore.shared.items.count) items"
        updateInfoPanel(selection: Set(libraryView.selectedItems.map(\.id)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        // 분할 뷰를 감싸는 뷰를 둔다. 이 칸이 응답자 체인에서 분할 뷰 컨트롤러 뒤에 오게 한다.
        let view = NSView()
        split.view.frame = view.bounds
        split.view.autoresizingMask = [.width, .height]
        view.addSubview(split.view)
        self.view = view
    }

    // MARK: 칸

    override var showsWindowTitle: Bool { true }
    override var tabTitle: String { "Library" }
    override var tabImage: NSImage? { NSImage(systemSymbolName: "books.vertical", accessibilityDescription: "Library") }
    override var tabToolTip: String? { "Library (⌘L)" }
    /// ⌘Z가 라이브러리 지우기를 되돌리도록 LibraryStore의 실행 취소 기록을 쓴다.
    override var paneUndoManager: UndoManager? { LibraryStore.shared.undoManager }
    override var preferredFirstResponder: NSView? { libraryView.tableView }

    /// 서재 사이드바는 PDF 탭의 사이드바와 따로 접고 편다(분할 뷰가 상태를 기억한다).
    @objc func toggleSidebar(_ sender: Any?) { split.toggleSidebar(sender) }
    @objc func toggleInspector(_ sender: Any?) { split.toggleInspector(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSidebar(_:)):
            item.title = split.splitViewItems.first?.isCollapsed == true ? "Show Sidebar" : "Hide Sidebar"
        case #selector(toggleInspector(_:)):
            item.title = infoItem.isCollapsed ? "Show Inspector" : "Hide Inspector"
        default:
            break
        }
        return true
    }

    private var window: NSWindow? { viewIfLoaded?.window }

    private static func controller(for view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    /// 정보 패널은 늘 펴 둔다(고른 논문이 없으면 “No Item Selected”). 정보 버튼으로 접었어도 다른 논문을 고르면 다시 편다.
    private func updateInfoPanel(selection: Set<Int64>) {
        defer { shownIDs = selection }
        if !selection.isEmpty, selection != shownIDs, infoItem.isCollapsed {
            infoItem.animator().isCollapsed = false
        }
    }

    private func showNewFiles() {
        guard let window, newFilesSheet == nil else { return }
        guard !LibraryStore.shared.newFiles.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No unlinked PDFs"
            alert.informativeText = "Every PDF in your workspace folder is already in the library. PDFs you add to the folder in Finder appear here."
            alert.beginSheetModal(for: window)
            return
        }
        let sheet = NewFilesSheet(files: LibraryStore.shared.newFiles)
        sheet.onAdded = { [weak self] ids in self?.libraryView.select(itemIDs: Set(ids)) }
        newFilesSheet = sheet
        window.beginSheet(sheet.window!) { [weak self] _ in self?.newFilesSheet = nil }
    }

    @objc func addByIdentifier(_ sender: Any?) {
        // 다른 탭을 보고 있으면 서재 칸으로 먼저 간다(툴바의 버튼에 팝오버를 붙인다).
        if window == nil { host?.showLibrary(nil) }
        guard window != nil else { return }
        if addPopover.isShown { addPopover.performClose(nil) } else { addPopover.show(relativeTo: addItem) }
    }

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchItem.searchField)
    }

    /// 돋보기를 누르면 찾을 칸과 범위를 고르는 메뉴. 안내 글자에 지금 찾는 칸을 보인다.
    @objc private func searchSettingsChanged() {
        let fields = Settings.searchFields
        let field = searchItem.searchField
        field.placeholderString = "Search " + fields.map(\.title).joined(separator: ", ")
        let menu = NSMenu()
        menu.font = Style.font
        menu.addItem(withTitle: "Search In", action: nil, keyEquivalent: "")
        for f in SearchField.allCases {
            let item = menu.addItem(withTitle: f.title, action: #selector(toggleSearchField(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = f.rawValue
            item.state = fields.contains(f) ? .on : .off
            item.indentationLevel = 1
        }
        menu.addItem(.separator())
        let scope = menu.addItem(withTitle: "Only in Selected Collection or Tag", action: #selector(toggleSearchScope(_:)), keyEquivalent: "")
        scope.target = self
        scope.state = Settings.searchWithinSelection ? .on : .off
        let restore = menu.addItem(withTitle: "Restore Defaults", action: #selector(restoreSearch(_:)), keyEquivalent: "")
        restore.target = self
        field.searchMenuTemplate = menu
    }

    @objc private func toggleSearchField(_ sender: NSMenuItem) {
        guard let f = (sender.representedObject as? String).flatMap(SearchField.init) else { return }
        var fields = Settings.searchFields
        if let i = fields.firstIndex(of: f) {
            guard fields.count > 1 else { return }  // 하나는 남긴다.
            fields.remove(at: i)
        } else {
            fields = SearchField.allCases.filter { fields.contains($0) || $0 == f }
        }
        Settings.searchFields = fields
    }

    @objc private func toggleSearchScope(_ sender: Any?) { Settings.searchWithinSelection.toggle() }

    @objc private func restoreSearch(_ sender: Any?) {
        Settings.searchFields = SearchField.defaults
        Settings.searchWithinSelection = false
    }

    func controlTextDidChange(_ notification: Notification) {
        libraryView.query = searchItem.searchField.stringValue
    }

    // MARK: NSToolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // 정보 버튼은 검색 칸 바로 옆에 둔다. 정보 패널 위로 툴바를 나누면(inspectorTrackingSeparator)
        // 패널이 열렸을 때 버튼만 패널 위 빈 줄에 따로 남는다.
        [.quilloSidebar, .flexibleSpace, addItem.itemIdentifier, searchItem.itemIdentifier,
         infoToggleItem.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == .quilloSidebar { return .quilloSidebar() }
        return [searchItem, addItem, infoToggleItem].first { $0.itemIdentifier == itemIdentifier }
    }
}
