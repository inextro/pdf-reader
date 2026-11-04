import AppKit
import AppUpdater

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var libraryWindow = LibraryWindowController()
    private lazy var settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        showLibrary(nil)
        // 브라우저 확장이 논문을 보내는 로컬 서버
        Connector.shared.start()
        // workspace 폴더와 컬렉션을 맞추고 폴더를 감시한다.
        LibraryStore.shared.startWorkspaceSync()
        // 앱이 업데이트되어 확장 파일이 바뀌었으면 Chrome에서 Reload를 눌러야 새 확장이 돈다.
        let extensionUpdated = ChromeExtension.refresh()
        // workspace가 없으면 쓸 수 없다(컬렉션 = 그 안의 폴더, PDF도 거기 둔다). 고를 때까지 묻고, 고른 뒤에 확장 설치를 권한다.
        DispatchQueue.main.async {
            self.requireWorkspace {
                if extensionUpdated { ChromeExtension.announceUpdate(in: self.libraryWindow.window) }
                ChromeExtension.offerOnFirstLaunch(in: self.libraryWindow.window)
                // 새 버전 확인(켤 때 잠시 뒤 한 번, 그 뒤 하루마다). workspace를 고르는 중에는 묻지 않는다.
                UpdateController.shared.start()
            }
        }
    }

    /// workspace를 정하지 않았으면 고르게 한다. 폴더를 고르거나 Zotero에서 가져와야 넘어가고, 아니면 앱을 끈다.
    private func requireWorkspace(then next: @escaping () -> Void) {
        guard LibraryStore.shared.folder == nil else { next(); return }
        guard let window = libraryWindow.window else { return }
        let again = { DispatchQueue.main.async { self.requireWorkspace(then: next) } }
        let alert = NSAlert()
        alert.messageText = "Choose your workspace folder"
        alert.informativeText = "PaperLibrary keeps your papers in a folder you choose, for example in Google Drive. "
            + "Each collection is a folder inside it, and PDFs are saved there.\n\n"
            + "Choose a folder to start, or import your Zotero library (its PDF folder becomes the workspace)."
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Import from Zotero…")
        alert.addButton(withTitle: "Quit")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                DispatchQueue.main.async {
                    let panel = NSOpenPanel()
                    panel.message = "Choose your workspace folder. Its subfolders are your collections."
                    panel.prompt = "Choose"
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.directoryURL = LibraryStore.googleDriveFolder()
                    panel.beginSheetModal(for: window) { result in
                        if result == .OK, let url = panel.url { LibraryStore.shared.folder = url }
                        again()
                    }
                }
            case .alertSecondButtonReturn:
                DispatchQueue.main.async { LibraryStore.shared.importFromZotero(in: window, finished: again) }
            default:
                NSApp.terminate(nil)
            }
        }
    }

    /// `paperlibrary://`: 확장 팝업의 "Open PaperLibrary" 버튼이 앱을 켤 때 쓴다.
    func application(_ application: NSApplication, open urls: [URL]) {
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

    @objc private func addByIdentifier(_ sender: Any?) {
        showLibrary(nil)
        libraryWindow.addByIdentifier(sender)
    }

    @objc private func showSettings(_ sender: Any?) {
        settingsWindow.showWindow(nil)
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

    @objc private func installChromeExtension(_ sender: Any?) {
        ChromeExtension.install(in: NSApp.mainWindow)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(of: main, title: "PaperLibrary")
        app.addItem(withTitle: "About PaperLibrary", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "")
            .target = MainActor.assumeIsolated { UpdateController.shared }
        app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(withTitle: "Install Chrome Extension…", action: #selector(installChromeExtension(_:)), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide PaperLibrary", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit PaperLibrary", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(of: main, title: "File")
        file.addItem(withTitle: "Add by Identifier…", action: #selector(addByIdentifier(_:)), keyEquivalent: "N").target = self
        file.addItem(.separator())
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
        edit.addItem(withTitle: "Copy Citation", action: #selector(LibraryView.copyCitation(_:)), keyEquivalent: "C")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Delete…", action: #selector(LibraryView.deletePapers(_:)), keyEquivalent: "\u{8}")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(LibraryWindowController.focusSearch(_:)), keyEquivalent: "f")

        let view = submenu(of: main, title: "View")
        view.addItem(withTitle: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        view.addItem(withTitle: "Show Inspector", action: #selector(NSSplitViewController.toggleInspector(_:)), keyEquivalent: "i")
            .keyEquivalentModifierMask = [.command, .option]

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
