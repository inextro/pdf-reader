import AppKit
import PDFKit
import PaperMarkCore

private extension NSToolbarItem.Identifier {
    static let highlightMode = NSToolbarItem.Identifier("highlightMode")
    static let palette = NSToolbarItem.Identifier("palette")
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
    private let palette = PaletteView()
    private let modeButton = NSButton()
    private var searchItem: NSSearchToolbarItem?

    private var results: [PDFSelection] = []
    private var resultIndex = 0
    private var lastQuery = ""

    // 드래그(마우스 누름~뗌) 사이에 PDF 안에서 텍스트 선택이 바뀌었을 때만 칠한다.
    private var mouseDownInPDF = false
    private var selectionChangedDuringDrag = false
    private var eventMonitor: Any?

    private var pmDocument: PMDocument? { document as? PMDocument }

    init(document: PMDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 1180),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 400)
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("PaperMarkDocumentWindow")

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.document = document.pdf
        pdfView.highlightMenuItems = { [weak self] in self?.menuItems(for: $0) ?? [] }
        window.contentView = pdfView

        modeButton.setButtonType(.pushOnPushOff)
        modeButton.bezelStyle = .toolbar
        modeButton.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Highlight Mode")
        modeButton.toolTip = "Highlight Mode: when on, dragging over text highlights it immediately (⇧⌘D)"
        modeButton.target = self
        modeButton.action = #selector(toggleHighlightMode(_:))

        let toolbar = NSToolbar(identifier: "PaperMarkToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        NotificationCenter.default.addObserver(self, selector: #selector(colorStoreChanged),
                                               name: ColorStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pdfSelectionChanged),
                                               name: .PDFViewSelectionChanged, object: pdfView)
        colorStoreChanged()
        installMouseMonitor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let inPDF = self.pdfView.bounds.contains(self.pdfView.convert(event.locationInWindow, from: nil))
            if event.type == .leftMouseDown {
                self.mouseDownInPDF = inPDF
                self.selectionChangedDuringDrag = false
            } else if self.mouseDownInPDF {
                self.mouseDownInPDF = false
                // PDFView가 mouseUp을 처리해 선택을 확정한 다음에 칠한다.
                DispatchQueue.main.async { self.highlightAfterDrag() }
            }
            return event
        }
    }

    @objc private func pdfSelectionChanged(_ note: Notification) {
        if mouseDownInPDF { selectionChangedDuringDrag = true }
    }

    private func highlightAfterDrag() {
        guard selectionChangedDuringDrag, ColorStore.shared.highlightMode else { return }
        selectionChangedDuringDrag = false
        highlightCurrentSelection()
    }

    private func highlightCurrentSelection() {
        guard let selection = pdfView.currentSelection,
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

    @objc func toggleHighlightMode(_ sender: Any?) {
        ColorStore.shared.highlightMode.toggle()
    }

    @objc private func colorStoreChanged() {
        modeButton.state = ColorStore.shared.highlightMode ? .on : .off
        modeButton.contentTintColor = ColorStore.shared.highlightMode ? ColorStore.shared.currentColor : nil
    }

    private func menuItems(for highlight: PlacedHighlight) -> [NSMenuItem] {
        let name = Markups.displayName(of: highlight.annotation)
        let remove = NSMenuItem(title: "Remove \(name)", action: #selector(removeHighlight(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = HighlightAction(highlight)
        guard Markups.isRecolorable(highlight.annotation) else { return [remove] }

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
        return [remove, recolor]
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

    // MARK: 실행 취소 (창이 문서의 undo manager를 쓰게 한다)

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager ?? nil
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleHighlightMode(_:)):
            item.state = ColorStore.shared.highlightMode ? .on : .off
            return true
        case #selector(highlightSelection(_:)):
            return pdfView.currentSelection != nil
        case #selector(findNextResult(_:)), #selector(findPreviousResult(_:)):
            return !results.isEmpty
        default:
            return true
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: 툴바

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.highlightMode, .palette, .flexibleSpace, .search]
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
        case .palette:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Color"
            item.view = palette
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
