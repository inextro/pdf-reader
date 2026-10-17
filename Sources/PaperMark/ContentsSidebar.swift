import AppKit
import PDFKit
import PaperMarkCore

/// 목차 항목 하나. PDFOutline은 child(at:)마다 같은 객체를 준다는 보장이 없어서 트리를 한 번 옮겨 담는다.
private final class ContentsNode: NSObject {
    let label: String
    let destination: PDFDestination?
    let position: PDFContents.Position?
    let isOpen: Bool
    var children: [ContentsNode] = []
    weak var parent: ContentsNode?

    init(_ item: PDFOutline, in document: PDFDocument) {
        label = (item.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        destination = PDFLinks.destination(of: item)
        position = destination.flatMap { d in
            d.page.map { PDFContents.Position(page: document.index(for: $0), y: PDFLinks.point(of: d).y) }
        }
        isOpen = item.isOpen
        super.init()
        children = (0..<item.numberOfChildren).compactMap { item.child(at: $0) }.map {
            let child = ContentsNode($0, in: document)
            child.parent = self
            return child
        }
    }

    /// 자신과 모든 하위 항목을 목차 순서대로.
    var flattened: [ContentsNode] { [self] + children.flatMap(\.flattened) }
}

/// 목차 한 행: 제목 … 쪽 번호.
private final class ContentsCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ContentsCell")
    let pageLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)   // 남는 폭을 제목이 차지해 쪽 번호를 오른쪽 끝에 둔다
        pageLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.setContentHuggingPriority(.required, for: .horizontal)
        pageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [text, pageLabel])
        stack.distribution = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = text
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Return으로도 이동하는 목차.
private final class ContentsOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}

/// 사이드바의 Contents 탭: PDF에 든 목차(북마크). 누르면 그 절로 가고, 스크롤하면 지금 읽는 절을 강조한다.
/// 목차가 없는 PDF는 안내 문구만 보인다.
final class ContentsView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private weak var pdfView: PDFView?
    private let outline = ContentsOutlineView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No Table of Contents")
    private var roots: [ContentsNode] = []
    private var entries: [ContentsNode] = []
    // 지금 읽는 절을 따라 선택을 옮기는 중에는 선택이 바뀌어도 이동하지 않는다.
    private var syncing = false

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: .zero)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.rowHeight = 22
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.onReturn = { [weak self] in self?.goToSelected() }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center

        for view in [scroll, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 40),
        ])

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(documentChanged), name: .PDFViewDocumentChanged, object: pdfView)
        center.addObserver(self, selector: #selector(trackCurrent), name: .PDFViewPageChanged, object: pdfView)
        // 같은 쪽 안에서 절이 바뀌는 것도 따라가려고 PDF의 스크롤도 본다.
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(trackCurrent), name: NSView.boundsDidChangeNotification, object: clip)
        }
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: 읽기

    @objc private func documentChanged() {
        if let document = pdfView?.document, let root = document.outlineRoot {
            roots = (0..<root.numberOfChildren).compactMap { root.child(at: $0) }.map { ContentsNode($0, in: document) }
        } else {
            roots = []
        }
        entries = roots.flatMap(\.flattened)
        // 시작 탭처럼 PDF가 없으면 안내 문구도 띄우지 않는다.
        emptyLabel.isHidden = !entries.isEmpty || pdfView?.document == nil
        outline.reloadData()
        // 논문 목차는 절·소절을 합쳐도 짧아서 다 펼친다. 긴 책은 PDF가 펼쳐 두라고 한 항목만.
        let expandAll = entries.count <= 80
        for node in entries where expandAll || node.isOpen { outline.expandItem(node) }
        trackCurrent()
    }

    // MARK: 이동

    @objc private func rowClicked(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.clickedRow) as? ContentsNode else { return }
        go(to: node)
    }

    private func goToSelected() {
        guard let node = outline.item(atRow: outline.selectedRow) as? ContentsNode else { return }
        go(to: node)
    }

    private func go(to node: ContentsNode) {
        guard let destination = node.destination else { return }
        pdfView?.go(to: destination)
    }

    /// 화살표 키로 고르면 바로 그 절로 간다(마우스로 누른 것은 rowClicked가 맡는다).
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, NSApp.currentEvent?.type == .keyDown else { return }
        goToSelected()
    }

    // MARK: 지금 읽는 절

    /// 보이는 영역 위에서 1/4 내려온 곳을 읽는 위치로 보고, 그곳을 지난 마지막 절을 고른다.
    /// 그 절이 접힌 항목 안에 있으면 보이는 조상을 고른다.
    @objc private func trackCurrent() {
        guard !isHidden, !entries.isEmpty, let pdfView, let document = pdfView.document else { return }
        // PDF는 반투명 툴바 뒤까지 깔려 있으므로 툴바 아래부터를 보이는 영역으로 친다.
        var visible = pdfView.bounds
        if let window = pdfView.window {
            visible = visible.intersection(pdfView.convert(window.contentLayoutRect, from: nil))
        }
        let probe = NSPoint(x: visible.midX, y: visible.maxY - visible.height / 4)
        guard let page = pdfView.page(for: probe, nearest: true) else { return }
        let at = PDFContents.Position(page: document.index(for: page), y: pdfView.convert(probe, to: page).y)
        let positions = entries.map { $0.position ?? PDFContents.Position(page: .max, y: 0) }
        guard let index = PDFContents.current(in: positions, at: at) else {
            select(nil)
            return
        }
        var node: ContentsNode? = entries[index]
        while let n = node, outline.row(forItem: n) < 0 { node = n.parent }
        select(node)
    }

    private func select(_ node: ContentsNode?) {
        let row = node.map { outline.row(forItem: $0) } ?? -1
        guard row != outline.selectedRow else { return }
        syncing = true
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
        syncing = false
    }

    override var isHidden: Bool {
        didSet { if !isHidden { trackCurrent() } }
    }

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ContentsNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ContentsNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? ContentsNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ContentsNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: ContentsCell.id, owner: nil) as? ContentsCell ?? ContentsCell()
        cell.textField?.stringValue = node.label
        cell.toolTip = node.label
        // 쪽 번호는 PDF에 적힌 쪽 이름(로마 숫자 등)이 있으면 그것을, 없으면 순서 번호.
        cell.pageLabel.stringValue = node.destination?.page.map { $0.label ?? "" } ?? ""
        return cell
    }

    func outlineViewItemDidCollapse(_ notification: Notification) { trackCurrent() }
    func outlineViewItemDidExpand(_ notification: Notification) { trackCurrent() }
}
