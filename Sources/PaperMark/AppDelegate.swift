import AppKit

/// 첫 열기 창을 Google Drive 폴더에서 시작하게 한다. 이후에는 마지막으로 연 폴더를 시스템이 기억한다.
final class PMDocumentController: NSDocumentController {
    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        let key = "didSuggestDriveFolder"
        if !UserDefaults.standard.bool(forKey: key), let drive = Self.googleDriveFolder() {
            openPanel.directoryURL = drive
            UserDefaults.standard.set(true, forKey: key)
        }
        super.beginOpenPanel(openPanel, forTypes: inTypes, completionHandler: completionHandler)
    }

    static func googleDriveFolder() -> URL? {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let drive = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix("GoogleDrive-") }) else { return nil }
        let myDrive = drive.appendingPathComponent("My Drive")
        return FileManager.default.fileExists(atPath: myDrive.path) ? myDrive : drive
    }
}

/// 앱을 다시 열 때 이어 볼 파일과 파일마다 마지막으로 보던 페이지.
/// 창을 직접 닫으면(⌘W, 닫기 버튼) 목록에서 빼고, 앱을 끄면서 닫히는 창은 남긴다.
enum Session {
    private static let filesKey = "openFiles", pagesKey = "lastPages"
    private static var defaults: UserDefaults { .standard }

    static var files: [URL] { (defaults.stringArray(forKey: filesKey) ?? []).map { URL(fileURLWithPath: $0) } }

    static func didOpen(_ url: URL) {
        var paths = defaults.stringArray(forKey: filesKey) ?? []
        if !paths.contains(url.path) { paths.append(url.path) }
        defaults.set(paths, forKey: filesKey)
    }

    static func didCloseByUser(_ url: URL) {
        defaults.set((defaults.stringArray(forKey: filesKey) ?? []).filter { $0 != url.path }, forKey: filesKey)
    }

    static func lastPage(of url: URL) -> Int? {
        (defaults.dictionary(forKey: pagesKey)?[url.path] as? Int)
    }

    static func setLastPage(_ page: Int, of url: URL) {
        var pages = defaults.dictionary(forKey: pagesKey) ?? [:]
        pages[url.path] = page
        defaults.set(pages, forKey: pagesKey)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let highlightMenu = NSMenu(title: "Highlight")
    private var colorItems: [NSMenuItem] = []
    private var commandItems: [Command: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildColorItems),
                                               name: ColorStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyShortcuts),
                                               name: ShortcutStore.didChange, object: nil)
        applyShortcuts()
        MainActor.assumeIsolated { UpdateController.shared.start() }
        // Dock에서 그냥 실행했을 때는 직전 파일을 다시 연다(파일을 더블클릭해 실행한 경우 제외).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if NSDocumentController.shared.documents.isEmpty { self.reopenLastFiles() }
        }
    }

    /// 작업 폴더(파일 트리 root)의 파일 트리를 보여 주는 새 탭을 먼저 열고, 앱을 끌 때 열려 있던 파일들을 다시 연다.
    /// 다시 연 파일은 새 탭 왼쪽에 붙어서 새 탭은 맨 오른쪽에 남는다.
    /// 다시 열 파일이 없으면 가장 최근 파일을 연다.
    private func reopenLastFiles() {
        askWorkingFolderOnce {
            self.openStartTab()
            let controller = NSDocumentController.shared
            let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
            var urls = Session.files.filter(exists)
            if urls.isEmpty, let recent = controller.recentDocumentURLs.first(where: exists) { urls = [recent] }
            for url in urls {
                controller.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }
    }

    /// 작업 폴더를 정한 적이 없으면 처음 한 번만 묻는다. 취소하거나 사이드바에서 root를 풀면 다시 묻지 않는다.
    private func askWorkingFolderOnce(then next: @escaping () -> Void) {
        let key = "didAskWorkingFolder"
        guard FileTreeRoot.url == nil, !UserDefaults.standard.bool(forKey: key) else { next(); return }
        UserDefaults.standard.set(true, forKey: key)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = PMDocumentController.googleDriveFolder()
        panel.begin { response in
            if response == .OK, let url = panel.url { FileTreeRoot.url = url }
            next()
        }
    }

    /// 탭 막대의 + 버튼과 같은 PDF 없는 새 탭(작업 폴더의 파일 트리와 열기 버튼).
    private func openStartTab() {
        do {
            _ = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        } catch {
            NSApp.presentError(error)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openStartTab() }
        return false
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(of: main, title: "PaperMark")
        app.addItem(withTitle: "About PaperMark", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        // 메뉴는 앱을 켤 때 메인 스레드에서 만든다.
        app.addItem(withTitle: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "")
            .target = MainActor.assumeIsolated { UpdateController.shared }
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide PaperMark", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit PaperMark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(of: main, title: "File")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recentItem = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "Open Recent")
        // AppKit이 이 메뉴를 최근 문서 목록으로 채우게 하는 비공개 표식. 없으면 그냥 빈 메뉴로 남는다.
        let marker = NSSelectorFromString("_setMenuName:")
        if recent.responds(to: marker) { recent.perform(marker, with: "NSRecentDocumentsMenu") }
        recent.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recentItem.submenu = recent
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")

        let edit = submenu(of: main, title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(DocumentWindowController.focusSearch(_:)), .find)
        add(edit, "Find Next", #selector(DocumentWindowController.findNextResult(_:)), .findNext)
        add(edit, "Find Previous", #selector(DocumentWindowController.findPreviousResult(_:)), .findPrevious)

        main.addItem(withTitle: "Highlight", action: nil, keyEquivalent: "").submenu = highlightMenu
        add(highlightMenu, "Highlight Selection", #selector(DocumentWindowController.highlightSelection(_:)), .highlightSelection)
        add(highlightMenu, "Highlight Mode", #selector(DocumentWindowController.toggleHighlightMode(_:)), .highlightMode)
        add(highlightMenu, "Eraser Mode", #selector(DocumentWindowController.toggleEraserMode(_:)), .eraserMode)
        add(highlightMenu, "Translate Selection", #selector(DocumentWindowController.translateSelection(_:)), .translate)
        add(highlightMenu, "Remove Current Color from Presets", #selector(removeCurrentColor(_:)), .removeCurrentColor)
        commandItems[.removeCurrentColor]?.target = self

        let view = submenu(of: main, title: "View")
        add(view, "Show Sidebar", #selector(DocumentWindowController.toggleSidebar(_:)), .toggleSidebar)
        view.addItem(.separator())
        add(view, "Zoom In", #selector(DocumentWindowController.zoomInPDF(_:)), .zoomIn)
        add(view, "Zoom Out", #selector(DocumentWindowController.zoomOutPDF(_:)), .zoomOut)
        add(view, "Zoom to Fit", #selector(DocumentWindowController.zoomToFit(_:)), .zoomToFit)

        let go = submenu(of: main, title: "Go")
        add(go, "Back", #selector(DocumentWindowController.goBack(_:)), .goBack)
        add(go, "Forward", #selector(DocumentWindowController.goForward(_:)), .goForward)

        let window = submenu(of: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    /// 프리셋 색마다 Color 1~9 메뉴 항목을 만든다. 프리셋이나 현재 색이 바뀌면 다시 만든다.
    @objc private func rebuildColorItems() {
        colorItems.forEach(highlightMenu.removeItem)
        colorItems = [.separator()]
        let store = ColorStore.shared
        for (i, hex) in store.presets.enumerated() {
            guard let color = NSColor(hex: hex) else { continue }
            let item = NSMenuItem(title: "Color \(i + 1)  \(hex)", action: #selector(selectPresetColor(_:)),
                                  keyEquivalent: "")
            if let command = Command.color(i) { ShortcutStore.shared.apply(command, to: item) }
            item.target = self
            item.tag = i
            item.image = swatchImage(color)
            item.state = hex == store.currentHex ? .on : .off
            colorItems.append(item)
        }
        colorItems.forEach(highlightMenu.addItem)
    }

    /// 단축키를 바꿀 수 있는 메뉴 항목을 만든다. 키는 applyShortcuts가 넣는다.
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ command: Command) {
        commandItems[command] = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
    }

    @objc private func applyShortcuts() {
        for (command, item) in commandItems { ShortcutStore.shared.apply(command, to: item) }
        rebuildColorItems()
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(sender)
    }

    @objc private func removeCurrentColor(_ sender: Any?) {
        ColorStore.shared.removePreset(ColorStore.shared.currentHex)
    }

    @objc private func selectPresetColor(_ sender: NSMenuItem) {
        let presets = ColorStore.shared.presets
        guard presets.indices.contains(sender.tag) else { return }
        ColorStore.shared.currentHex = presets[sender.tag]
    }

    private func submenu(of main: NSMenu, title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }
}
