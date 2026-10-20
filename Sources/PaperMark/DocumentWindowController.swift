import AppKit
import PDFKit
import PaperMarkCore

private extension NSToolbarItem.Identifier {
    static let highlightMode = NSToolbarItem.Identifier("highlightMode")
    static let eraser = NSToolbarItem.Identifier("eraser")
    static let palette = NSToolbarItem.Identifier("palette")
    static let pageNumber = NSToolbarItem.Identifier("pageNumber")
    static let search = NSToolbarItem.Identifier("search")
}

/// 메뉴 항목에 실어 보내는 형광펜과 바꿀 색.
private final class HighlightAction: NSObject {
    let highlight: PlacedHighlight
    let color: NSColor?

    init(_ highlight: PlacedHighlight, color: NSColor? = nil) {
        self.highlight = highlight
        self.color = color
    }
}

final class DocumentWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let pdfView = ReaderPDFView()
    private var splitController: NSSplitViewController!
    private var sidebarContent: SidebarViewController!
    private let palette = PaletteView()
    private let modeButton = NSButton()
    private let eraserButton = NSButton()
    private let pageLabel = NSTextField(labelWithString: "")
    private var searchItem: NSSearchToolbarItem?

    private var results: [PDFSelection] = []
    private var resultIndex = 0
    private var lastQuery = ""

    // 드래그(마우스 누름~뗌) 사이에 PDF 안에서 텍스트 선택이 바뀌었을 때만 칠한다.
    private var mouseDownInPDF = false
    private var selectionChangedDuringDrag = false
    // 더블클릭으로 잡은 단어는 Highlights.doubleClickedWord로 다시 고른다.
    private var doubleClicked = false
    private var eventMonitor: Any?
    // 지우개로 한 번 문지르는 동안 지운 주석들(마우스를 떼면 실행 취소 하나로 기록).
    private var erasedDuringDrag: [PlacedHighlight]?
    // 스페이스바를 누르고 있어서 켜진 지우개(떼면 끈다).
    private var spaceHeld = false
    // T를 누르고 있는 동안 드래그하면 칠하지 않고 놓는 즉시 번역한다.
    private var translateHeld = false
    private var translateDrag = false
    // 다시 열 때 갈 마지막 페이지. 이동하기 전까지는 페이지 변경을 기록하지 않는다(처음 그릴 때 0쪽으로 덮어쓰지 않게).
    private var pageToRestore: Int?

    private var pmDocument: PMDocument? { document as? PMDocument }

    init(document: PMDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 1180),
                              // fullSizeContentView: PDF가 반투명 툴바 아래까지 깔려서 스크롤하면 툴바 뒤로 비친다.
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 400)
        // 다시 열 파일과 페이지는 Session이 맡는다. 시스템 창 복원까지 켜 두면 지난 창이 먼저 살아나서
        // 앱 시작 흐름(작업 폴더 탭, 직전 파일 열기)을 건너뛰게 된다.
        window.isRestorable = false
        // 시스템 설정("문서를 열 때 탭 사용")과 관계없이 새 PDF는 항상 지금 창의 탭으로 연다.
        window.tabbingMode = .preferred
        window.toolbarStyle = .expanded   // 제목 표시줄(파일 이름) 아래에 툴바를 따로 둔다
        super.init(window: window)
        window.delegate = self
        // 저장된 창 크기가 없으면(첫 실행) 화면의 쓸 수 있는 영역 높이에 맞춰 연다.
        if !window.setFrameUsingName("PaperMarkDocumentWindow"), let visible = NSScreen.main?.visibleFrame {
            let size = NSSize(width: min(980, visible.width), height: visible.height)
            window.setFrame(NSRect(origin: NSPoint(x: visible.midX - size.width / 2, y: visible.minY), size: size),
                            display: false)
        }
        window.setFrameAutosaveName("PaperMarkDocumentWindow")

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.document = document.pdf
        pageToRestore = document.fileURL.flatMap(Session.lastPage(of:))
        pdfView.highlightMenuItems = { [weak self] in self?.menuItems(for: $0) ?? [] }
        pdfView.selectionMenuItems = { [weak self] in self?.selectionMenuItems() ?? [] }
        // contentViewController로 넣으면 창이 내용의 fitting size(최소 크기)로 줄어들어서 뷰만 붙인다.
        splitController = makeSplitViewController(fileURL: document.fileURL)
        window.contentView = splitController.view
        applyDefaultSidebarWidth()
        // 새 탭에서는 사이드바(파일 트리)가 접혀 있으면 안 된다.
        if document.fileURL == nil { splitController.splitViewItems.first?.isCollapsed = false }

        modeButton.setButtonType(.pushOnPushOff)
        modeButton.bezelStyle = .toolbar
        modeButton.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Highlight Mode")
        modeButton.target = self
        modeButton.action = #selector(toggleHighlightMode(_:))
        eraserButton.setButtonType(.pushOnPushOff)
        eraserButton.bezelStyle = .toolbar
        eraserButton.image = NSImage(systemSymbolName: "eraser", accessibilityDescription: "Eraser Mode")
        eraserButton.target = self
        eraserButton.action = #selector(toggleEraserMode(_:))
        pageLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        pageLabel.textColor = .secondaryLabelColor

        let toolbar = NSToolbar(identifier: "PaperMarkToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        NotificationCenter.default.addObserver(self, selector: #selector(colorStoreChanged),
                                               name: ColorStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(colorStoreChanged),
                                               name: ShortcutStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePageLabel),
                                               name: .PDFViewDocumentChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(pdfSelectionChanged),
                                               name: .PDFViewSelectionChanged, object: pdfView)
        colorStoreChanged()
        updatePageLabel()
        installMouseMonitor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 왼쪽은 사이드바(목차 또는 파일 트리, ⌃⌘S로 접기), 오른쪽은 PDF.
    private func makeSplitViewController(fileURL: URL?) -> NSSplitViewController {
        sidebarContent = SidebarViewController(pdfView: pdfView)
        sidebarContent.files.documentURL = fileURL
        sidebarContent.isStartPage = fileURL == nil
        if fileURL == nil { sidebarContent.files.didOpen = { [weak self] in self?.closeStartPage() } }
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarContent)
        sidebar.minimumThickness = 120
        sidebar.maximumThickness = 400
        sidebar.canCollapse = true

        let mainContent = NSViewController()
        mainContent.view = fileURL == nil ? makeStartView() : pdfView
        let main = NSSplitViewItem(viewController: mainContent)
        main.minimumThickness = 360

        let split = SidebarSplitViewController()
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(main)
        // 사이드바 폭과 접힘 상태를 기억한다.
        split.splitView.autosaveName = Self.sidebarAutosaveName
        return split
    }

    // 기본 너비를 넓히면서 이름을 바꿨다. 예전 이름으로 저장된 좁은 너비는 쓰지 않고 한 번 새 기본값으로 연다.
    private static let sidebarAutosaveName = "PaperMarkSidebarWidth"
    private static let defaultSidebarWidth: CGFloat = 240

    /// 저장된 사이드바 너비가 없으면(처음 열 때) 파일 이름이 덜 잘리도록 기본 너비로 연다.
    private func applyDefaultSidebarWidth() {
        guard UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(Self.sidebarAutosaveName)") == nil
        else { return }
        splitController.view.layoutSubtreeIfNeeded()
        splitController.splitView.setPosition(Self.defaultSidebarWidth, ofDividerAt: 0)
    }

    /// 탭이 하나뿐이어도 탭 막대를 보인다. 한 번 켜면 시스템이 기억하므로 꺼져 있을 때만 켠다.
    private func showTabBar() {
        guard let window, window.tabGroup?.isTabBarVisible == false else { return }
        window.toggleTabBar(nil)
    }

    /// 탭 막대의 + 버튼으로 연 새 탭(PDF 없는 문서): 빈 화면 대신 안내와 열기 버튼을 두고 사이드바에 파일 트리를 연다.
    /// 여기서 PDF를 열면 이 탭은 닫혀서 그 PDF로 바뀐 것처럼 보인다.
    private func makeStartView() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let label = NSTextField(labelWithString: "Double-click a PDF in the sidebar to open it.")
        label.textColor = .secondaryLabelColor
        let button = NSButton(title: "Open…", target: self, action: #selector(openFromStartPage(_:)))
        let stack = NSStackView(views: [icon, label, button])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    @objc private func openFromStartPage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.directoryURL = NSDocumentController.shared.recentDocumentURLs.first?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                    if let error { NSApp.presentError(error) }
                    if document != nil { self?.closeStartPage() }
                }
            }
        }
    }

    private func closeStartPage() {
        guard let document = pmDocument, document.fileURL == nil else { return }
        document.close()
    }

    /// 제목 옆 아이콘: PDF 파일 아이콘(대개 밋밋한 흰 문서) 대신 PaperMark 아이콘을 보인다.
    /// 아이콘을 끌어 파일을 옮기거나 ⌘클릭으로 경로를 보는 기능은 그대로다.
    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        window?.standardWindowButton(.documentIconButton)?.image = NSApp.applicationIconImage
    }

    @objc func toggleSidebar(_ sender: Any?) {
        splitController.toggleSidebar(sender)
    }

    private var sidebarCollapsed: Bool { splitController.splitViewItems.first?.isCollapsed ?? true }

    /// 다른 기기에서 바뀐 파일을 다시 읽었을 때: 보던 쪽을 유지한다.
    func documentDidReload() {
        let pageIndex = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? 0
        pdfView.document = pmDocument?.pdf
        if let page = pdfView.document?.page(at: min(pageIndex, max((pdfView.document?.pageCount ?? 1) - 1, 0))) {
            pdfView.go(to: page)
        }
        clearSearch()
    }

    // MARK: 형광펜

    private func installMouseMonitor() {
        // EventTypeMask에는 찾아보기(.quickLook) 멤버가 없어서 이벤트 종류 값으로 만든다.
        let quickLookMask = NSEvent.EventTypeMask(rawValue: 1 << NSEvent.EventType.quickLook.rawValue)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .otherMouseDown, .swipe, .keyDown, .keyUp, .pressure, quickLookMask]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .keyDown || event.type == .keyUp { return self.handleKey(event) ? nil : event }
            // 마우스 옆 버튼: 뒤로는 링크를 누른 자리로 돌아가기(없으면 이동 기록 뒤로), 앞으로는 이동 기록 앞으로.
            // 보통은 3·4번 버튼으로 오지만, Logi Options+는 옆 버튼을 세 손가락 쓸기(swipe)로 바꿔 보낸다.
            // 쓸기는 오른쪽으로 쓸면(뒤로) deltaX가 +1, 왼쪽으로 쓸면(앞으로) -1이다.
            if event.type == .otherMouseDown || event.type == .swipe {
                let back = event.type == .swipe ? event.deltaX > 0 : event.buttonNumber == 3
                let forward = event.type == .swipe ? event.deltaX < 0 : event.buttonNumber == 4
                if back { self.goBack(nil) } else if forward { self.goForward(nil) } else { return event }
                return nil
            }
            // PDF는 툴바 뒤까지 깔려 있으므로(fullSizeContentView) 툴바·제목 표시줄에 가린 곳은 PDF로 치지 않는다.
            // 그러지 않으면 지우개가 켜진 동안 툴바 클릭까지 가로채서 지우개를 끌 수도 없다.
            let inPDF = self.pdfView.bounds.contains(self.pdfView.convert(event.locationInWindow, from: nil))
                && self.window?.contentLayoutRect.contains(event.locationInWindow) == true
            // Force Click(세게 누르기)과 찾아보기는 macOS 데이터 감지로 이어져서 "84 × 84 × 4" 같은 숫자를 전화번호로 보고
            // 연락처 카드를 띄운다. 클릭 압력이 가벼우면 칠하다가도 쉽게 눌리므로 PDF 위에서는 넘기지 않는다.
            if event.type == .quickLook || event.type == .pressure {
                return inPDF && (event.type == .quickLook || event.stage >= 2) ? nil : event
            }
            // 지우개 모드: PDF 안의 클릭·드래그는 PDFView에 넘기지 않고(텍스트 선택 안 함) 지나간 주석을 지운다.
            if ColorStore.shared.eraserMode || self.erasedDuringDrag != nil {
                return self.handleEraser(event, inPDF: inPDF) ? nil : event
            }
            if event.type == .leftMouseDragged { return event }
            if event.type == .leftMouseDown {
                self.mouseDownInPDF = inPDF
                self.selectionChangedDuringDrag = false
                self.translateDrag = self.translateHeld
                self.doubleClicked = inPDF && event.clickCount == 2
            } else if self.mouseDownInPDF {
                self.mouseDownInPDF = false
                // PDFView가 mouseUp을 처리해 선택을 확정한 다음에 칠한다.
                DispatchQueue.main.async { self.highlightAfterDrag() }
            }
            return event
        }
    }

    /// 스페이스바를 누르고 있는 동안만 지우개 모드(떼면 꺼짐). 페이지를 내리는 기본 동작 대신이다.
    /// 지우개가 이미 버튼이나 ⇧⌘E로 켜져 있으면 스페이스바는 아무것도 바꾸지 않는다. Esc는 지우개를 끈다.
    /// T를 누르고 있는 동안 드래그하면 번역한다(형광펜은 칠하지 않음).
    /// 검색창 등 글자 입력 중일 때는 건드리지 않는다.
    private func handleKey(_ event: NSEvent) -> Bool {
        // 한글 입력 중에는 T 키가 "ㅅ"으로 들어오므로 글자가 아니라 키 위치(kVK_ANSI_T = 17)로 본다.
        let isT = event.keyCode == 17
        if event.type == .keyUp {
            if isT, translateHeld { translateHeld = false; return true }
            guard event.keyCode == 49, spaceHeld else { return false }
            releaseSpace()
            return true
        }
        guard !(window?.firstResponder is NSText),
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 49:    // Space
            if !event.isARepeat, !ColorStore.shared.eraserMode {
                spaceHeld = true
                ColorStore.shared.eraserMode = true
                pdfView.clearSelection()
            }
            return true
        case _ where isT:
            if !event.isARepeat { translateHeld = true }
            return true
        case 53 where ColorStore.shared.eraserMode:    // Esc
            spaceHeld = false
            ColorStore.shared.eraserMode = false
            return true
        default:
            return false
        }
    }

    private func releaseSpace() {
        guard spaceHeld else { return }
        spaceHeld = false
        ColorStore.shared.eraserMode = false
    }

    // 스페이스바를 누른 채 다른 창으로 가면 keyUp이 오지 않으므로 여기서 끈다.
    func windowDidResignKey(_ notification: Notification) {
        releaseSpace()
        translateHeld = false
    }

    // 창으로 돌아올 때 파일 트리를 다시 읽고(다른 곳에서 파일이 바뀌었을 수 있다) 이 창의 PDF를 보여 준다.
    func windowDidBecomeKey(_ notification: Notification) {
        showTabBar()
        if sidebarContent.showsFiles, !sidebarCollapsed { sidebarContent.files.reload(revealDocument: true) }
    }

    /// 지우개 이벤트를 처리했으면 true(PDFView에 넘기지 않음).
    private func handleEraser(_ event: NSEvent, inPDF: Bool) -> Bool {
        switch event.type {
        case .leftMouseDown:
            // 스크롤 막대나 페이지 밖 여백은 평소처럼 동작하게 둔다.
            let point = pdfView.convert(event.locationInWindow, from: nil)
            guard inPDF, !(window?.contentView?.hitTest(event.locationInWindow) is NSScroller),
                  pdfView.page(for: point, nearest: false) != nil else { return false }
            erasedDuringDrag = []
            // PDFView에 클릭을 넘기지 않으므로 키 입력(스페이스바, Esc)을 받을 수 있게 직접 포커스를 준다.
            window?.makeFirstResponder(pdfView)
            erase(at: event)
            return true
        case .leftMouseDragged:
            guard erasedDuringDrag != nil else { return false }
            erase(at: event)
            return true
        case .leftMouseUp:
            guard let erased = erasedDuringDrag else { return false }
            erasedDuringDrag = nil
            pmDocument?.didRemove(erased, actionName: "Erase")
            return true
        default:
            return false
        }
    }

    private func erase(at event: NSEvent) {
        let point = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: point, nearest: false),
              let annotation = Markups.markup(on: page, at: pdfView.convert(point, to: page)) else { return }
        let removed = Markups.removalSet(for: annotation, on: page)
        for h in removed { page.removeAnnotation(h.annotation) }
        erasedDuringDrag?.append(contentsOf: removed)
    }

    @objc private func pdfSelectionChanged(_ note: Notification) {
        if mouseDownInPDF { selectionChangedDuringDrag = true }
    }

    private func highlightAfterDrag() {
        if translateDrag {
            translateDrag = false
            if selectionChangedDuringDrag { translateSelection(nil) }
            selectionChangedDuringDrag = false
            return
        }
        guard selectionChangedDuringDrag, ColorStore.shared.highlightMode else { return }
        selectionChangedDuringDrag = false
        highlightCurrentSelection()
    }

    private func highlightCurrentSelection() {
        // 드래그는 글자 단위라 양 끝을 단어 경계로 맞춘다(문장부호에서는 넓히지 않음).
        let word = doubleClicked ? pdfView.currentSelection.flatMap(Highlights.doubleClickedWord) : nil
        doubleClicked = false
        guard let selection = word ?? pdfView.currentSelection.map(Highlights.snappedToWords),
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let color = ColorStore.shared.currentColor, author = NSFullUserName()
        let highlights = Highlights.make(from: selection, color: color, author: author)
        guard !highlights.isEmpty else { return }
        let merged = Highlights.merge(highlights, color: color, author: author)
        pmDocument?.replace(merged.removed, with: merged.added, actionName: "Highlight")
        pdfView.clearSelection()
    }

    @objc func highlightSelection(_ sender: Any?) {
        highlightCurrentSelection()
    }

    /// 지우개가 켜져 있으면 형광펜 버튼은 꺼진 것처럼 보이므로, 누르면 지우개를 끄고 형광펜을 켠다.
    @objc func toggleHighlightMode(_ sender: Any?) {
        let store = ColorStore.shared
        if store.eraserMode {
            spaceHeld = false
            store.eraserMode = false
            store.highlightMode = true
        } else {
            store.highlightMode.toggle()
        }
    }

    @objc func toggleEraserMode(_ sender: Any?) {
        spaceHeld = false
        ColorStore.shared.eraserMode.toggle()
        if ColorStore.shared.eraserMode { pdfView.clearSelection() }
    }

    @objc private func colorStoreChanged() {
        let store = ColorStore.shared
        // 지우개가 켜져 있으면 칠하지 않으므로 형광펜 버튼은 꺼진 것처럼 보이게 한다.
        let highlighting = store.highlightMode && !store.eraserMode
        modeButton.state = highlighting ? .on : .off
        modeButton.contentTintColor = highlighting ? store.currentColor : nil
        eraserButton.state = store.eraserMode ? .on : .off
        eraserButton.contentTintColor = store.eraserMode ? .systemRed : nil
        // macOS 26부터 켜진 툴바 버튼은 아이콘 대신 바탕을 강조색으로 채우므로 바탕도 같은 색으로 한다.
        if #available(macOS 26, *) {
            modeButton.bezelColor = highlighting ? store.currentColor : nil
            eraserButton.bezelColor = store.eraserMode ? .systemRed : nil
        }
        func key(_ command: Command) -> String {
            ShortcutStore.shared.shortcut(for: command).map { " (\($0.display))" } ?? ""
        }
        modeButton.toolTip = "Highlight Mode: when on, dragging over text highlights it immediately" + key(.highlightMode)
        eraserButton.toolTip = "Eraser Mode: click or rub over an annotation to remove it. Hold Space for a quick erase"
            + key(.eraserMode)
    }

    // MARK: 번역

    private var selectedText: String {
        PDFText.cleaned(pdfView.currentSelection?.string ?? "")
    }

    @objc func translateSelection(_ sender: Any?) {
        guard let selection = pdfView.currentSelection.map(Highlights.snappedToWords),
              let page = selection.pages.first else { return }
        pdfView.setCurrentSelection(selection, animate: false)
        let rect = pdfView.convert(selection.bounds(for: page), from: page)
        Translator.present(PDFText.cleaned(selection.string ?? ""), at: rect, in: pdfView)
    }

    @objc private func translateHighlight(_ sender: NSMenuItem) {
        guard let h = (sender.representedObject as? HighlightAction)?.highlight else { return }
        let rect = pdfView.convert(h.annotation.bounds, from: h.page)
        Translator.present(PDFText.text(of: h.annotation, on: h.page), at: rect, in: pdfView)
    }

    private func selectionMenuItems() -> [NSMenuItem] {
        let text = selectedText
        guard Translator.isAvailable, !text.isEmpty else { return [] }
        let preview = text.count > 24 ? String(text.prefix(24)) + "…" : text
        let item = NSMenuItem(title: "Translate “\(preview)”", action: #selector(translateSelection(_:)), keyEquivalent: "")
        item.target = self
        return [item]
    }

    private func menuItems(for highlight: PlacedHighlight) -> [NSMenuItem] {
        let name = Markups.displayName(of: highlight.annotation)
        var items: [NSMenuItem] = []
        if Translator.isAvailable, Markups.textMarkupTypes.contains(Markups.type(of: highlight.annotation)) {
            let translate = NSMenuItem(title: "Translate \(name)", action: #selector(translateHighlight(_:)), keyEquivalent: "")
            translate.target = self
            translate.representedObject = HighlightAction(highlight)
            items += [translate, .separator()]
        }
        let remove = NSMenuItem(title: "Remove \(name)", action: #selector(removeHighlight(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = HighlightAction(highlight)
        items.append(remove)
        guard Markups.isRecolorable(highlight.annotation) else { return items }

        let recolor = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        let currentHex = highlight.annotation.color.hexString
        for hex in ColorStore.shared.presets {
            guard let color = NSColor(hex: hex) else { continue }
            let item = NSMenuItem(title: hex, action: #selector(recolorHighlight(_:)), keyEquivalent: "")
            item.target = self
            item.image = swatchImage(color)
            item.state = hex == currentHex ? .on : .off
            item.representedObject = HighlightAction(highlight, color: color)
            colors.addItem(item)
        }
        recolor.submenu = colors
        return items + [recolor]
    }

    @objc private func removeHighlight(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? HighlightAction else { return }
        let h = action.highlight
        pmDocument?.replace(Markups.removalSet(for: h.annotation, on: h.page), with: [],
                            actionName: "Remove \(Markups.displayName(of: h.annotation))")
    }

    @objc private func recolorHighlight(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? HighlightAction, let color = action.color else { return }
        pmDocument?.recolor(action.highlight, to: color)
    }

    // MARK: 검색

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        let query = sender.stringValue
        guard !query.isEmpty else { clearSearch(); return }
        if query == lastQuery, !results.isEmpty {
            step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1)
            return
        }
        lastQuery = query
        results = pdfView.document?.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive]) ?? []
        for result in results { result.color = NSColor.systemYellow.withAlphaComponent(0.35) }
        pdfView.highlightedSelections = results.isEmpty ? nil : results
        resultIndex = 0
        showCurrentResult()
    }

    private func step(_ delta: Int) {
        guard !results.isEmpty else { NSSound.beep(); return }
        resultIndex = (resultIndex + delta + results.count) % results.count
        showCurrentResult()
    }

    private func showCurrentResult() {
        guard !results.isEmpty else {
            window?.subtitle = "No results for “\(lastQuery)”"
            NSSound.beep()
            return
        }
        let result = results[resultIndex]
        pdfView.go(to: result)
        pdfView.setCurrentSelection(result, animate: true)
        window?.subtitle = "“\(lastQuery)” \(resultIndex + 1) / \(results.count)"
    }

    private func clearSearch() {
        results = []
        lastQuery = ""
        resultIndex = 0
        pdfView.highlightedSelections = nil
        window?.subtitle = ""
    }

    @objc func focusSearch(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    @objc func findNextResult(_ sender: Any?) { step(1) }
    @objc func findPreviousResult(_ sender: Any?) { step(-1) }

    // MARK: 보기

    @objc func zoomInPDF(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOutPDF(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func zoomToFit(_ sender: Any?) { pdfView.autoScales = true }

    // 링크·목차·검색으로 옮겨 간 자리를 PDFView가 기록해 두므로 그 기록을 오간다.
    // 링크를 눌러 옮겨 왔으면(돌아가기 버튼이 떠 있으면) 링크를 누른 자리로 먼저 돌아간다.
    @objc func goBack(_ sender: Any?) {
        if pdfView.canReturnToLinkOrigin { pdfView.returnToLinkOrigin() } else { pdfView.goBack(sender) }
    }
    @objc func goForward(_ sender: Any?) {
        if pdfView.canRedoLinkJump { pdfView.redoLinkJump() } else { pdfView.goForward(sender) }
    }

    // MARK: 실행 취소 (창이 문서의 undo manager를 쓰게 한다)

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager ?? nil
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleHighlightMode(_:)):
            item.state = ColorStore.shared.highlightMode && !ColorStore.shared.eraserMode ? .on : .off
            return true
        case #selector(toggleEraserMode(_:)):
            item.state = ColorStore.shared.eraserMode ? .on : .off
            return true
        case #selector(highlightSelection(_:)):
            return pdfView.currentSelection != nil
        case #selector(translateSelection(_:)):
            return Translator.isAvailable && !selectedText.isEmpty
        case #selector(toggleSidebar(_:)):
            item.title = sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(findNextResult(_:)), #selector(findPreviousResult(_:)):
            return !results.isEmpty
        case #selector(goBack(_:)):
            return pdfView.canReturnToLinkOrigin || pdfView.canGoBack
        case #selector(goForward(_:)):
            return pdfView.canRedoLinkJump || pdfView.canGoForward
        default:
            return true
        }
    }

    // 사용자가 창을 닫을 때만 불린다(앱을 끄면서 닫히는 창은 아님). 다음 실행 때 다시 열 목록에서 뺀다.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let url = pmDocument?.fileURL { Session.didCloseByUser(url) }
        return true
    }

    override func showWindow(_ sender: Any?) {
        joinExistingWindow()
        super.showWindow(sender)
        // 창 크기가 정해진 다음에 마지막으로 보던 페이지로 간다.
        DispatchQueue.main.async { [weak self] in
            guard let self, let index = self.pageToRestore else { return }
            self.pageToRestore = nil
            if let page = self.pdfView.document?.page(at: index) { self.pdfView.go(to: page) }
        }
    }

    /// 처음 띄우는 창이면 이미 열린 문서 창의 탭으로 붙인다. tabbingMode만으로는 PaperMark가 뒤에 있을 때
    /// (Finder, Raycast, PDFRouter로 열 때) 붙을 주 창이 없어서 새 창이 따로 뜬다.
    private func joinExistingWindow() {
        guard let window, !window.isVisible, (window.tabGroup?.windows.count ?? 1) <= 1 else { return }
        let others = NSApp.orderedWindows.filter {
            $0 !== window && $0.windowController is DocumentWindowController && $0.isVisible && !$0.isMiniaturized
        }
        guard let target = NSApp.mainWindow.flatMap({ main in others.first { $0 === main } }) ?? others.first else { return }
        target.addTabbedWindow(window, ordered: .above)
    }

    // 앱을 끌 때는 창이 닫히지 않을 수 있어서 페이지가 바뀔 때마다 기록한다.
    @objc private func pageChanged(_ note: Notification) {
        updatePageLabel()
        guard pageToRestore == nil, let url = pmDocument?.fileURL, let page = pdfView.currentPage,
              let index = pdfView.document?.index(for: page) else { return }
        Session.setLastPage(index, of: url)
    }

    /// 툴바 팔레트 옆에 "현재 쪽 / 전체 쪽"을 보여 준다. 시작 탭처럼 PDF가 없으면 비운다.
    @objc private func updatePageLabel() {
        guard let document = pdfView.document, let page = pdfView.currentPage, document.pageCount > 0 else {
            pageLabel.stringValue = ""
            return
        }
        pageLabel.stringValue = "\(document.index(for: page) + 1) / \(document.pageCount)"
    }

    func windowWillClose(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: 툴바

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .highlightMode, .eraser, .palette, .pageNumber, .flexibleSpace, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .highlightMode:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Highlight Mode"
            item.view = modeButton
            return item
        case .eraser:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Eraser"
            item.view = eraserButton
            return item
        case .palette:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Color"
            item.view = palette
            return item
        case .pageNumber:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Page"
            item.view = pageLabel
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.placeholderString = "Search in Document"
            item.searchField.sendsWholeSearchString = true
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldAction(_:))
            searchItem = item
            return item
        default:
            return nil
        }
    }
}

/// 사이드바 분할선은 1pt라 잡히는 폭이 분할선 주변 4pt 남짓뿐이다. 그런데 바로 오른쪽 PDF 여백까지
/// 경계처럼 보여서, 보이는 경계를 잡으면 끌리지 않았다. 잡는 범위를 그 여백까지 넓힌다.
private final class SidebarSplitViewController: NSSplitViewController {
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                                   forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return rect.union(NSRect(x: drawnRect.minX - 3, y: drawnRect.minY,
                                 width: drawnRect.width + 9, height: drawnRect.height))
    }
}
