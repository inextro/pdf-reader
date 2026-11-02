import Foundation

/// 논문 한 편의 서지 정보. 웹 페이지 메타태그·CrossRef·arXiv에서 채워 라이브러리 항목으로 저장한다.
public struct PaperMetadata: Equatable {
    public var type = "webpage"
    public var title = ""
    public var creators: [Creator] = []
    /// "2024-07-10", "2024-07", "2024"
    public var date: String?
    public var venue: String?
    public var doi: String?
    public var arxivID: String?
    public var url: String?
    public var abstract: String?
    /// 열로 따로 두지 않는 필드. 이름은 Zotero 필드 이름(volume, issue, pages, publisher, ISSN …)을 따른다.
    public var fields: [String: String] = [:]
    /// 페이지가 알려 준 PDF 주소.
    public var pdfURL: String?

    public init() {}

    /// 라이브러리 항목에서 이름 짓기(citation key, 파일 이름)에 쓸 정보를 꺼낸다.
    public init(_ entry: LibraryEntry) {
        type = entry.type
        title = entry.title
        creators = entry.creators
        date = entry.date ?? entry.year.map(String.init)
        venue = entry.venue
        doi = entry.doi
        arxivID = entry.arxivID
        url = entry.url
        abstract = entry.abstract
        fields = entry.fields
    }

    public var year: Int? {
        guard let date, let r = date.range(of: #"(1[5-9]|20)\d{2}"#, options: .regularExpression) else { return nil }
        return Int(date[r])
    }

    /// 항목 종류에 맞는 Zotero의 venue 필드 이름.
    public var venueField: String {
        switch type {
        case "conferencePaper": return "proceedingsTitle"
        case "preprint": return "repository"
        case "webpage": return "websiteTitle"
        default: return "publicationTitle"
        }
    }

    /// 두 출처를 합친다. 둘 다 있는 값은 preferOther면 other, 아니면 self의 것을 쓴다.
    /// 종류와 venue는 함께 다닌다(한쪽의 종류에 다른 쪽의 venue를 붙이지 않는다). 주소와 PDF 주소는 저장한 페이지의 것을 둔다.
    public func merged(with other: PaperMetadata, preferOther: Bool) -> PaperMetadata {
        let (a, b) = preferOther ? (other, self) : (self, other)
        var m = PaperMetadata()
        m.title = a.title.isEmpty ? b.title : a.title
        m.creators = a.creators.isEmpty ? b.creators : a.creators
        m.date = a.date ?? b.date
        if a.venue != nil { (m.type, m.venue) = (a.type, a.venue) }
        else if b.venue != nil { (m.type, m.venue) = (b.type, b.venue) }
        else { m.type = a.type == "webpage" ? b.type : a.type }
        m.doi = a.doi ?? b.doi
        m.arxivID = a.arxivID ?? b.arxivID
        m.url = url ?? other.url
        m.abstract = a.abstract ?? b.abstract
        m.fields = b.fields.merging(a.fields) { _, preferred in preferred }
        m.pdfURL = pdfURL ?? other.pdfURL
        return m
    }
}

// MARK: - 웹 페이지 메타태그

extension PaperMetadata {
    /// 웹 페이지의 메타태그(Highwire `citation_*`, Dublin Core, PRISM, Open Graph)로 채운다.
    /// ACM DL, ScienceDirect, ACL Anthology, NeurIPS·OpenReview, arXiv 등 논문 페이지는 대부분 `citation_*`를 단다.
    public static func page(meta: [(String, String)], url: String?, title pageTitle: String?) -> PaperMetadata {
        var all: [String: [String]] = [:]
        for (name, value) in meta {
            let value = clean(value)
            if !value.isEmpty { all[name.lowercased(), default: []].append(value) }
        }
        func first(_ names: String...) -> String? { names.lazy.compactMap { all[$0]?.first }.first }

        var m = PaperMetadata()
        m.url = url
        m.title = first("citation_title", "dc.title", "og:title") ?? clean(pageTitle ?? "")
        let names = all["citation_author"] ?? all["dc.creator"]
            ?? all["citation_authors"]?.flatMap { $0.split(separator: ";").map(String.init) } ?? []
        m.creators = names.map(Creator.author)
        m.date = first("citation_publication_date", "citation_date", "citation_cover_date", "citation_online_date",
                       "dc.date", "prism.publicationdate").map(normalizedDate)
        m.doi = first("citation_doi", "prism.doi", "bepress_citation_doi").flatMap(PaperID.doi(in:))
            ?? all["dc.identifier"]?.lazy.compactMap(PaperID.doi(in:)).first
            ?? url.flatMap(PaperID.doi(in:))
        m.arxivID = first("citation_arxiv_id").flatMap { PaperID.arxiv(in: "arXiv:\($0)") } ?? url.flatMap(PaperID.arxiv(in:))

        if let journal = first("citation_journal_title", "prism.publicationname") {
            (m.type, m.venue) = (isConference(journal) ? "conferencePaper" : "journalArticle", journal)
        } else if let conference = first("citation_conference_title", "citation_conference") {
            (m.type, m.venue) = ("conferencePaper", conference)
        } else if let book = first("citation_inbook_title", "citation_book_title") {
            (m.type, m.venue) = ("other", book)
        } else if m.arxivID != nil {
            (m.type, m.venue) = ("preprint", "arXiv")
        } else if m.doi != nil || !m.creators.isEmpty {
            m.type = "journalArticle"
        } else {
            m.venue = first("og:site_name")
        }

        m.fields["volume"] = first("citation_volume", "prism.volume")
        m.fields["issue"] = first("citation_issue", "prism.number")
        if let firstPage = first("citation_firstpage", "prism.startingpage") {
            m.fields["pages"] = first("citation_lastpage", "prism.endingpage").map { "\(firstPage)-\($0)" } ?? firstPage
        }
        m.fields["publisher"] = first("citation_publisher", "dc.publisher")
        m.fields["ISSN"] = first("citation_issn", "prism.issn")
        m.fields["ISBN"] = first("citation_isbn")
        m.abstract = first("citation_abstract", "dc.description")
        m.pdfURL = first("citation_pdf_url")
        return m
    }

    /// NeurIPS처럼 학회 논문집이 journal 메타태그로 오는 경우를 가린다.
    static func isConference(_ venue: String) -> Bool {
        let v = venue.lowercased()
        return ["proceedings", "conference", "symposium", "workshop", "neural information processing systems"]
            .contains { v.contains($0) }
    }

    static func normalizedDate(_ date: String) -> String {
        let parts = date.split(whereSeparator: { $0 == "/" || $0 == "-" })
        guard let year = parts.first, year.count == 4, Int(year) != nil, parts.allSatisfy({ Int($0) != nil }) else { return date }
        return parts.prefix(3).enumerated().map { $0 == 0 ? String($1) : String(repeating: "0", count: max(0, 2 - $1.count)) + $1 }
            .joined(separator: "-")
    }

    /// 같은 제목인지 견줄 때 쓰는 꼴: 소문자 영숫자만.
    static func titleKey(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Creator {
    /// "He, Xiangnan" 또는 "Xiangnan He"를 성과 이름으로 나눈다.
    public static func author(_ name: String) -> Creator {
        let name = PaperMetadata.clean(name)
        if let comma = name.firstIndex(of: ",") {
            let given = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return Creator(role: "author", family: name[..<comma].trimmingCharacters(in: .whitespaces),
                           given: given.isEmpty ? nil : given)
        }
        guard let space = name.lastIndex(of: " ") else { return Creator(role: "author", family: name, given: nil) }
        return Creator(role: "author", family: String(name[name.index(after: space)...]), given: String(name[..<space]))
    }
}

// MARK: - CrossRef, arXiv

extension PaperMetadata {
    /// CrossRef `/works/{doi}` 응답.
    public static func crossref(_ data: Data) -> PaperMetadata? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let work = root["message"] as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            (work[key] as? String).map(clean).flatMap { $0.isEmpty ? nil : $0 }
        }
        func firstString(_ key: String) -> String? {
            (work[key] as? [String])?.lazy.map(clean).first { !$0.isEmpty }
        }
        func people(_ key: String, role: String) -> [Creator] {
            (work[key] as? [[String: Any]] ?? []).map { person in
                if let family = person["family"] as? String {
                    return Creator(role: role, family: clean(family), given: (person["given"] as? String).map(clean))
                }
                return Creator(role: role, family: clean(person["name"] as? String ?? ""), given: nil)
            }
        }

        var m = PaperMetadata()
        m.title = firstString("title") ?? ""
        if let subtitle = firstString("subtitle"), !m.title.isEmpty, !m.title.contains(subtitle) {
            m.title += ": " + subtitle
        }
        m.creators = people("author", role: "author") + people("editor", role: "editor")
        for key in ["issued", "published-print", "published-online", "published"] {
            if let parts = ((work[key] as? [String: Any])?["date-parts"] as? [[Any]])?.first?.compactMap({ $0 as? Int }),
               let year = parts.first {
                m.date = ([String(year)] + parts.dropFirst().prefix(2).map { String(format: "%02d", $0) }).joined(separator: "-")
                break
            }
        }
        m.doi = string("DOI")
        m.type = switch string("type") {
        case "journal-article": "journalArticle"
        case "proceedings-article": "conferencePaper"
        case "posted-content": "preprint"
        case "book", "monograph", "edited-book": "book"
        default: "other"
        }
        m.venue = firstString("container-title")
        if m.type == "journalArticle", let venue = m.venue, isConference(venue) { m.type = "conferencePaper" }
        m.fields["volume"] = string("volume")
        m.fields["issue"] = string("issue")
        m.fields["pages"] = string("page")
        m.fields["publisher"] = string("publisher")
        m.fields["place"] = string("publisher-location")
        m.fields["ISSN"] = (work["ISSN"] as? [String]).map { $0.joined(separator: ", ") }
        m.fields["ISBN"] = firstString("ISBN")
        if m.type == "conferencePaper" {
            m.fields["conferenceName"] = ((work["event"] as? [String: Any])?["name"] as? String).map(clean)
        }
        m.abstract = string("abstract").map(stripMarkup)
        return m
    }

    /// CrossRef 초록의 JATS 태그(`<jats:p>`)를 떼고 앞의 "Abstract" 머리말을 뺀다.
    static func stripMarkup(_ text: String) -> String {
        let plain = clean(text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
        return plain.replacingOccurrences(of: #"^Abstract\s*[:.]?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// arXiv API(`export.arxiv.org/api/query`)의 Atom 응답. publishedDOI는 저자가 arXiv에 적어 둔 출판본 DOI.
    public static func arxiv(_ data: Data) -> (metadata: PaperMetadata, publishedDOI: String?)? {
        let reader = ArxivAtomReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        guard let entry = reader.entry, let id = entry["id"].flatMap(PaperID.arxiv(in:)), let title = entry["title"] else {
            return nil
        }
        var m = PaperMetadata()
        m.type = "preprint"
        m.venue = "arXiv"
        m.title = clean(title)
        m.creators = reader.authors.map(Creator.author)
        m.date = entry["published"].map { String($0.prefix(10)) }
        m.arxivID = id
        m.doi = "10.48550/arXiv.\(id)"
        m.url = "https://arxiv.org/abs/\(id)"
        m.abstract = entry["summary"].map(clean)
        m.fields["archiveID"] = "arXiv:\(id)"
        return (m, entry["arxiv:doi"].map(clean))
    }
}

/// arXiv Atom 응답의 첫 entry만 읽는다.
private final class ArxivAtomReader: NSObject, XMLParserDelegate {
    var entry: [String: String]?
    var authors: [String] = []
    private var current: [String: String]?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "entry" { current = [:] }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard current != nil else { return }
        switch name {
        case "entry":
            entry = current
            parser.abortParsing()
        case "name":
            authors.append(text)
        default:
            if current?[name] == nil { current?[name] = text }
        }
        text = ""
    }
}

// MARK: - 제목

extension PaperMetadata {
    /// "LightGCN: Simplifying and Powering Graph Convolution" → "LightGCN: Simplifying and powering graph convolution".
    /// 첫 낱말과 콜론·물음표 뒤 첫 낱말은 그대로, 대문자가 둘 이상이거나 숫자가 섞인 낱말(LightGCN, BERT, 3D)도 그대로 둔다.
    /// 제목 전체가 대문자이면 첫 글자만 남기고 모두 소문자로 바꾼다.
    public static func sentenceCase(_ title: String) -> String {
        let words = title.split(separator: " ").map(String.init)
        let lettered = words.filter { $0.contains(where: \.isLetter) }
        let shouting = lettered.count >= 3 && lettered.filter { $0 == $0.uppercased() }.count * 10 >= lettered.count * 6
        var startsSentence = true
        let result = words.map { word -> String in
            // 하이픈·대시·빗금으로 이은 낱말은 조각마다 판단한다("Score-Based" → "Score-based").
            var parts = [""], separators: [Character] = []
            for ch in word {
                if "-–—/".contains(ch) { separators.append(ch); parts.append("") } else { parts[parts.count - 1].append(ch) }
            }
            let cased = parts.enumerated().map { i, part in
                caseWord(part, keep: startsSentence && i == 0, shouting: shouting, joined: parts.count > 1)
            }
            if word.contains(where: \.isLetter) { startsSentence = ":?!.".contains(word.last!) }
            return zip(cased, separators.map(String.init) + [""]).map { $0 + $1 }.joined()
        }
        return result.joined(separator: " ")
    }

    private static func caseWord(_ part: String, keep: Bool, shouting: Bool, joined: Bool) -> String {
        guard let first = part.first(where: \.isLetter) else { return part }
        if shouting {
            return keep ? part.prefix(while: { $0 != first }) + String(first) + part.drop(while: { $0 != first }).dropFirst().lowercased()
                        : part.lowercased()
        }
        if keep || part.contains(where: \.isNumber) { return part }
        let uppers = part.filter(\.isUppercase).count
        if uppers >= 2 || (uppers == 1 && !first.isUppercase) { return part }
        if joined && part.count == 1 { return part }   // "Q-Learning"의 Q
        return part.lowercased()
    }
}

// MARK: - DOI, arXiv 번호, PDF 주소

public enum PaperID {
    /// URL, "doi:" 접두어, 문장 속에서 DOI("10.1145/3626772.3657738")를 찾는다.
    public static func doi(in text: String) -> String? {
        let text = text.removingPercentEncoding ?? text
        guard let r = text.range(of: #"10\.\d{4,9}/[^\s"'<>?#]+"#, options: .regularExpression) else { return nil }
        var doi = String(text[r])
        while let last = doi.last, ".,;)]}".contains(last) { doi.removeLast() }
        return doi
    }

    /// arxiv.org 주소, "arXiv:2310.20453", arXiv DOI("10.48550/arXiv.2310.20453")에서 번호를 찾는다. 버전(v2)은 뗀다.
    public static func arxiv(in text: String) -> String? {
        let id = #"(\d{4}\.\d{4,5}|[a-z\-]+(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?"#
        for pattern in [#"arxiv\.org/(?:abs|pdf|html)/"# + id, #"(?i:arxiv)[:.]\s*"# + id] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(match.range(at: 1), in: text) else { continue }
            return String(text[r])
        }
        return nil
    }

    /// 마술 지팡이 입력창의 글에서 DOI·arXiv 번호를 모두 찾는다(공백·쉼표·줄바꿈으로 나눈 것마다 하나).
    /// 주소("https://doi.org/…", "arxiv.org/abs/…"), "arXiv:…", 접두어 없는 arXiv 번호("2002.02126")를 받는다.
    public static func identifiers(in text: String) -> [PaperMetadata] {
        var seen: Set<String> = []
        return text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }).compactMap { token in
            let token = String(token)
            var m = PaperMetadata()
            if let doi = doi(in: token), !doi.lowercased().hasPrefix("10.48550/") {
                m.doi = doi
            } else if let id = arxiv(in: token)
                        ?? (token.range(of: #"^\d{4}\.\d{4,5}(v\d+)?$"#, options: .regularExpression) != nil
                            ? token.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression) : nil) {
                m.arxivID = id
            } else {
                return nil
            }
            return seen.insert((m.doi ?? m.arxivID ?? "").lowercased()).inserted ? m : nil
        }
    }

    /// PDF를 받아 볼 주소들(앞의 것부터 시도한다). 페이지가 알려 준 주소, 사이트별 규칙, 페이지 안의 PDF 링크 순.
    public static func pdfCandidates(for m: PaperMetadata, pageURL: String, isPDF: Bool, links: [String]) -> [String] {
        var urls: [String] = []
        if isPDF { urls.append(pageURL) }
        if let pdf = m.pdfURL { urls.append(pdf) }
        let page = URLComponents(string: pageURL)
        let host = page?.host ?? ""
        if let id = m.arxivID, m.venue == "arXiv" || host.hasSuffix("arxiv.org") { urls.append("https://arxiv.org/pdf/\(id)") }
        if host.hasSuffix("dl.acm.org"), let doi = m.doi { urls.append("https://dl.acm.org/doi/pdf/\(doi)") }
        if host.hasSuffix("openreview.net"), let id = page?.queryItems?.first(where: { $0.name == "id" })?.value {
            urls.append("https://openreview.net/pdf?id=\(id)")
        }
        urls += links
        var seen: Set<String> = []
        return urls.filter { seen.insert($0).inserted }
    }
}
