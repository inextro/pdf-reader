import AppKit

/// 리더의 문서 컨트롤러. 앱에서 처음 만든 NSDocumentController 인스턴스가 shared가 되므로
/// Quillo의 main.swift가 NSApplication을 돌리기 전에 하나 만든다.
public final class PMDocumentController: NSDocumentController {}

/// 앱을 다시 열 때 이어 볼 파일과 파일마다 마지막으로 보던 페이지.
/// 창을 직접 닫으면(⌘W, 닫기 버튼) 목록에서 빼고, 앱을 끄면서 닫히는 창은 남긴다.
public enum Session {
    private static let filesKey = "openFiles", pagesKey = "lastPages"
    private static var defaults: UserDefaults { .standard }

    public static var files: [URL] { (defaults.stringArray(forKey: filesKey) ?? []).map { URL(fileURLWithPath: $0) } }

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

/// 리더 메뉴 항목. Quillo의 메뉴 막대에 끼워 넣는다. 항목의 target은 비워 두어 응답자 체인으로 가므로
/// PDF 탭에서만 켜지고 서재 탭에서는 흐리게 보인다.
/// 단축키는 리더 설정(ShortcutStore)을 따르고, 바뀌면 다시 넣는다.
@MainActor
public final class ReaderMenus: NSObject {
    public static let shared = ReaderMenus()

    private let highlightMenu = NSMenu(title: "Highlight")
    private var colorItems: [NSMenuItem] = []
    private var commandItems: [Command: NSMenuItem] = [:]

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildColorItems),
                                               name: ColorStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyShortcuts),
                                               name: ShortcutStore.didChange, object: nil)
    }

    /// File 메뉴: Open PDF…, Open Recent.
    public func addOpenItems(to file: NSMenu) {
        file.addItem(withTitle: "Open PDF…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recentItem = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "Open Recent")
        // AppKit이 이 메뉴를 최근 문서 목록으로 채우게 하는 비공개 표식. 없으면 그냥 빈 메뉴로 남는다.
        let marker = NSSelectorFromString("_setMenuName:")
        if recent.responds(to: marker) { recent.perform(marker, with: "NSRecentDocumentsMenu") }
        recent.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recentItem.submenu = recent
    }

    /// Edit 메뉴: Find…, Find Next, Find Previous. Find…는 서재 창에도 같은 이름의 동작(focusSearch:)이 있어 탭마다 맞게 간다.
    public func addFindItems(to edit: NSMenu) {
        add(edit, "Find…", #selector(ReaderPane.focusSearch(_:)), .find)
        add(edit, "Find Next", #selector(ReaderPane.findNextResult(_:)), .findNext)
        add(edit, "Find Previous", #selector(ReaderPane.findPreviousResult(_:)), .findPrevious)
    }

    /// Highlight 메뉴(형광펜, 지우개, 번역, 색 1~9).
    public func makeHighlightMenu() -> NSMenu {
        add(highlightMenu, "Highlight Selection", #selector(ReaderPane.highlightSelection(_:)), .highlightSelection)
        add(highlightMenu, "Highlight Mode", #selector(ReaderPane.toggleHighlightMode(_:)), .highlightMode)
        add(highlightMenu, "Eraser Mode", #selector(ReaderPane.toggleEraserMode(_:)), .eraserMode)
        add(highlightMenu, "Translate Selection", #selector(ReaderPane.translateSelection(_:)), .translate)
        add(highlightMenu, "Remove Current Color from Presets", #selector(removeCurrentColor(_:)), .removeCurrentColor)
        commandItems[.removeCurrentColor]?.target = self
        return highlightMenu
    }

    /// View 메뉴: Show Sidebar(서재 창의 사이드바도 같은 동작 이름이라 탭마다 맞게 간다), 확대·축소.
    public func addViewItems(to view: NSMenu) {
        add(view, "Show Sidebar", #selector(ReaderPane.toggleSidebar(_:)), .toggleSidebar)
        view.addItem(.separator())
        add(view, "Zoom In", #selector(ReaderPane.zoomInPDF(_:)), .zoomIn)
        add(view, "Zoom Out", #selector(ReaderPane.zoomOutPDF(_:)), .zoomOut)
        add(view, "Zoom to Fit", #selector(ReaderPane.zoomToFit(_:)), .zoomToFit)
    }

    /// Go 메뉴: 링크를 따라간 뒤 돌아오기.
    public func makeGoMenu() -> NSMenu {
        let go = NSMenu(title: "Go")
        add(go, "Back", #selector(ReaderPane.goBack(_:)), .goBack)
        add(go, "Forward", #selector(ReaderPane.goForward(_:)), .goForward)
        return go
    }

    /// 메뉴를 다 만든 뒤 한 번 부른다.
    public func applyShortcutsNow() { applyShortcuts() }

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

    @objc private func removeCurrentColor(_ sender: Any?) {
        ColorStore.shared.removePreset(ColorStore.shared.currentHex)
    }

    @objc private func selectPresetColor(_ sender: NSMenuItem) {
        let presets = ColorStore.shared.presets
        guard presets.indices.contains(sender.tag) else { return }
        ColorStore.shared.currentHex = presets[sender.tag]
    }
}
