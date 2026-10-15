import AppKit
import SwiftUI
import Translation

/// macOS 기본 번역 팝업(Apple Translation, 기기 안에서 처리)을 PDF의 선택 영역 옆에 띄운다.
/// 문장이나 문단 길이도 그대로 넘긴다.
enum Translator {
    static var isAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// 지금 떠 있는 번역 팝업의 기준 뷰. 새로 띄우면 이전 것은 치운다.
    private static weak var currentAnchor: NSView?

    /// rect는 view 좌표계에서 팝업 화살표가 가리킬 영역.
    static func present(_ text: String, at rect: NSRect, in view: NSView) {
        guard !text.isEmpty else { return }
        guard #available(macOS 14.4, *) else { NSSound.beep(); return }
        currentAnchor?.removeFromSuperview()

        final class Box { weak var view: NSView? }
        let box = Box()
        let dismiss: () -> Void = { box.view?.removeFromSuperview() }
        // 닫힌 상태로 붙인 뒤 다음 순간 열린 상태로 바꿔서, 팝업이 확실히 "열림"으로 바뀌며 뜨게 한다.
        let anchor = NSHostingView(rootView: TranslationAnchor(text: text, shown: false, onDismiss: dismiss))
        box.view = anchor
        anchor.frame = rect
        view.addSubview(anchor)
        currentAnchor = anchor
        DispatchQueue.main.async {
            anchor.rootView = TranslationAnchor(text: text, shown: true, onDismiss: dismiss)
        }
    }
}

/// 보이지 않는 뷰. shown이면 번역 팝업을 띄우고, 팝업이 닫히면 스스로를 치운다.
/// (Xcode 없이 빌드하므로 SwiftUI 매크로인 @State 대신 일반 클래스로 상태를 들고 바인딩을 직접 만든다.)
@available(macOS 14.4, *)
private struct TranslationAnchor: View {
    private final class Presentation {
        var shown: Bool
        init(_ shown: Bool) { self.shown = shown }
    }

    let text: String
    let onDismiss: () -> Void
    private let presentation: Presentation

    init(text: String, shown: Bool, onDismiss: @escaping () -> Void) {
        self.text = text
        self.onDismiss = onDismiss
        presentation = Presentation(shown)
    }

    var body: some View {
        Color.clear.translationPresentation(isPresented: Binding(
            get: { presentation.shown },
            set: { shown in
                presentation.shown = shown
                if !shown { onDismiss() }
            }), text: text)
    }
}
