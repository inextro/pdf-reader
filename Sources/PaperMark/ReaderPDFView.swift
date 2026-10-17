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
