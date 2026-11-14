import AppKit

/// 서재에서 PDF를 연다. Quillo의 리더 탭으로 열리고, 서재 탭이 있는 창의 맨 끝 탭에 붙는다.
enum PDFOpener {
    static func open(_ pdf: URL, from window: NSWindow?) {
        NSDocumentController.shared.openDocument(withContentsOf: pdf, display: true) { _, _, error in
            guard let error else { return }
            let alert = NSAlert(error: error)
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }
}
