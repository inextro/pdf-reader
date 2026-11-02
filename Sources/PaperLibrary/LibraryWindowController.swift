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
        let infoItem = NSSplitViewItem(inspectorWithViewController: Self.controller(for: infoView))
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
        searchItem.searchField.placeholderString = "Search Library"
        searchItem.searchField.font = Style.font
        searchItem.searchField.controlSize = .large
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.searchField.delegate = self

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
        libraryView.onSelectionChange = { [weak self] in self?.infoView.show($0) }
        libraryView.onCountChange = { [weak window] count in
            window?.subtitle = "\(count) item\(count == 1 ? "" : "s")"
        }
        libraryView.filter = sidebar.selection
        window.subtitle = "\(LibraryStore.shared.items.count) items"

        window.center()
        window.setFrameAutosaveName("LibraryWindow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func controller(for view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    @objc func addByIdentifier(_ sender: Any?) {
        guard let window else { return }
        if !window.isVisible { showWindow(nil) }
        if addPopover.isShown { addPopover.performClose(nil) } else { addPopover.show(relativeTo: addItem) }
    }

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchItem.searchField)
    }

    func controlTextDidChange(_ notification: Notification) {
        libraryView.query = searchItem.searchField.stringValue
    }

    // MARK: NSToolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, addItem.itemIdentifier, searchItem.itemIdentifier,
         .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        [searchItem, addItem].first { $0.itemIdentifier == itemIdentifier }
    }
}
