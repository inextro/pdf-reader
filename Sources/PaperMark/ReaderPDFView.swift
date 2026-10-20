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
        didSet {
            disableImmediateActions()
            Self.suppressLinkToolTips
            clearReturnSpots()
        }
    }

    // Force Click을 받는 NSImmediateActionGestureRecognizer는 공개 타입이 아니어서 클래스 이름으로 찾는다.
    private func disableImmediateActions() {
        guard let immediateAction = NSClassFromString("NSImmediateActionGestureRecognizer") else { return }
        for recognizer in gestureRecognizers where recognizer.isKind(of: immediateAction) {
            recognizer.isEnabled = false
        }
    }

    // PDFKit은 쪽을 그릴 때 링크마다 툴팁 영역을 등록하고 문구("Go to page N")를 목적지에서 바로 만든다.
    // 그래서 contents를 비워도 뜬다. 문서 안 링크는 미리보기가 대신하므로 PDFPageView가 툴팁 영역을
    // 등록할 때 빼 버린다(userData가 그 주석이다). 웹 주소 링크의 툴팁은 그대로 둔다.
    private static let suppressLinkToolTips: Void = {
        let selector = #selector(NSView.addToolTip(_:owner:userData:))
        guard let pageView = NSClassFromString("PDFPageView"),
              let method = class_getInstanceMethod(pageView, selector) else { return }
        typealias AddToolTip = @convention(c) (NSView, Selector, NSRect, AnyObject, UnsafeMutableRawPointer?) -> NSView.ToolTipTag
        let original = unsafeBitCast(method_getImplementation(method), to: AddToolTip.self)
        let block: @convention(block) (NSView, NSRect, AnyObject, UnsafeMutableRawPointer?) -> NSView.ToolTipTag = { view, rect, owner, userData in
            if let userData, view.responds(to: NSSelectorFromString("page")),
               let page = view.value(forKey: "page") as? PDFPage,
               let link = page.annotations.first(where: { Unmanaged.passUnretained($0).toOpaque() == userData }),
               PDFLinks.destination(of: link) != nil { return 0 }
            return original(view, selector, rect, owner, userData)
        }
        let replacement = imp_implementationWithBlock(block)
        // PDFPageView가 이 메서드를 직접 갖고 있지 않으면(NSView 것을 물려받으면) 덧붙이고, 갖고 있으면 바꾼다.
        if !class_addMethod(pageView, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
    }()

    // MARK: 링크로 옮겨 간 뒤 돌아가기

    // 문서 안 링크를 눌러 옮겨 가면 누르기 전 자리를 쌓아 두고, 아래쪽에 돌아가기 버튼을 띄운다.
    // PDFKit이 링크를 따라가는 경로는 공개돼 있지 않아서, 링크 위에서 눌렀다 뗀 뒤 보던 자리가 바뀌었으면 옮겨 간 것으로 본다.
    private struct Spot {
        let page: PDFPage
        let origin: NSPoint
        let scale: CGFloat
        let destination: PDFDestination
    }

    private var spotAtLinkClick: Spot?
    private var linkClickLocation = NSPoint.zero
    private var returnSpots: [Spot] = [] { didSet { updateReturnBar() } }
    // 돌아가기로 떠난 자리. 앞으로 가기(마우스 앞으로 버튼, ⌘])로 다시 간다. 링크를 새로 누르면 비운다.
    private var forwardSpots: [Spot] = []
    private lazy var returnBar = ReturnBar(back: { [weak self] in self?.returnToLinkOrigin() },
                                           close: { [weak self] in self?.clearReturnSpots() })

    var canReturnToLinkOrigin: Bool { !returnSpots.isEmpty }
    var canRedoLinkJump: Bool { !forwardSpots.isEmpty }

    private var clipView: NSClipView? { documentView?.enclosingScrollView?.contentView }

    // currentPage·currentDestination은 스크롤 위치를 직접 되돌린 뒤 바로 갱신되지 않으므로 화면에서 직접 구한다.
    // 쪽은 화면 가운데의 쪽, 목적지는 화면 왼쪽 위 자리.
    private func currentSpot() -> Spot? {
        guard let clipView, let page = page(for: NSPoint(x: bounds.midX, y: bounds.midY), nearest: true) else { return nil }
        let top = NSPoint(x: bounds.minX, y: bounds.maxY)
        let topPage = self.page(for: top, nearest: true) ?? page
        return Spot(page: page, origin: clipView.bounds.origin, scale: scaleFactor,
                    destination: PDFDestination(page: topPage, at: convert(top, to: topPage)))
    }

    private func moved(from spot: Spot) -> Bool {
        guard let now = currentSpot() else { return false }
        return now.page !== spot.page || hypot(now.origin.x - spot.origin.x, now.origin.y - spot.origin.y) > 1
    }

    private func recordJumpIfMoved() {
        guard let spot = spotAtLinkClick, moved(from: spot) else { return }
        spotAtLinkClick = nil
        forwardSpots = []
        returnSpots.append(spot)
    }

    func returnToLinkOrigin() {
        guard let spot = returnSpots.popLast() else { return }
        if let here = currentSpot() { forwardSpots.append(here) }
        restore(spot)
    }

    /// 돌아가기 전에 보던 자리(링크로 옮겨 갔던 곳)로 다시 간다.
    func redoLinkJump() {
        guard let spot = forwardSpots.popLast() else { return }
        if let here = currentSpot() { returnSpots.append(here) }
        restore(spot)
    }

    private func restore(_ spot: Spot) {
        // 배율이 그대로면 스크롤 위치를 그대로 되돌리고, 그새 확대·축소했으면 그 쪽의 그 자리로 간다.
        if abs(spot.scale - scaleFactor) < 0.001, let clipView {
            clipView.scroll(to: spot.origin)
            clipView.enclosingScrollView?.reflectScrolledClipView(clipView)
        } else {
            go(to: spot.destination)
        }
    }

    func clearReturnSpots() {
        spotAtLinkClick = nil
        forwardSpots = []
        if !returnSpots.isEmpty { returnSpots = [] }
    }

    private func updateReturnBar() {
        guard let spot = returnSpots.last else {
            returnBar.removeFromSuperview()
            return
        }
        let label = spot.page.label ?? document.map { "\($0.index(for: spot.page) + 1)" } ?? ""
        returnBar.title = "Back to p. \(label)"
        guard returnBar.superview == nil else { return }
        returnBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(returnBar)
        NSLayoutConstraint.activate([
            returnBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            returnBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
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
        spotAtLinkClick = event.clickCount == 1 && internalLink(at: event.locationInWindow) != nil ? currentSpot() : nil
        linkClickLocation = event.locationInWindow
        super.mouseDown(with: event)
        // PDFView가 mouseDown 안에서 뗄 때까지 추적하며 링크를 따라갔을 수도 있다.
        DispatchQueue.main.async { [weak self] in self?.recordJumpIfMoved() }
    }

    // 링크에서 시작해 글자를 끌어 고르다 화면이 저절로 스크롤된 것은 옮겨 간 게 아니다.
    override func mouseDragged(with event: NSEvent) {
        if hypot(event.locationInWindow.x - linkClickLocation.x, event.locationInWindow.y - linkClickLocation.y) > 4 {
            spotAtLinkClick = nil
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        DispatchQueue.main.async { [weak self] in
            self?.recordJumpIfMoved()
            self?.spotAtLinkClick = nil
        }
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
              let regions = PDFLinks.citationPreview(for: annotation, on: page)?.filter({ $0.rect.width > 1 && $0.rect.height > 1 }),
              let first = regions.first
        else { return }
        // 두 단 논문의 한 단(약 260pt)이 읽기 좋은 크기가 되도록 키우고, 한 단 논문의 본문 너비는 너무 커지지 않게 줄인다.
        let scale = min(1.6, 520 / first.rect.width)
        // 다음 단·다음 쪽으로 이어진 부분은 아래에 붙이고, 사이에 옅은 선을 그어 끊긴 자리를 알린다.
        // 저자가 너무 많아 가운데를 건너뛴 자리에는 그렇다고 적는다.
        let gap: CGFloat = 7, omittedGap: CGFloat = 20
        let omittedText = NSAttributedString(string: "··· Many authors omitted ···", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.45, alpha: 1),
        ])
        let gaps = regions.dropFirst().map { $0.omittedBefore ? omittedGap : gap }.reduce(0, +)
        let size = NSSize(width: (regions.map(\.rect.width).max()! * scale).rounded(),
                          height: (regions.map { $0.rect.height * scale }.reduce(0, +) + gaps).rounded())
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            var top = size.height
            for (index, region) in regions.enumerated() {
                if index > 0, region.omittedBefore {
                    let textSize = omittedText.size()
                    omittedText.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: top - omittedGap / 2 - textSize.height / 2))
                    top -= omittedGap
                } else if index > 0 {
                    NSColor(white: 0.85, alpha: 1).setFill()
                    NSRect(x: 8, y: top - gap / 2 - 0.5, width: size.width - 16, height: 1).fill()
                    top -= gap
                }
                let frame = NSRect(x: 0, y: top - region.rect.height * scale,
                                   width: region.rect.width * scale, height: region.rect.height * scale)
                let box = region.page.bounds(for: .cropBox)
                context.saveGState()
                context.clip(to: frame)
                context.translateBy(x: frame.minX, y: frame.minY)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: box.minX - region.rect.minX, y: box.minY - region.rect.minY)
                region.page.draw(with: .cropBox, to: context)
                context.restoreGState()
                top = frame.minY
            }
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

/// 링크로 옮겨 간 뒤 PDF 아래쪽에 떠 있는 "돌아가기" 막대. 왼쪽은 돌아가기, 오른쪽 ×는 막대만 닫는다.
private final class ReturnBar: NSVisualEffectView {
    private let backButton: NSButton
    private let closeButton: NSButton

    var title: String {
        get { backButton.title }
        set { backButton.title = newValue }
    }

    init(back: @escaping () -> Void, close: @escaping () -> Void) {
        backButton = ActionButton(title: "", image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil), action: back)
        closeButton = ActionButton(title: "", image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close"), action: close)
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        backButton.imagePosition = .imageLeading
        backButton.font = .systemFont(ofSize: 13, weight: .medium)
        backButton.toolTip = "Return to where you clicked the link (⌘[)"
        closeButton.imagePosition = .imageOnly
        closeButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        closeButton.contentTintColor = .secondaryLabelColor
        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [backButton, divider, closeButton])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// 누르면 클로저를 부르는 테두리 없는 버튼.
private final class ActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, image: NSImage?, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        self.image = image
        isBordered = false
        bezelStyle = .inline
        target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
