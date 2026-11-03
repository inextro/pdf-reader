import AppKit

/// PaperLibrary의 글자 크기. 시스템 기본(13pt)이 작아 읽기 힘들다고 해서 앱 전체를 2pt씩 키웠다.
enum Style {
    static let fontSize: CGFloat = 15
    static var font: NSFont { .systemFont(ofSize: fontSize) }
    static let rowHeight: CGFloat = 26

    /// 설정 창·팝오버처럼 표준 컨트롤로 만든 화면: 안의 글자를 모두 2pt 키운다.
    static func enlarge(_ view: NSView) {
        if let control = view as? NSControl, let font = control.font {
            control.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize + 2)
        }
        view.subviews.forEach(enlarge)
    }
}
