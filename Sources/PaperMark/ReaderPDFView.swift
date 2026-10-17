import AppKit
import PDFKit
import PaperMarkCore

/// 형광펜 등 사용자 주석 위에서 우클릭하면 지우기·색 바꾸기 메뉴를 앞에 붙이는 PDFView.
final class ReaderPDFView: PDFView {
    var highlightMenuItems: ((PlacedHighlight) -> [NSMenuItem])?
    /// 주석이 아닌 곳을 우클릭했을 때, 선택한 글자가 있으면 앞에 붙일 항목(번역 등).
    var selectionMenuItems: (() -> [NSMenuItem])?

    // Force Click(세게 누르기)은 macOS 데이터 감지로 이어져서 "84 × 84 × 4" 같은 숫자를 전화번호로 보고
    // 연락처 카드를 띄운다. 그 제스처 인식기를 끈다. 찾아보기 이벤트는 DocumentWindowController가 막는다.
    override var document: PDFDocument? {
        didSet { disableImmediateActions() }
    }

    // Force Click을 받는 NSImmediateActionGestureRecognizer는 공개 타입이 아니어서 클래스 이름으로 찾는다.
    private func disableImmediateActions() {
        guard let immediateAction = NSClassFromString("NSImmediateActionGestureRecognizer") else { return }
        for recognizer in gestureRecognizers where recognizer.isKind(of: immediateAction) {
            recognizer.isEnabled = false
        }
    }

    // MARK: 링크 미리보기

    // 인용 링크 위에 마우스를 잠깐 두면 가리키는 참고문헌 항목을 popover로 보여 준다. 그림·표 링크는 누르면 가기만 한다.
    // PDFView 자체 추적 영역과 섞이지 않도록 마우스 움직임은 따로 둔 추적 영역에서 받는다.
    private lazy var hoverTracker = LinkHoverTracker(view: self)
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: hoverTracker, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }
    }

    /// 마우스 아래 링크가 문서 안을 가리키면 그 링크와 링크가 있는 쪽.
    fileprivate func internalLink(at locationInWindow: NSPoint) -> (PDFAnnotation, PDFPage)? {
        let point = convert(locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return nil }
        // annotation(at:)은 맨 위 주석만 주므로, 인용 번호까지 칠한 형광펜이 링크를 덮으면 못 찾는다.
        let pagePoint = convert(point, to: page)
        for annotation in page.annotations.reversed() where annotation.bounds.contains(pagePoint) {
            if PDFLinks.destination(of: annotation) != nil { return (annotation, page) }
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        hoverTracker.dismiss()
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        hoverTracker.dismiss()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        hoverTracker.dismiss()
        let menu = super.menu(for: event) ?? NSMenu()
        let items = highlight(at: event).flatMap { highlightMenuItems?($0) } ?? selectionMenuItems?() ?? []
        guard !items.isEmpty else { return menu }
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    private func highlight(at event: NSEvent) -> PlacedHighlight? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false),
              let annotation = Markups.markup(on: page, at: convert(point, to: page)) else { return nil }
        return PlacedHighlight(page: page, annotation: annotation)
    }
}

/// 링크 위에서 잠깐 멈추면 미리보기를 띄우고, 링크를 벗어나거나 스크롤·클릭하면 닫는다.
private final class LinkHoverTracker: NSResponder {
    private unowned let view: ReaderPDFView
    private var hovered: PDFAnnotation?
    private var pending: DispatchWorkItem?
    private var popover: NSPopover?
    private static let delay: TimeInterval = 0.35

    init(view: ReaderPDFView) {
        self.view = view
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseMoved(with event: NSEvent) {
        // 지우개를 쓰거나 끌어서 칠하는 중에는 띄우지 않는다.
        guard !ColorStore.shared.eraserMode, NSEvent.pressedMouseButtons == 0,
              let (annotation, page) = view.internalLink(at: event.locationInWindow) else {
            dismiss()
            return
        }
        guard annotation !== hovered else { return }
        dismiss()
        hovered = annotation
        let work = DispatchWorkItem { [weak self] in self?.show(annotation, on: page) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    override func mouseExited(with event: NSEvent) { dismiss() }

    func dismiss() {
        pending?.cancel()
        pending = nil
        hovered = nil
        popover?.close()
        popover = nil
    }

    private func show(_ annotation: PDFAnnotation, on page: PDFPage) {
        guard view.window?.isKeyWindow == true,
              let (target, rect) = PDFLinks.citationPreview(for: annotation, on: page), rect.width > 1, rect.height > 1
        else { return }
        // 두 단 논문의 한 단(약 260pt)이 읽기 좋은 크기가 되도록 키우고, 한 단 논문의 본문 너비는 너무 커지지 않게 줄인다.
        let scale = min(1.6, 520 / rect.width)
        let size = NSSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            let box = target.bounds(for: .cropBox)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: box.minX - rect.minX, y: box.minY - rect.minY)
            target.draw(with: .cropBox, to: context)
            return true
        }
        let imageView = NSImageView(image: image)
        imageView.frame = NSRect(origin: .zero, size: size)
        let controller = NSViewController()
        controller.view = imageView
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = size
        popover.show(relativeTo: view.convert(annotation.bounds, from: page), of: view, preferredEdge: .minY)
        self.popover = popover
    }
}
