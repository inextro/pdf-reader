import AppKit
import PaperMarkLibrary

/// 라이브러리 창 하나: 왼쪽 사이드바(컬렉션·태그), 오른쪽 서지 표, 툴바 검색.
final class LibraryWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    private let sidebar = LibrarySidebarView()
    private let libraryView = LibraryView()
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .init("search"))

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
        split.splitView.autosaveName = "LibrarySplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 700))

        let toolbar = NSToolbar(identifier: "PaperLibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        searchItem.searchField.placeholderString = "Search Library"
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.searchField.delegate = self

        sidebar.onSelect = { [weak self] in self?.libraryView.filter = $0 }
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

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchItem.searchField)
    }

    func controlTextDidChange(_ notification: Notification) {
        libraryView.query = searchItem.searchField.stringValue
    }

    // MARK: NSToolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, searchItem.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        itemIdentifier == searchItem.itemIdentifier ? searchItem : nil
    }
}
