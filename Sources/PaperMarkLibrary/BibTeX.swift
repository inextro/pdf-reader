import Foundation

/// Copy BibTeX에서 내보낼 필드. Settings → BibTeX에서 고른다(Better BibTeX의 "Fields to omit"과 같은 역할).
public struct BibTeXOptions: Equatable {
    /// 내보내지 않을 필드 이름(소문자).
    public var omitted: Set<String>
    /// DOI가 있어도 url을 적는다. 끄면(기본) DOI가 없는 항목만 url을 적는다.
    public var urlWithDOI: Bool
    /// keywords에서 뺄 태그(읽기 상태 태그 등). 대소문자를 가리지 않는다.
    public var hiddenTags: [String]

    public init(omitted: Set<String> = [], urlWithDOI: Bool = false, hiddenTags: [String] = []) {
        self.omitted = Set(omitted.map { $0.lowercased() })
        self.urlWithDOI = urlWithDOI
        self.hiddenTags = hiddenTags
    }
}

/// 항목을 BibTeX 항목(@article{key, …})으로 만든다. 표에서 Copy BibTeX(⌘⇧B)로 복사해 LaTeX의 .bib에 붙인다.
/// 키는 항목의 citation key(Better BibTeX에서 가져온 것 포함)를 그대로 쓴다.
/// 필드 이름은 BibTeX와 biblatex가 함께 읽는 것을 쓰고, 한쪽만 아는 필드(urldate, eprint 등)는 다른 쪽이 무시한다.
public enum BibTeX {
    /// 내보낼 수 있는 필드 전부(설정 화면의 순서). title은 늘 내보낸다.
    public static let fields: [String] = [
        "title", "author", "editor", "journal", "booktitle", "series", "edition", "volume", "number", "articleno", "pages",
        "publisher", "address", "school", "institution", "howpublished", "eprint", "archivePrefix", "primaryClass",
        "year", "month", "doi", "url", "urldate", "isbn", "issn", "abstract", "keywords",
    ]

    public static func entries(_ items: [LibraryEntry], options: BibTeXOptions = BibTeXOptions()) -> String {
        items.map { entry($0, options: options) }.joined(separator: "\n\n")
    }

    public static func entry(_ e: LibraryEntry, options: BibTeXOptions = BibTeXOptions()) -> String {
        entry(PaperMetadata(e), key: e.citationKey.flatMap { $0.isEmpty ? nil : $0 } ?? "item\(e.id)", tags: e.tags, options: options)
    }

    public static func entry(_ e: PaperMetadata, key: String, tags: [String] = [], options: BibTeXOptions = BibTeXOptions()) -> String {
        func field(_ names: String...) -> String? {
            names.lazy.compactMap { e.fields[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }
        var out: [(String, String)] = []
        func add(_ name: String, _ value: String?, raw: Bool = false) {
            guard name == "title" || !options.omitted.contains(name.lowercased()),
                  let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            out.append((name, raw ? value : escape(value)))
        }

        let type: String
        let arxiv = e.doi.flatMap { $0.lowercased().hasPrefix("10.48550/") ? PaperID.arxiv(in: $0) : nil } ?? e.arxivID
        let authors = e.creators.filter { $0.role == "author" }
        add("title", protect(e.title), raw: true)
        // 저자가 없으면 다른 사람(편집자 등)을 저자로 쓴다. 다만 편집한 책은 편집자를 editor로 둔다.
        let editors = e.creators.filter { $0.role == "editor" }
        let editedBook = authors.isEmpty && ["book", "bookSection"].contains(e.type)
        add("author", names(authors.isEmpty ? (editedBook ? [] : e.creators) : authors), raw: true)
        if !authors.isEmpty || editedBook { add("editor", names(editors), raw: true) }

        switch e.type {
        case "journalArticle":
            type = "article"
            add("journal", field("publicationTitle") ?? e.venue)
            add("volume", field("volume"))
            add("number", field("issue"))
            add("articleno", field(ArticleNumber.key))
            add("pages", pages(field("pages")), raw: true)
            add("publisher", field("publisher"))
        case "conferencePaper":
            type = "inproceedings"
            add("booktitle", field("proceedingsTitle", "conferenceName") ?? e.venue)
            add("series", field("series"))
            add("pages", pages(field("pages")), raw: true)
            add("publisher", field("publisher"))
            add("address", field("place"))
        case "bookSection":
            type = "incollection"
            add("booktitle", field("bookTitle", "publicationTitle") ?? e.venue)
            add("pages", pages(field("pages")), raw: true)
            add("publisher", field("publisher"))
            add("address", field("place"))
        case "book":
            type = "book"
            add("edition", field("edition"))
            add("series", field("series"))
            add("publisher", field("publisher"))
            add("address", field("place"))
        case "thesis":
            type = (field("thesisType") ?? "").lowercased().contains("master") ? "mastersthesis" : "phdthesis"
            add("school", field("university", "publisher"))
            add("address", field("place"))
        case "report":
            type = "techreport"
            add("institution", field("institution", "publisher"))
            add("number", field("reportNumber", "number"))
            add("address", field("place"))
        case "preprint":
            type = "misc"
            if let arxiv {
                add("eprint", arxiv)
                add("archivePrefix", "arXiv")
                add("primaryClass", field("primaryClass"))
            } else {
                add("howpublished", field("repository", "publisher") ?? e.venue)
            }
        default:
            type = "misc"
            add("howpublished", field("websiteTitle", "publicationTitle") ?? e.venue)
        }
        // arXiv 논문을 eprint 없이 내보내면 어디 실렸는지가 사라지므로 howpublished로 남긴다.
        if type == "misc", arxiv != nil, options.omitted.contains("eprint"), !out.contains(where: { $0.0 == "howpublished" }) {
            add("howpublished", "arXiv:\(arxiv!)")
        }

        if let year = e.year { add("year", String(year)) }
        if let month = month(e.date) { add("month", month, raw: true) }
        let doi = e.doi.flatMap { $0.isEmpty ? nil : $0 }
        if let doi { add("doi", doi, raw: true) }
        if let url = e.url, !url.isEmpty, doi == nil || options.urlWithDOI {
            add("url", url, raw: true)
            // 웹 페이지는 본 날짜도 적는다(biblatex의 urldate).
            if type == "misc", arxiv == nil, let date = field("accessDate")?.prefix(10), date.count == 10 { add("urldate", String(date), raw: true) }
        }
        add("isbn", field("ISBN"))
        add("issn", field("ISSN"))
        add("abstract", e.abstract)
        let hidden = Set(options.hiddenTags.map { $0.lowercased() })
        let keywords = tags.map { String($0.drop { $0 == "/" }) }.filter { !$0.isEmpty && !hidden.contains($0.lowercased()) }
        add("keywords", keywords.isEmpty ? nil : keywords.joined(separator: ", "))

        // month는 BibTeX 약어(jan…dec)라 괄호 없이 쓴다.
        let body = out.map { $0.0 == "month" ? "  month = \($0.1)" : "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n")
        return "@\(type){\(key),\n\(body)\n}"
    }

    // MARK: 도움

    /// "Liu, Yang and Mao, Jie". 이름이 하나뿐인 저자(단체 등)는 {{…}}로 감싸 BibTeX이 성과 이름으로 나누지 않게 한다.
    static func names(_ people: [Creator]) -> String? {
        let list = Creator.people(people).map { c -> String in
            guard let given = c.given, !given.isEmpty else { return "{\(escape(c.family))}" }
            return "\(escape(c.family)), \(escape(given))"
        }
        return list.isEmpty ? nil : list.joined(separator: " and ")
    }

    /// "2020-07-25" → "jul". 달이 없으면 nil.
    static func month(_ date: String?) -> String? {
        guard let date, let r = date.range(of: #"^\d{4}-(\d{2})"#, options: .regularExpression),
              let m = Int(date[r].suffix(2)), (1...12).contains(m) else { return nil }
        return ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"][m - 1]
    }

    /// 쪽 범위 "299-319", "299–319" → "299--319".
    static func pages(_ text: String?) -> String? {
        text.map { escape($0).replacingOccurrences(of: #"\s*[-–—]+\s*"#, with: "--", options: .regularExpression) }
    }

    /// 제목에서 대문자를 지켜야 할 낱말(GPT-4, BERT, iPhone, LLMs)을 {}로 감싼다.
    /// 참고문헌 스타일이 제목을 소문자로 바꿔도 그 낱말은 그대로 남는다. 첫 글자만 대문자인 낱말은 두어서 스타일을 따르게 한다.
    static func protect(_ title: String) -> String {
        title.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            guard word.filter(\.isLetter).dropFirst().contains(where: \.isUppercase),
                  let first = word.firstIndex(where: { $0.isLetter || $0.isNumber }),
                  let last = word.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return escape(String(word)) }
            // 앞뒤 구두점은 괄호 밖에 둔다: "(BERT)," → "({BERT}),", "LightGCN:" → "{LightGCN}:".
            return escape(String(word[..<first])) + "{" + escape(String(word[first...last])) + "}"
                + escape(String(word[word.index(after: last)...]))
        }.joined(separator: " ")
    }

    /// LaTeX에서 뜻이 있는 글자를 글자 그대로 나오게 바꾼다. 한글·악센트 같은 유니코드는 그대로 둔다(biber, Overleaf가 읽는다).
    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "\\": out += "\\textbackslash{}"
            case "{", "}", "&", "%", "$", "#", "_": out += "\\\(ch)"
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            case "\n", "\r", "\t": out += " "
            default: out.append(ch)
            }
        }
        return out
    }
}
