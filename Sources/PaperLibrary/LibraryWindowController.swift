import AppKit
import PaperMarkLibrary

/// 라이브러리 창 하나: 왼쪽 사이드바(컬렉션·태그), 오른쪽 서지 표, 툴바 검색.
final class LibraryWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
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
    private var infoAutoHidden = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "PaperLibrary"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 360)
        super.init(window: window)

        let split = NSSplitViewController()
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
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 700))

        let toolbar = NSToolbar(identifier: "PaperLibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
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

        sidebar.onSelect = { [weak self] in self?.libraryView.filter = $0 }
        sidebar.onNewFiles = { [weak self] in self?.showNewFiles() }
        libraryView.onSelectionChange = { [weak self] in
            self?.infoView.show($0)
            self?.updateInfoPanel(hasSelection: !$0.isEmpty)
        }
        libraryView.onCountChange = { [weak window] count in
            window?.subtitle = "\(count) item\(count == 1 ? "" : "s")"
        }
        libraryView.filter = sidebar.selection
        window.subtitle = "\(LibraryStore.shared.items.count) items"
        updateInfoPanel(hasSelection: !libraryView.selectedItems.isEmpty)

        window.center()
        window.setFrameAutosaveName("LibraryWindow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func controller(for view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    /// 고른 논문이 없으면 정보 패널을 접고, 고르면 다시 편다.
    private func updateInfoPanel(hasSelection: Bool) {
        if !hasSelection, !infoItem.isCollapsed {
            infoAutoHidden = true
            infoItem.animator().isCollapsed = true
        } else if hasSelection, infoAutoHidden {
            infoAutoHidden = false
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
        guard let window else { return }
        if !window.isVisible { showWindow(nil) }
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
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, addItem.itemIdentifier, searchItem.itemIdentifier,
         .inspectorTrackingSeparator, .flexibleSpace, infoToggleItem.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        [searchItem, addItem, infoToggleItem].first { $0.itemIdentifier == itemIdentifier }
    }
}
