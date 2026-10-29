import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var libraryWindow = LibraryWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        showLibrary(nil)
    }

    /// 창을 닫아도 앱은 남는다. Dock 아이콘을 누르면 다시 보인다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary(nil) }
        return false
    }

    @objc private func showLibrary(_ sender: Any?) {
        libraryWindow.showWindow(nil)
    }

    @objc private func importFromZotero(_ sender: Any?) {
        showLibrary(nil)
        LibraryStore.shared.importFromZotero(in: libraryWindow.window)
    }

    /// PDF가 있는 폴더를 바꾼다. DB의 PDF 경로는 이 폴더 기준이라, PDF 폴더를 옮겼을 때 쓴다.
    @objc private func changeFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder that holds your library PDFs."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = LibraryStore.shared.folder ?? LibraryStore.googleDriveFolder()
        guard let window = libraryWindow.window else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { LibraryStore.shared.folder = url }
        }
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(of: main, title: "PaperLibrary")
        app.addItem(withTitle: "About PaperLibrary", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide PaperLibrary", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit PaperLibrary", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(of: main, title: "File")
        file.addItem(withTitle: "Import from Zotero…", action: #selector(importFromZotero(_:)), keyEquivalent: "I").target = self
        file.addItem(withTitle: "Change PDF Folder…", action: #selector(changeFolder(_:)), keyEquivalent: "").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(of: main, title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(LibraryWindowController.focusSearch(_:)), keyEquivalent: "f")

        let view = submenu(of: main, title: "View")
        view.addItem(withTitle: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]

        let window = submenu(of: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Library", action: #selector(showLibrary(_:)), keyEquivalent: "0").target = self
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private func submenu(of main: NSMenu, title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }
}
