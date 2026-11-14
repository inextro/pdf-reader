import AppKit
import PDFKit

/// 리더 사이드바: PDF의 목차(Contents). 폴더 트리(Files)는 서재가 그 역할을 해서 Quillo에 합치며 뺐다.
final class SidebarViewController: NSViewController {
    private let contents: ContentsView

    init(pdfView: PDFView) {
        contents = ContentsView(pdfView: pdfView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let view = NSView()
        contents.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contents)
        // 사이드바는 창 꼭대기(신호등·툴바 뒤)까지 깔리므로 목차는 툴바 아래(safe area)부터 둔다.
        NSLayoutConstraint.activate([
            contents.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            contents.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contents.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contents.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
    }
}
