import AppKit

/// 한 창 안의 칸 하나. 맨 앞에 고정된 서재 칸과 그 뒤의 PDF 탭이 이것이다.
/// 칸을 고르면 창의 내용, 툴바, 제목이 그 칸의 것으로 바뀐다.
@MainActor
open class Pane: NSViewController {
    public internal(set) weak var host: TabbedWindowController?
    /// 칸이 보일 때 창에 다는 툴바.
    public var toolbar: NSToolbar?
    /// 툴바 줄에 창 제목(title)과 부제를 보일지. PDF는 이름이 탭에 있어서 숨긴다.
    open var showsWindowTitle: Bool { false }
    public var windowSubtitle = "" { didSet { host?.paneTitleChanged(self) } }
    /// 탭 막대에 보일 이름과 아이콘.
    open var tabTitle: String { title ?? "" }
    open var tabImage: NSImage? { nil }
    open var tabToolTip: String? { nil }
    /// 탭 메뉴의 "Show in Finder"에 쓸 파일.
    open var representedURL: URL? { nil }
    /// ⌘Z가 쓸 실행 취소 기록.
    open var paneUndoManager: UndoManager? { nil }
    /// 칸을 처음 고를 때 키 입력을 받을 뷰. 그 뒤로는 칸을 떠날 때의 것을 기억했다가 돌려준다.
    open var preferredFirstResponder: NSView? { nil }
    fileprivate weak var savedResponder: NSView?

    open func paneDidActivate() {}
    open func paneWillDeactivate() {}
    open func paneDidResignKey() {}
    /// 사용자가 탭을 닫았다(앱을 끄면서 닫히는 것은 아님).
    open func paneDidClose() {}
}

/// Quillo의 창. 탭 막대 맨 앞에 서재 칸이 고정되고 그 뒤로 PDF 탭이 붙는다.
/// macOS 기본 탭은 탭마다 창이 따로라서 서재가 논문 탭처럼 보이고 사이드바 상태도 탭끼리 묶였다. 그래서 탭 막대를 직접 그린다.
@MainActor
public final class TabbedWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    public private(set) static var shared: TabbedWindowController?

    public let pinned: Pane
    public private(set) var tabs: [Pane] = []
    public private(set) var selected: Pane?
    private let container = NSView()
    private let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 800, height: TabStripView.height))

    public init(pinned: Pane) {
        self.pinned = pinned
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              // fullSizeContentView: 사이드바와 PDF가 반투명 툴바 뒤까지 깔린다.
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // 다시 열 PDF는 Session이 맡는다.
        window.isRestorable = false
        window.minSize = NSSize(width: 640, height: 400)
        window.toolbarStyle = .unified
        window.title = "Quillo"
        window.contentView = container
        super.init(window: window)
        window.delegate = self
        Self.shared = self

        // 탭 막대는 툴바 바로 아래(macOS 기본 탭과 같은 자리)에 붙인다. 툴바 줄 위에 두면 툴바를 가린다.
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = strip
        accessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(accessory)
        strip.onSelect = { [weak self] in self?.selectIndex($0) }
        strip.onClose = { [weak self] in self?.closeTab(at: $0) }
        strip.onMove = { [weak self] in self?.moveTab(from: $0, to: $1) }
        strip.menuForTab = { [weak self] in self?.menu(forTab: $0) }

        pinned.host = self
        show(pinned)

        // 예전 서재 창의 크기와 자리를 이어받는다.
        if !window.setFrameUsingName(Self.frameName), !window.setFrameUsingName("LibraryWindow") { window.center() }
        window.setFrameAutosaveName(Self.frameName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let frameName = "QuilloWindow"

    // MARK: 칸 고르기

    /// PDF 탭을 맨 끝에 붙인다.
    public func add(_ pane: Pane, select: Bool) {
        guard !tabs.contains(pane) else { if select { self.select(pane) }; return }
        pane.host = self
        tabs.append(pane)
        if select { self.select(pane) } else { reloadStrip() }
    }

    public func select(_ pane: Pane) {
        guard pane === pinned || tabs.contains(pane) else { return }
        show(pane)
    }

    /// Window > Library(⌘L): 서재 칸으로 가서 창을 앞으로.
    @objc public func showLibrary(_ sender: Any?) {
        show(pinned)
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    @objc public func selectNextPane(_ sender: Any?) { step(1) }
    @objc public func selectPreviousPane(_ sender: Any?) { step(-1) }

    private func step(_ delta: Int) {
        let all = [pinned] + tabs
        guard all.count > 1, let current = selected, let i = all.firstIndex(of: current) else { return }
        show(all[(i + delta + all.count) % all.count])
    }

    /// strip의 번호: -1은 서재 칸, 0부터는 PDF 탭.
    private func selectIndex(_ index: Int) {
        show(index < 0 ? pinned : tabs[index])
    }

    private func show(_ pane: Pane) {
        guard let window, selected !== pane else { reloadStrip(); return }
        if let old = selected {
            if let responder = window.firstResponder as? NSView, responder.isDescendant(of: old.view) {
                old.savedResponder = responder
            }
            old.paneWillDeactivate()
            old.view.removeFromSuperview()
        }
        selected = pane
        let view = pane.view
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        // 툴바를 바꾸면 AppKit이 내용 크기를 지키려고 창 크기를 바꾼다. 창 크기는 그대로 둔다.
        let frame = window.frame
        window.toolbar = pane.toolbar
        if window.frame != frame { window.setFrame(frame, display: false) }
        applyTitle(pane)
        reloadStrip()
        window.makeFirstResponder(pane.savedResponder ?? pane.preferredFirstResponder)
        pane.paneDidActivate()
    }

    private func applyTitle(_ pane: Pane) {
        guard let window else { return }
        window.titleVisibility = pane.showsWindowTitle ? .visible : .hidden
        window.title = pane.title ?? "Quillo"
        window.subtitle = pane.windowSubtitle
    }

    func paneTitleChanged(_ pane: Pane) {
        if pane === selected { applyTitle(pane) }
        reloadStrip()
    }

    private func reloadStrip() {
        strip.pinnedTitle = pinned.tabTitle
        strip.pinnedImage = pinned.tabImage
        strip.tabs = tabs.map { .init(title: $0.tabTitle, toolTip: $0.tabToolTip) }
        strip.selected = selected.flatMap { tabs.firstIndex(of: $0) } ?? -1
    }

    // MARK: 탭 닫기와 옮기기

    /// File > Close Tab(⌘W). 서재 칸에서는 창을 닫는다(앱은 남고, 열어 둔 탭도 그대로다).
    @objc public func closeTab(_ sender: Any?) {
        guard let current = selected, let index = tabs.firstIndex(of: current) else {
            window?.performClose(sender)
            return
        }
        closeTab(at: index)
    }

    private func closeTab(at index: Int) {
        let pane = tabs.remove(at: index)
        if pane === selected {
            // 닫은 탭의 왼쪽 탭으로 간다(맨 앞이었으면 서재 칸).
            show(index > 0 ? tabs[index - 1] : (tabs.first ?? pinned))
        }
        reloadStrip()
        pane.host = nil
        pane.paneDidClose()
    }

    private func closeOtherTabs(than keep: Pane) {
        for pane in tabs where pane !== keep {
            if let i = tabs.firstIndex(of: pane) { closeTab(at: i) }
        }
    }

    private func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        tabs.insert(tabs.remove(at: from), at: to)
        reloadStrip()
    }

    private func menu(forTab index: Int) -> NSMenu? {
        guard tabs.indices.contains(index) else { return nil }
        let pane = tabs[index]
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Close Tab") { [weak self] in
            if let i = self?.tabs.firstIndex(of: pane) { self?.closeTab(at: i) }
        })
        let others = ClosureMenuItem("Close Other Tabs") { [weak self] in self?.closeOtherTabs(than: pane) }
        others.isEnabled = tabs.count > 1
        menu.addItem(others)
        if let url = pane.representedURL {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        menu.autoenablesItems = false
        return menu
    }

    // MARK: 메뉴와 응답자 체인

    /// 메뉴 항목(target 없음)이 지금 고른 칸으로 가게 한다. 칸 안의 뷰가 키 입력을 받고 있지 않아도 칸이 받는다.
    public override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let pane = selected, pane.responds(to: action) { return pane }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTab(_:)):
            return window?.isVisible == true
        case #selector(selectNextPane(_:)), #selector(selectPreviousPane(_:)):
            return !tabs.isEmpty
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        selected?.paneUndoManager
    }

    public func windowDidResignKey(_ notification: Notification) {
        selected?.paneDidResignKey()
    }
}

/// 메뉴 항목에 동작을 바로 단다.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// 툴바 아래의 탭 막대. 맨 앞은 서재 칸(아이콘과 이름, 닫기 없음), 구분선 뒤로 PDF 탭.
/// 탭을 누르면 고르고, 끌면 순서를 바꾸고, 가운데 버튼이나 ✕로 닫는다.
@MainActor
final class TabStripView: NSView {
    struct Tab: Equatable {
        var title: String
        var toolTip: String?
    }

    static let height: CGFloat = 34

    var pinnedTitle = "" { didSet { if pinnedTitle != oldValue { needsDisplay = true } } }
    var pinnedImage: NSImage? { didSet { needsDisplay = true } }
    var tabs: [Tab] = [] { didSet { if tabs != oldValue { needsDisplay = true } } }
    /// -1이면 서재 칸.
    var selected = -1 { didSet { if selected != oldValue { needsDisplay = true } } }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var menuForTab: ((Int) -> NSMenu?)?

    private var hover: Int?            // 마우스가 올라간 칸(-1은 서재 칸)
    private var hoverClose = false     // 마우스가 그 탭의 ✕ 위에 있다
    private var pressedClose: Int?     // ✕를 누른 탭
    private var drag: (index: Int, grab: CGFloat, startX: CGFloat, x: CGFloat, moving: Bool)?

    private let font = NSFont.systemFont(ofSize: 13)
    private let boldFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let slotHeight: CGFloat = 26
    private let gap: CGFloat = 4
    private let side: CGFloat = 10

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    // MARK: 자리 계산

    private var slotY: CGFloat { (bounds.height - slotHeight) / 2 }

    private var pinnedRect: NSRect {
        let text = (pinnedTitle as NSString).size(withAttributes: [.font: boldFont]).width
        return NSRect(x: side, y: slotY, width: ceil(10 + 16 + 6 + text + 12), height: slotHeight)
    }

    private var separatorX: CGFloat { pinnedRect.maxX + 8 }
    private var tabsStartX: CGFloat { separatorX + 9 }

    private var tabWidth: CGFloat {
        guard !tabs.isEmpty else { return 0 }
        let available = bounds.width - tabsStartX - side - gap * CGFloat(tabs.count - 1)
        return max(56, min(230, floor(available / CGFloat(tabs.count))))
    }

    private func tabRect(_ index: Int) -> NSRect {
        NSRect(x: tabsStartX + CGFloat(index) * (tabWidth + gap), y: slotY, width: tabWidth, height: slotHeight)
    }

    private func closeRect(_ tab: NSRect) -> NSRect {
        NSRect(x: tab.minX + 6, y: tab.midY - 8, width: 16, height: 16)
    }

    private func hitTab(_ point: NSPoint) -> Int? {
        if pinnedRect.contains(point) { return -1 }
        return tabs.indices.first { tabRect($0).contains(point) }
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        drawSlot(pinnedRect, title: pinnedTitle, image: pinnedImage, selected: selected == -1, hovered: hover == -1,
                 closable: false, index: -1)
        NSColor.separatorColor.setFill()
        NSRect(x: separatorX, y: bounds.midY - 8, width: 1, height: 16).fill()

        let dragged = drag?.moving == true ? drag : nil
        // 고르지도 마우스가 올라가지도 않은 탭끼리는 가는 세로줄로 나눈다.
        NSColor.separatorColor.setFill()
        for i in tabs.indices.dropLast() where dragged == nil {
            let quiet = { (j: Int) in self.selected != j && self.hover != j }
            if quiet(i), quiet(i + 1) {
                let x = tabRect(i).maxX + gap / 2
                NSRect(x: x, y: bounds.midY - 7, width: 1, height: 14).fill()
            }
        }
        for i in tabs.indices where i != dragged?.index {
            drawSlot(tabRect(i), title: tabs[i].title, image: nil, selected: selected == i, hovered: hover == i,
                     closable: true, index: i)
        }
        if let dragged {
            var rect = tabRect(dragged.index)
            rect.origin.x = dragged.x
            drawSlot(rect, title: tabs[dragged.index].title, image: nil, selected: selected == dragged.index,
                     hovered: true, closable: false, index: dragged.index)
        }
    }

    private func drawSlot(_ rect: NSRect, title: String, image: NSImage?, selected isSelected: Bool, hovered: Bool,
                          closable: Bool, index: Int) {
        let fill: CGFloat = isSelected ? 0.11 : (hovered ? 0.05 : 0)
        if fill > 0 {
            NSColor.labelColor.withAlphaComponent(fill).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        }
        let active = window?.isKeyWindow ?? true
        let color: NSColor = isSelected && active ? .labelColor : .secondaryLabelColor
        var textX = rect.minX + 10
        if let image {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(.init(hierarchicalColor: color))
            let symbol = image.withSymbolConfiguration(config) ?? image
            let size = symbol.size
            symbol.draw(in: NSRect(x: textX + (16 - size.width) / 2, y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height))
            textX += 16 + 6
        }
        if closable {
            textX = rect.minX + 26
            if hovered || isSelected {
                let close = closeRect(rect)
                if hovered && hoverClose && hover == index {
                    NSColor.labelColor.withAlphaComponent(0.12).setFill()
                    NSBezierPath(roundedRect: close, xRadius: 4, yRadius: 4).fill()
                }
                if hovered, let x = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
                    .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)
                        .applying(.init(hierarchicalColor: .secondaryLabelColor))) {
                    x.draw(in: NSRect(x: close.midX - x.size.width / 2, y: close.midY - x.size.height / 2,
                                      width: x.size.width, height: x.size.height))
                }
            }
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        // PDF 탭 이름은 가운데에 둔다(✕ 자리만큼 오른쪽도 비운다).
        if closable { style.alignment = .center }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: isSelected ? boldFont : font, .foregroundColor: color, .paragraphStyle: style,
        ]
        let textHeight = (title as NSString).size(withAttributes: attributes).height
        let right = closable ? rect.maxX - (textX - rect.minX) : rect.maxX - 10
        let textRect = NSRect(x: textX, y: rect.midY - textHeight / 2, width: right - textX, height: textHeight)
        (title as NSString).draw(in: textRect, withAttributes: attributes)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: window)
        }
    }

    @objc private func keyChanged() { needsDisplay = true }

    // MARK: 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        hover = nil
        hoverClose = false
        needsDisplay = true
    }

    private func updateHover(_ point: NSPoint) {
        let index = hitTab(point)
        let onClose = index.map { $0 >= 0 && closeRect(tabRect($0)).contains(point) } ?? false
        toolTip = index.flatMap { $0 >= 0 ? tabs[$0].toolTip : nil }
        guard index != hover || onClose != hoverClose else { return }
        hover = index
        hoverClose = onClose
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = hitTab(point) else {
            // 빈 곳은 창을 끌거나(한 번) 키운다(두 번, 시스템 설정을 따른다).
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
            return
        }
        if index >= 0, closeRect(tabRect(index)).contains(point) {
            pressedClose = index
            return
        }
        onSelect?(index)
        if index >= 0 {
            drag = (index, point.x - tabRect(index).minX, point.x, tabRect(index).minX, false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !current.moving, abs(point.x - current.startX) < 4 { return }
        current.moving = true
        let lastX = tabRect(tabs.count - 1).minX
        current.x = min(max(point.x - current.grab, tabsStartX), lastX)
        let target = min(max(Int(((current.x - tabsStartX) / (tabWidth + gap)).rounded()), 0), tabs.count - 1)
        if target != current.index {
            onMove?(current.index, target)
            current.index = target
        }
        drag = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = pressedClose {
            pressedClose = nil
            if tabs.indices.contains(index), closeRect(tabRect(index)).contains(point) { onClose?(index) }
        }
        drag = nil
        updateHover(point)
        needsDisplay = true
    }

    override func otherMouseUp(with event: NSEvent) {
        // 가운데 버튼으로 누른 탭을 닫는다.
        guard event.buttonNumber == 2, let index = hitTab(convert(event.locationInWindow, from: nil)), index >= 0
        else { return super.otherMouseUp(with: event) }
        onClose?(index)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = hitTab(convert(event.locationInWindow, from: nil)), index >= 0 else { return nil }
        return menuForTab?(index)
    }
}

public extension NSToolbarItem.Identifier {
    /// 서재 칸과 PDF 탭이 함께 쓰는 사이드바 버튼.
    static let quilloSidebar = NSToolbarItem.Identifier("quilloSidebar")
}

public extension NSToolbarItem {
    /// 신호등 바로 오른쪽에 붙는 사이드바 버튼. 칸을 바꿔도 같은 자리에 있다.
    /// 시스템의 .toggleSidebar는 창 제목이 보이면 제목 뒤로 밀리고, 분할 뷰가 contentViewController가 아니면
    /// 접을 때 넘침 메뉴(>>)로 들어가서 navigational 항목으로 직접 만든다.
    @MainActor static func quilloSidebar() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .quilloSidebar)
        item.label = "Sidebar"
        item.toolTip = "Show or Hide Sidebar (⌘B)"
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
        item.action = Selector(("toggleSidebar:"))
        item.isNavigational = true
        item.isBordered = true
        return item
    }
}
