import AppKit
import AppUpdater
import PaperMarkLibrary
import Reader

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var library = LibraryPane()
    /// Quillo 창: 탭 막대 맨 앞에 서재 칸, 그 뒤로 PDF 탭.
    private lazy var mainWindow = TabbedWindowController(pinned: library)
    private lazy var settingsWindow = SettingsWindowController()

    // 켜지는 동안(첫 0.5초) 받은 PDF를 모두 Preview로 넘겼으면, Quillo는 창 없이 다시 꺼진다.
    private var isLaunching = true, receivedPDFsAtLaunch = false, forwardedOnly = false
    private var pendingForwards = 0, quitAfterForwarding = false
    private var started = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 메뉴(색, 단축키)가 설정을 읽기 전에 PaperMark 설정을 가져온다.
        PaperMarkSettings.importOnce()
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard receivedPDFsAtLaunch else {
            isLaunching = false
            start()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isLaunching = false
            if self.forwardedOnly, !self.started {
                // PDF를 Preview로 넘기려고만 켜졌다.
                self.quitAfterForwarding = true
                if self.pendingForwards == 0 { NSApp.terminate(nil) }
                return
            }
            self.start()
        }
    }

    /// 창을 띄우고 서재 일(확장 서버, workspace 감시, 업데이트 확인)을 시작한다. 지난번에 열려 있던 PDF도 다시 연다.
    private func start() {
        guard !started else { return }
        started = true
        showLibrary(nil)
        reopenLastPDFs()
        // 브라우저 확장이 논문을 보내는 로컬 서버
        Connector.shared.start()
        // workspace 폴더와 컬렉션을 맞추고 폴더를 감시한다.
        LibraryStore.shared.startWorkspaceSync()
        // 앱이 업데이트되어 확장 파일이 바뀌었으면 Chrome에서 Reload를 눌러야 새 확장이 돈다.
        let extensionUpdated = ChromeExtension.refresh()
        // workspace가 없으면 쓸 수 없다(컬렉션 = 그 안의 폴더, PDF도 거기 둔다). 고를 때까지 묻고, 고른 뒤에 확장 설치를 권한다.
        DispatchQueue.main.async {
            self.requireWorkspace {
                if extensionUpdated { ChromeExtension.announceUpdate(in: self.mainWindow.window) }
                ChromeExtension.offerOnFirstLaunch(in: self.mainWindow.window)
                // 새 버전 확인(켤 때 잠시 뒤 한 번, 그 뒤 하루마다). workspace를 고르는 중에는 묻지 않는다.
                UpdateController.shared.start()
                // 예전에 저장한 학술지 논문의 논문 번호(한 번만).
                LibraryStore.shared.fillArticleNumbers()
                // workspace 안의 PDF는 Quillo로, 나머지는 Preview로 열지 처음 한 번 묻는다.
                DefaultPDFApp.askOnce()
            }
        }
    }

    /// 앱을 끌 때 열려 있던 PDF를 탭으로 다시 붙인다. 고르지는 않아서 서재 칸이 앞에 있다.
    private func reopenLastPDFs() {
        for url in Session.files where FileManager.default.fileExists(atPath: url.path) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, _, error in
                if let error { NSLog("%@", "Quillo: could not reopen \(url.lastPathComponent): \(error)") }
                document?.makeWindowControllers()
            }
        }
    }

    /// workspace를 정하지 않았으면 고르게 한다. 폴더를 고르거나 Zotero에서 가져와야 넘어가고, 아니면 앱을 끈다.
    private func requireWorkspace(then next: @escaping () -> Void) {
        guard LibraryStore.shared.folder == nil else { next(); return }
        guard let window = mainWindow.window else { return }
        let again = { DispatchQueue.main.async { self.requireWorkspace(then: next) } }
        let alert = NSAlert()
        alert.messageText = "Choose your workspace folder"
        alert.informativeText = "Quillo keeps your papers in a folder you choose, for example in Google Drive. "
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

    /// PDF 파일(Finder, Raycast, 다음으로 열기)과 `paperlibrary://`(확장 팝업의 "Open Quillo" 버튼).
    /// Quillo가 기본 PDF 앱으로 받은 workspace 밖의 PDF는 Preview로 넘긴다.
    func application(_ application: NSApplication, open urls: [URL]) {
        let pdfs = urls.filter(\.isFileURL)
        if pdfs.count < urls.count {
            forwardedOnly = false
            if started { showLibrary(nil) } else if !isLaunching { start() }
        }
        guard !pdfs.isEmpty else { return }
        let (open, forward) = DefaultPDFApp.split(pdfs, sender: DefaultPDFApp.currentSender)
        if isLaunching {
            receivedPDFsAtLaunch = true
            forwardedOnly = open.isEmpty && (forwardedOnly || !started)
        }
        if !open.isEmpty {
            start()
            for url in open {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            }
        }
        guard !forward.isEmpty else { return }
        pendingForwards += 1
        DefaultPDFApp.forward(forward) { [self] in
            pendingForwards -= 1
            if quitAfterForwarding, pendingForwards == 0 { NSApp.terminate(nil) }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// 창을 닫아도 앱은 남는다. Dock 아이콘을 누르면 다시 보인다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if started { mainWindow.showWindow(nil) } else { start() }
        }
        return false
    }

    // MARK: 서재 칸

    /// Window > Library(⌘L): 서재 칸으로 가서 창을 앞으로.
    @objc func showLibrary(_ sender: Any?) {
        mainWindow.showLibrary(sender)
    }

    @objc private func askDefaultPDFApp(_ sender: Any?) { DefaultPDFApp.ask() }

    @objc private func addByIdentifier(_ sender: Any?) {
        showLibrary(nil)
        library.addByIdentifier(sender)
    }

    @objc private func showSettings(_ sender: Any?) {
        settingsWindow.showWindow(nil)
    }

    @objc private func importFromZotero(_ sender: Any?) {
        showLibrary(nil)
        LibraryStore.shared.importFromZotero(in: mainWindow.window)
    }

    /// PDF가 있는 폴더를 바꾼다. DB의 PDF 경로는 이 폴더 기준이라, PDF 폴더를 옮겼을 때 쓴다.
    @objc private func changeFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder that holds your library PDFs."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = LibraryStore.shared.folder ?? LibraryStore.googleDriveFolder()
        guard let window = mainWindow.window else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { LibraryStore.shared.folder = url }
        }
    }

    @objc private func installChromeExtension(_ sender: Any?) {
        ChromeExtension.install(in: NSApp.mainWindow)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(of: main, title: "Quillo")
        app.addItem(withTitle: "About Quillo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "")
            .target = MainActor.assumeIsolated { UpdateController.shared }
        app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(withTitle: "Default PDF App…", action: #selector(askDefaultPDFApp(_:)), keyEquivalent: "").target = self
        app.addItem(withTitle: "Install Chrome Extension…", action: #selector(installChromeExtension(_:)), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Quillo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Quillo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let reader = ReaderMenus.shared
        let file = submenu(of: main, title: "File")
        reader.addOpenItems(to: file)
        file.addItem(.separator())
        file.addItem(withTitle: "Add by Identifier…", action: #selector(addByIdentifier(_:)), keyEquivalent: "N").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Import from Zotero…", action: #selector(importFromZotero(_:)), keyEquivalent: "I").target = self
        file.addItem(withTitle: "Change PDF Folder…", action: #selector(changeFolder(_:)), keyEquivalent: "").target = self
        file.addItem(.separator())
        // ⌘W는 PDF 탭을 닫는다(서재 칸에서는 창을 닫는다). 창을 닫아도 탭은 그대로 남는다.
        file.addItem(withTitle: "Close Tab", action: #selector(TabbedWindowController.closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")

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
        // Find…는 서재 탭에서는 서재 검색, PDF 탭에서는 문서 검색으로 간다(둘 다 focusSearch:).
        reader.addFindItems(to: edit)

        main.addItem(withTitle: "Highlight", action: nil, keyEquivalent: "").submenu = reader.makeHighlightMenu()

        let view = submenu(of: main, title: "View")
        reader.addViewItems(to: view)
        view.addItem(.separator())
        view.addItem(withTitle: "Show Inspector", action: #selector(LibraryPane.toggleInspector(_:)), keyEquivalent: "i")
            .keyEquivalentModifierMask = [.command, .option]

        main.addItem(withTitle: "Go", action: nil, keyEquivalent: "").submenu = reader.makeGoMenu()

        let window = submenu(of: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Library", action: #selector(showLibrary(_:)), keyEquivalent: "l").target = self
        window.addItem(withTitle: "Show Previous Tab", action: #selector(TabbedWindowController.selectPreviousPane(_:)), keyEquivalent: "[")
            .keyEquivalentModifierMask = [.command, .shift]
        window.addItem(withTitle: "Show Next Tab", action: #selector(TabbedWindowController.selectNextPane(_:)), keyEquivalent: "]")
            .keyEquivalentModifierMask = [.command, .shift]
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        reader.applyShortcutsNow()
        return main
    }

    private func submenu(of main: NSMenu, title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }
}
