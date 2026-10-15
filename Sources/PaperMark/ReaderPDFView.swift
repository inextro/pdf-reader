import AppKit
import PDFKit
import PaperMarkCore

/// 형광펜 등 사용자 주석 위에서 우클릭하면 지우기·색 바꾸기 메뉴를 앞에 붙이는 PDFView.
final class ReaderPDFView: PDFView {
    var highlightMenuItems: ((PlacedHighlight) -> [NSMenuItem])?
    /// 주석이 아닌 곳을 우클릭했을 때, 선택한 글자가 있으면 앞에 붙일 항목(번역 등).
    var selectionMenuItems: (() -> [NSMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
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
