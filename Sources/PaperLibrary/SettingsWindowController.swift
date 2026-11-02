import AppKit
import PaperMarkLibrary

/// PaperLibrary > Settings…(⌘,). 브라우저 확장으로 논문을 넣을 때 서지 정보를 채우는 방식과 PDF 저장 위치를 고른다.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let libraryFolderLabel = NSTextField(labelWithString: "")
    private let pdfFolderLabel = NSTextField(labelWithString: "")
    private let fileNameField = NSTextField()
    private let fileNamePreview = NSTextField(labelWithString: "")
    private let keyField = NSTextField()
    private let keyPreview = NSTextField(labelWithString: "")
    private let preferOnline = NSButton(checkboxWithTitle: "Prefer CrossRef and arXiv over the web page’s own metadata", target: nil, action: nil)
    private let publishedVersion = NSButton(checkboxWithTitle: "For arXiv papers, use the published version (conference or journal) when one is found",
                                            target: nil, action: nil)
    private let sentenceCase = NSButton(checkboxWithTitle: "Write titles in sentence case (only the first word capitalized)", target: nil, action: nil)
    private let connectorLabel = NSTextField(labelWithString: "")

    /// 미리보기에 쓰는 예시 논문.
    private static let sample: PaperMetadata = {
        var m = PaperMetadata()
        m.type = "conferencePaper"
        m.title = "LightGCN: Simplifying and Powering Graph Convolution Network for Recommendation"
        m.creators = [Creator(role: "author", family: "He", given: "Xiangnan"), Creator(role: "author", family: "Deng", given: "Kuan"),
                      Creator(role: "author", family: "Wang", given: "Xiang")]
        m.date = "2020-07-25"
        m.venue = "Proceedings of the 43rd International ACM SIGIR Conference on Research and Development in Information Retrieval"
        return m
    }()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PaperLibrary Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        for field in [fileNameField, keyField] {
            field.delegate = self
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        for label in [fileNamePreview, keyPreview, connectorLabel, libraryFolderLabel, pdfFolderLabel] {
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 560).isActive = true
        }
        for box in [preferOnline, publishedVersion, sentenceCase] {
            box.target = self
            box.action = #selector(lookupChanged(_:))
        }
        let tokens = NSTextField(wrappingLabelWithString: "Tokens: " + Naming.tokens.joined(separator: " ")
                                 + "  ({Title2}, {Title3}: first two or three words)")
        tokens.textColor = .secondaryLabelColor
        tokens.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tokens.preferredMaxLayoutWidth = 560

        let changeLibrary = NSButton(title: "Change…", target: self, action: #selector(chooseLibraryFolder(_:)))
        let changePDF = NSButton(title: "Change…", target: self, action: #selector(choosePDFFolder(_:)))
        let grid = NSGridView(views: [
            [Self.header("Library folder:"), Self.row(libraryFolderLabel, changeLibrary)],
            [Self.header("Save new PDFs in:"), Self.row(pdfFolderLabel, changePDF)],
            [Self.header("PDF file name:"), fileNameField],
            [NSGridCell.emptyContentView, fileNamePreview],
            [Self.header("Citation key:"), keyField],
            [NSGridCell.emptyContentView, keyPreview],
            [NSGridCell.emptyContentView, tokens],
            [Self.header("Metadata:"), preferOnline],
            [NSGridCell.emptyContentView, publishedVersion],
            [Self.header("Titles:"), sentenceCase],
            [Self.header("Browser extension:"), connectorLabel],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for row in [2, 6, 7, 9, 10] { grid.row(at: row).topPadding = 10 }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        window.contentView = content
        Style.enlarge(content)

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Connector.statusDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: LibraryStore.didChange, object: nil)
        fileNameField.stringValue = Settings.fileNamePattern
        keyField.stringValue = Settings.citationKeyPattern
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private static func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }

    @objc private func refresh() {
        libraryFolderLabel.stringValue = LibraryStore.shared.folder?.path ?? "Not set"
        pdfFolderLabel.stringValue = Settings.pdfFolder?.path ?? "Not set"
        let lookup = Settings.lookup
        preferOnline.state = lookup.preferOnline ? .on : .off
        publishedVersion.state = lookup.usePublishedVersion ? .on : .off
        sentenceCase.state = lookup.sentenceCase ? .on : .off
        connectorLabel.stringValue = Connector.shared.status
        updatePreviews()
    }

    private func updatePreviews() {
        var sample = Self.sample
        if Settings.lookup.sentenceCase { sample.title = PaperMetadata.sentenceCase(sample.title) }
        fileNamePreview.stringValue = "e.g. " + Naming.fileName(pattern: Settings.fileNamePattern, metadata: sample) + ".pdf"
        keyPreview.stringValue = "e.g. " + Naming.citationKey(pattern: Settings.citationKeyPattern, metadata: sample, taken: [])
    }

    func controlTextDidChange(_ notification: Notification) {
        let fileName = fileNameField.stringValue.trimmingCharacters(in: .whitespaces)
        let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        Settings.fileNamePattern = fileName.isEmpty ? Naming.defaultFileName : fileName
        Settings.citationKeyPattern = key.isEmpty ? Naming.defaultCitationKey : key
        updatePreviews()
    }

    @objc private func lookupChanged(_ sender: NSButton) {
        Settings.lookup = LookupOptions(preferOnline: preferOnline.state == .on, usePublishedVersion: publishedVersion.state == .on,
                                        sentenceCase: sentenceCase.state == .on)
        updatePreviews()
    }

    @objc private func chooseLibraryFolder(_ sender: Any?) {
        choose("Choose the folder that holds your library PDFs. Paths in the library are stored relative to it.",
               from: LibraryStore.shared.folder ?? LibraryStore.googleDriveFolder()) { LibraryStore.shared.folder = $0 }
    }

    @objc private func choosePDFFolder(_ sender: Any?) {
        choose("Choose where PDFs saved from the browser go. A folder inside the library folder keeps paths portable.",
               from: Settings.pdfFolder ?? LibraryStore.shared.folder) { folder in
            Settings.pdfFolder = folder
            if LibraryStore.shared.folder == nil { LibraryStore.shared.folder = folder }
        }
    }

    private func choose(_ message: String, from directory: URL?, then done: @escaping (URL) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { done(url) }
            self?.refresh()
        }
    }
}
