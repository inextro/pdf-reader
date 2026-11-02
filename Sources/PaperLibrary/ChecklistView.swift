import AppKit

/// 체크박스 목록. 줄을 끌어 순서를 바꾼다. 켠 것만 순서대로 onChange로 알린다.
final class ChecklistView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Entry {
        var id: String
        var title: String
        var on: Bool
        /// 끌 수 없는 줄(표의 Title 열).
        var locked = false
    }

    var onChange: ([String]) -> Void = { _ in }
    private var entries: [Entry] = []
    private let table = NSTableView()
    private static let dragType = NSPasteboard.PasteboardType("com.inextro.paperlibrary.checklist-row")

    override init(frame: NSRect) {
        super.init(frame: frame)
        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.rowHeight = Style.rowHeight + 2
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// shown: 켠 것(순서대로). all: 고를 수 있는 전부. 꺼진 것은 all의 순서로 뒤에 붙인다.
    func set(all: [(id: String, title: String)], shown: [String], locked: Set<String> = []) {
        let titles = Dictionary(all.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        entries = shown.compactMap { id in titles[id].map { Entry(id: id, title: $0, on: true, locked: locked.contains(id)) } }
            + all.filter { !shown.contains($0.id) }.map { Entry(id: $0.id, title: $0.title, on: false) }
        table.reloadData()
    }

    private func changed() {
        onChange(entries.filter(\.on).map(\.id))
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let box = NSButton(checkboxWithTitle: entries[row].title, target: self, action: #selector(toggle(_:)))
        box.font = Style.font
        box.state = entries[row].on ? .on : .off
        box.isEnabled = !entries[row].locked
        box.tag = row
        let handle = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to reorder")!)
        handle.contentTintColor = .tertiaryLabelColor
        let cell = NSStackView(views: [box, NSView(), handle])
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        return cell
    }

    @objc private func toggle(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        entries[sender.tag].on = sender.state == .on
        changed()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let from = info.draggingPasteboard.string(forType: Self.dragType).flatMap(Int.init),
              entries.indices.contains(from) else { return false }
        let entry = entries.remove(at: from)
        let to = from < row ? row - 1 : row
        entries.insert(entry, at: min(to, entries.count))
        tableView.reloadData()
        changed()
        return true
    }
}
