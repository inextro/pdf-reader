import AppKit
import PaperMarkLibrary

/// Settings → BibTeX. Copy BibTeX(⇧⌘B)에서 내보낼 필드를 고르고, 예시 논문 두 편으로 결과를 바로 보여 준다.
final class BibTeXSettingsView: NSView {
    private var boxes: [String: NSButton] = [:]
    private let urlWithDOI = NSButton(checkboxWithTitle: "Include the URL even when the paper has a DOI", target: nil, action: nil)
    private let preview = NSTextView()

    /// 예시: 학회 논문 하나와 arXiv 프리프린트 하나.
    private static let samples: [(PaperMetadata, String, [String])] = {
        var conf = PaperMetadata()
        conf.type = "conferencePaper"
        conf.title = "LightGCN: Simplifying and powering graph convolution network for recommendation"
        conf.creators = [Creator(role: "author", family: "He", given: "Xiangnan"), Creator(role: "author", family: "Deng", given: "Kuan")]
        conf.date = "2020-07-25"
        conf.doi = "10.1145/3397271.3401063"
        conf.url = "https://dl.acm.org/doi/10.1145/3397271.3401063"
        conf.abstract = "Graph Convolution Network (GCN) has become new state-of-the-art for collaborative filtering."
        conf.fields = ["proceedingsTitle": "Proceedings of the 43rd International ACM SIGIR Conference on Research and Development in Information Retrieval",
                       "pages": "639-648", "publisher": "ACM", "place": "New York, NY, USA", "series": "SIGIR '20", "ISBN": "978-1-4503-8016-4"]
        var pre = PaperMetadata()
        pre.type = "preprint"
        pre.title = "Attention is all you need"
        pre.creators = [Creator(role: "author", family: "Vaswani", given: "Ashish"), Creator(role: "author", family: "Shazeer", given: "Noam")]
        pre.date = "2017-06-12"
        pre.doi = "10.48550/arXiv.1706.03762"
        pre.arxivID = "1706.03762"
        pre.url = "https://arxiv.org/abs/1706.03762"
        pre.fields = ["repository": "arXiv", "primaryClass": "cs.CL"]
        return [(conf, "he2020lightgcn", ["recommendation", "GNN"]), (pre, "vaswani2017attention", ["transformer"])]
    }()

    init() {
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: "Fields in Copy BibTeX (⇧⌘B)")
        heading.font = .boldSystemFont(ofSize: Style.fontSize)
        let note = NSTextField(wrappingLabelWithString: "Uncheck the fields you don’t want in your .bib file. "
                               + "A field appears only when the paper has a value for it. The title is always included.")
        note.font = .systemFont(ofSize: Style.fontSize - 2)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 640

        // 이름순으로, 사전처럼 위에서 아래로 읽고 다음 열로 넘어간다.
        let columns = 4
        let names = BibTeX.fields.sorted { $0.lowercased() < $1.lowercased() }
        let height = (names.count + columns - 1) / columns
        var rows: [[NSView]] = []
        for row in 0..<height {
            rows.append((0..<columns).map { row + $0 * height }.map { i -> NSView in
                guard i < names.count else { return NSGridCell.emptyContentView }
                let box = NSButton(checkboxWithTitle: names[i], target: self, action: #selector(changed(_:)))
                box.font = .monospacedSystemFont(ofSize: Style.fontSize - 1, weight: .regular)
                box.isEnabled = names[i] != "title"
                boxes[names[i].lowercased()] = box
                return box
            })
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 22
        urlWithDOI.font = Style.font
        urlWithDOI.target = self
        urlWithDOI.action = #selector(changed(_:))
        let allOn = NSButton(title: "Include All", target: self, action: #selector(includeAll(_:)))
        allOn.font = .systemFont(ofSize: Style.fontSize - 2)

        let previewHeading = NSTextField(labelWithString: "Preview")
        previewHeading.font = .boldSystemFont(ofSize: Style.fontSize)
        preview.isEditable = false
        preview.isSelectable = true
        preview.font = .monospacedSystemFont(ofSize: Style.fontSize - 2, weight: .regular)
        preview.textContainerInset = NSSize(width: 6, height: 6)
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = preview
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalToConstant: 660), scroll.heightAnchor.constraint(equalToConstant: 250)])

        let stack = NSStackView(views: [heading, note, grid, urlWithDOI, allOn, previewHeading, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: note)
        stack.setCustomSpacing(14, after: grid)
        stack.setCustomSpacing(20, after: allOn)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func reload() {
        let options = Settings.bibtex
        for (name, box) in boxes { box.state = options.omitted.contains(name) && name != "title" ? .off : .on }
        urlWithDOI.state = options.urlWithDOI ? .on : .off
        urlWithDOI.isEnabled = !options.omitted.contains("url")
        preview.string = Self.samples.map { BibTeX.entry($0.0, key: $0.1, tags: $0.2, options: options) }.joined(separator: "\n\n")
    }

    @objc private func changed(_ sender: NSButton) {
        Settings.bibtex = BibTeXOptions(omitted: Set(boxes.filter { $0.value.state == .off }.map(\.key)),
                                        urlWithDOI: urlWithDOI.state == .on)
        reload()
    }

    @objc private func includeAll(_ sender: Any?) {
        Settings.bibtex = BibTeXOptions(omitted: [], urlWithDOI: Settings.bibtex.urlWithDOI)
        reload()
    }
}
