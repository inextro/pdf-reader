import AppKit
import PDFKit
import PaperMarkCore

/// 형광펜 위에서 우클릭하면 지우기·색 바꾸기 메뉴를 앞에 붙이는 PDFView.
final class ReaderPDFView: PDFView {
    var highlightMenuItems: ((PlacedHighlight) -> [NSMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let target = highlight(at: event), let items = highlightMenuItems?(target), !items.isEmpty else {
            return menu
        }
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    private func highlight(at event: NSEvent) -> PlacedHighlight? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false),
              let annotation = Highlights.highlight(on: page, at: convert(point, to: page)) else { return nil }
        return PlacedHighlight(page: page, annotation: annotation)
    }
}
