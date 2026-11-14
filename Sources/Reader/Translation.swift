import AppKit
import NaturalLanguage
import PDFKit
import PaperMarkCore
import SwiftUI
import Translation

/// 선택한 글을 기기 안에서(Apple Translation) 번역해 PDF의 선택 영역 옆에 띄운다.
/// 문장이나 문단 길이도 그대로 넘긴다. 수식은 자리표로 바꿔 번역하고 그 자리에 PDF에서 잘라 낸 그림을 넣는다.
enum Translator {
    static var isAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// 지금 떠 있는 번역 팝오버(또는 시스템 번역 팝업의 기준 뷰). 새로 띄우면 이전 것은 치운다.
    private static weak var currentPopover: NSPopover?
    private static weak var currentAnchor: NSView?

    /// rect는 view 좌표계에서 팝업 화살표가 가리킬 영역.
    static func present(_ selection: PDFSelection, at rect: NSRect, in view: NSView) {
        let split = PDFMath.split(selection)
        guard !split.text.isEmpty else { return }
        currentPopover?.close()
        currentAnchor?.removeFromSuperview()
        if #available(macOS 15, *) {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = TranslationViewController(split: split, source: sourceLanguage(of: split.text))
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
            currentPopover = popover
        } else if #available(macOS 14.4, *) {
            presentSystemPopup(split.plain, at: rect, in: view)
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

/// 번역 결과 팝오버: 번역문(수식은 그림), 원문 → 번역 언어, 복사 버튼.
@available(macOS 15, *)
private final class TranslationViewController: NSViewController {
    /// 번역문 글자 크기와 줄을 바꾸는 폭. 논문을 읽는 중에 바로 알아볼 수 있게 본문보다 크게 한다.
    private static let font = NSFont.systemFont(ofSize: 17)
    private static let maxWidth: CGFloat = 520

    private let split: PDFMath.Split
    private let source: Locale.Language
    private let result = NSTextField(wrappingLabelWithString: "Translating…")
    private let languages = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private lazy var copyButton = NSButton(title: "Copy", target: self, action: #selector(copyTranslation(_:)))
    private lazy var resultWidth = result.widthAnchor.constraint(equalToConstant: 0)
    private var copyText = ""

    init(split: PDFMath.Split, source: Locale.Language) {
        self.split = split
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        result.isSelectable = true
        result.font = Self.font
        result.textColor = .secondaryLabelColor
        languages.font = .systemFont(ofSize: 12)
        languages.textColor = .secondaryLabelColor
        languages.stringValue = "\(name(source)) →"
        languages.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copyButton.isEnabled = false
        let footer = NSStackView(views: [languages, copyButton])
        stack.setViews([result, footer], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 번역은 SwiftUI의 translationTask로 한다. 언어 모델이 없으면 시스템이 내려받을지 묻는다.
        let task = NSHostingView(rootView: TranslationTask(text: split.text, source: source) { [weak self] in self?.show($0) })
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

    /// 번역문 길이에 맞춰 폭을 정한다: 짧으면 좁게, 길면 maxWidth에서 줄을 바꾼다.
    private func fitToResult() {
        let size = result.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.maxWidth, height: CGFloat.greatestFiniteMagnitude))
        resultWidth.constant = min(max(ceil(size?.width ?? 0), 240), Self.maxWidth)
        result.preferredMaxLayoutWidth = resultWidth.constant
        preferredContentSize = stack.fittingSize   // 창에 붙은 뒤의 view.fittingSize는 지금 창 크기에 끌려간다
    }

    private func show(_ outcome: Result<TranslationSession.Response, Error>) {
        switch outcome {
        case .success(let response):
            let (attributed, plain) = render(response.targetText)
            result.attributedStringValue = attributed
            copyText = plain
            languages.stringValue = "\(name(response.sourceLanguage)) → \(name(response.targetLanguage))"
            copyButton.isEnabled = true
        case .failure(let error):
            result.stringValue = "Couldn't translate: \(error.localizedDescription)"
        }
        fitToResult()
    }

    /// 번역문의 자리표를 수식 그림으로 바꾼다. 번역기가 자리표를 빠뜨렸으면 그 수식은 끝에 붙인다.
    /// 복사할 글에는 그림 대신 PDF에서 뽑은 수식 글자를 넣는다.
    private func render(_ translated: String) -> (NSAttributedString, String) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        let out = NSMutableAttributedString()
        var plain = ""
        var pieces = split.pieces(of: translated)
        let used = Set(pieces.compactMap { if case .math(let i) = $0 { return i } else { return nil } })
        for i in split.spans.indices where !used.contains(i) { pieces += [.text(" "), .math(i)] }
        for piece in pieces {
            switch piece {
            case .text(let s):
                out.append(NSAttributedString(string: s, attributes: attributes))
                plain += s
            case .math(let i):
                let span = split.spans[i]
                // 텍스트 필드 안쪽 여백만큼 좁혀야 별행 수식 끝(식 번호)이 잘리지 않는다.
                let images = span.rects.compactMap { MathImage.make(span.page, $0, lineHeight: split.lineHeight,
                                                                    font: Self.font, maxWidth: Self.maxWidth - 12) }
                if images.isEmpty {
                    out.append(NSAttributedString(string: span.text, attributes: attributes))
                } else {
                    for attachment in images { out.append(NSAttributedString(attachment: attachment)) }
                }
                plain += span.text
            }
        }
        return (out, plain)
    }

    @objc private func copyTranslation(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
    }

    private func name(_ language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

/// PDF에서 잘라 낸 수식 그림. 번역문 글자와 같은 크기로 맞추고, 글자 색으로 칠해 어두운 화면에서도 보이게 한다.
private enum MathImage {
    static func make(_ page: PDFPage, _ rect: CGRect, lineHeight: CGFloat, font: NSFont, maxWidth: CGFloat) -> NSTextAttachment? {
        // PDF 본문 한 줄 높이가 번역문 한 줄(ascender~descender) 높이가 되게 키운다. 너무 넓으면 폭에 맞춰 줄인다.
        var scale = (font.ascender - font.descender) / max(lineHeight, 1)
        scale = min(scale, maxWidth / max(rect.width, 1))
        guard let mask = inkMask(page, rect, pixelsPerPoint: scale * 3) else { return nil }
        let size = NSSize(width: rect.width * scale, height: rect.height * scale)
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.clip(to: bounds, mask: mask)
            NSColor.labelColor.setFill()   // 그릴 때마다 지금 화면 모드의 글자 색을 쓴다
            bounds.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // PDF 줄 상자의 가운데를 번역문 글자의 가운데에 맞춘다.
        attachment.bounds = CGRect(x: 0, y: (font.ascender + font.descender) / 2 - size.height / 2,
                                   width: size.width, height: size.height)
        return attachment
    }

    /// rect 부분을 흑백으로 그린 뒤 뒤집어, 잉크가 있는 곳만 칠해지는 마스크를 만든다.
    /// 페이지 내용만 그리므로(pageRef) 형광펜 같은 주석은 들어가지 않는다.
    private static func inkMask(_ page: PDFPage, _ rect: CGRect, pixelsPerPoint: CGFloat) -> CGImage? {
        guard let pageRef = page.pageRef else { return nil }
        let width = Int(ceil(rect.width * pixelsPerPoint)), height = Int(ceil(rect.height * pixelsPerPoint))
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.drawPDFPage(pageRef)
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        for i in 0..<(ctx.bytesPerRow * height) { bytes[i] = 255 - bytes[i] }
        return ctx.makeImage()
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
