import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/// 선택한 글을 기기 안에서(Apple Translation) 번역해 PDF의 선택 영역 옆에 띄운다.
/// 문장이나 문단 길이도 그대로 넘긴다.
enum Translator {
    static var isAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// 지금 떠 있는 번역 팝오버(또는 시스템 번역 팝업의 기준 뷰). 새로 띄우면 이전 것은 치운다.
    private static weak var currentPopover: NSPopover?
    private static weak var currentAnchor: NSView?

    /// rect는 view 좌표계에서 팝업 화살표가 가리킬 영역.
    static func present(_ text: String, at rect: NSRect, in view: NSView) {
        guard !text.isEmpty else { return }
        currentPopover?.close()
        currentAnchor?.removeFromSuperview()
        if #available(macOS 15, *) {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = TranslationViewController(text: text, source: sourceLanguage(of: text))
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
            currentPopover = popover
        } else if #available(macOS 14.4, *) {
            presentSystemPopup(text, at: rect, in: view)
        } else {
            NSSound.beep()
        }
    }

    /// 원문 언어. 논문은 대개 영어라서 영어로 보고, 다른 언어가 확실할 때(한국어 문단 등)만 그 언어로 한다.
    /// 시스템 번역 팝업은 원문 언어를 지정할 수 없어서 "infancy" 같은 단어 하나는 언어를 알아내지 못하고 매번 고르게 했다.
    static func sourceLanguage(of text: String) -> Locale.Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first, top.value >= 0.9
        else { return Locale.Language(identifier: "en") }
        return Locale.Language(identifier: top.key.rawValue)
    }

    /// macOS 14.4: 시스템 번역 팝업(원문 언어는 시스템이 알아낸다).
    @available(macOS 14.4, *)
    private static func presentSystemPopup(_ text: String, at rect: NSRect, in view: NSView) {
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

/// 번역 결과 팝오버: 번역문, 원문 → 번역 언어, 복사 버튼.
@available(macOS 15, *)
private final class TranslationViewController: NSViewController {
    private let text: String
    private let source: Locale.Language
    private let result = NSTextField(wrappingLabelWithString: "Translating…")
    private let languages = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private lazy var copyButton = NSButton(title: "Copy", target: self, action: #selector(copyTranslation(_:)))
    private lazy var resultWidth = result.widthAnchor.constraint(equalToConstant: 0)

    init(text: String, source: Locale.Language) {
        self.text = text
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        result.isSelectable = true
        result.textColor = .secondaryLabelColor
        languages.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        languages.textColor = .secondaryLabelColor
        languages.stringValue = "\(name(source)) →"
        languages.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copyButton.controlSize = .small
        copyButton.isEnabled = false
        let footer = NSStackView(views: [languages, copyButton])
        stack.setViews([result, footer], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 번역은 SwiftUI의 translationTask로 한다. 언어 모델이 없으면 시스템이 내려받을지 묻는다.
        let task = NSHostingView(rootView: TranslationTask(text: text, source: source) { [weak self] in self?.show($0) })
        task.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        let view = NSView()
        view.addSubview(task)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            resultWidth,
            footer.widthAnchor.constraint(equalTo: result.widthAnchor),
        ])
        self.view = view
        fitToResult()
    }

    /// 번역문 길이에 맞춰 폭을 정한다: 짧으면 좁게, 길면 360pt에서 줄을 바꾼다.
    private func fitToResult() {
        let size = result.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 360, height: CGFloat.greatestFiniteMagnitude))
        resultWidth.constant = max(ceil(size?.width ?? 0), 172)
        result.preferredMaxLayoutWidth = resultWidth.constant
        preferredContentSize = stack.fittingSize   // 창에 붙은 뒤의 view.fittingSize는 지금 창 크기에 끌려간다
    }

    private func show(_ outcome: Result<TranslationSession.Response, Error>) {
        switch outcome {
        case .success(let response):
            result.stringValue = response.targetText
            result.textColor = .labelColor
            languages.stringValue = "\(name(response.sourceLanguage)) → \(name(response.targetLanguage))"
            copyButton.isEnabled = true
        case .failure(let error):
            result.stringValue = "Couldn't translate: \(error.localizedDescription)"
        }
        fitToResult()
    }

    @objc private func copyTranslation(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.stringValue, forType: .string)
    }

    private func name(_ language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

/// 보이지 않는 뷰. 나타나면 text를 source에서 사용자의 언어로 번역해 done으로 넘긴다.
@available(macOS 15, *)
private struct TranslationTask: View {
    let text: String
    let source: Locale.Language
    let done: (Result<TranslationSession.Response, Error>) -> Void

    var body: some View {
        Color.clear.translationTask(source: source, target: nil) { session in
            let outcome: Result<TranslationSession.Response, Error>
            do { outcome = .success(try await session.translate(text)) } catch { outcome = .failure(error) }
            await MainActor.run { done(outcome) }
        }
    }
}

/// 보이지 않는 뷰. shown이면 시스템 번역 팝업을 띄우고, 팝업이 닫히면 스스로를 치운다.
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
