import Foundation

/// 참고문헌 문장 스타일. 표에서 Copy Citation(⌘⇧C)으로 복사할 때 쓴다.
public enum CitationStyle: String, CaseIterable {
    case apa, acm, ieee

    public var title: String {
        switch self {
        case .apa: "APA 7th"
        case .acm: "ACM"
        case .ieee: "IEEE"
        }
    }
}

/// 항목 하나를 참고문헌 문장으로 만든다. 기울여 쓸 곳(학술지·논문집 이름 등)은 italic 조각으로 나눠 돌려준다.
public enum Citation {
    public struct Piece: Equatable {
        public var text: String
        public var italic: Bool
    }

    public static func plain(_ e: LibraryEntry, style: CitationStyle) -> String {
        pieces(e, style: style).map(\.text).joined()
    }

    /// 여러 항목: APA·ACM은 첫 저자 성과 연도 순, IEEE는 고른 순서에 [1], [2]… 번호를 붙인다.
    public static func list(_ entries: [LibraryEntry], style: CitationStyle) -> [[Piece]] {
        switch style {
        case .ieee:
            return entries.enumerated().map { [Piece(text: "[\($0.offset + 1)] ", italic: false)] + pieces($0.element, style: style) }
        case .apa, .acm:
            let sorted = entries.sorted {
                let a = (people($0).first?.family ?? $0.title).lowercased(), b = (people($1).first?.family ?? $1.title).lowercased()
                return a != b ? a < b : ($0.year ?? 0) < ($1.year ?? 0)
            }
            return sorted.map { pieces($0, style: style) }
        }
    }

    public static func pieces(_ e: LibraryEntry, style: CitationStyle) -> [Piece] {
        var out: [Piece] = []
        func add(_ text: String, italic: Bool = false) { if !text.isEmpty { out.append(Piece(text: text, italic: italic)) } }
        let s = Source(e)
        switch style {
        case .apa:
            add(apaAuthors(people(e)).map { $0 + " " } ?? "")
            add("(\(e.year.map(String.init) ?? "n.d.")). ")
            switch s.kind {
            case .journal:
                add(period(e.title) + " ")
                if let journal = s.container {
                    add(journal, italic: true)
                    if let volume = s.volume { add(", "); add(volume, italic: true) }
                    if let issue = s.issue { add("(\(issue))") }
                    // APA 7: 논문 번호가 있으면 쪽 대신 "Article 103403".
                    if let number = s.article { add(", Article \(number)") } else if let pages = s.pages { add(", \(pages)") }
                    add(". ")
                }
            case .proceedings:
                add(period(e.title) + " ")
                if let proceedings = s.container {
                    add("In ")
                    add(proceedings, italic: true)
                    add(s.pages.map { " (pp. \($0)). " } ?? ". ")
                }
                if let publisher = s.publisher { add(period(publisher) + " ") }
            case .preprint:
                add(e.title, italic: true)
                add(s.arxiv.map { " (arXiv:\($0)). arXiv. " } ?? ". ")
                if let repository = s.container, s.arxiv == nil { add(period(repository) + " ") }
            case .book:
                add(period(e.title), italic: true)
                add(" ")
                if let publisher = s.publisher { add(period(publisher) + " ") }
            case .other:
                add(period(e.title), italic: true)
                add(" ")
                if let site = s.container { add(period(site) + " ") }
            }
            add(s.link ?? "")
        case .acm:
            add(acmAuthors(people(e)).map { period($0) + " " } ?? "")
            add("\(e.year.map(String.init) ?? "n.d."). ")
            switch s.kind {
            case .journal:
                add(period(e.title) + " ")
                if let journal = s.container {
                    add(journal, italic: true)
                    let numbers = [s.volume, s.issue].compactMap { $0 }.joined(separator: ", ")
                    add((numbers.isEmpty ? "" : " " + numbers) + (e.year.map { " (\($0))" } ?? ""))
                    // ACM: "…, Article 12, 25 pages."
                    if let number = s.article {
                        add(", Article \(number)" + (ArticleNumber.pageCount(s.pages).map { ", \($0) pages" } ?? "") + ". ")
                    } else {
                        add(s.pages.map { ", \($0). " } ?? ". ")
                    }
                }
            case .proceedings:
                add(period(e.title) + " ")
                if let proceedings = s.container {
                    add("In ")
                    add(proceedings, italic: true)
                    add(s.series.map { " (\($0))" } ?? "")
                    add(s.pages.map { ", \($0). " } ?? ". ")
                }
                if let publisher = s.publisher { add(period(publisher) + " ") }
            case .preprint:
                add(period(e.title) + " ")
                add(s.arxiv.map { "arXiv:\($0). " } ?? (s.container.map { period($0) + " " } ?? ""))
            case .book:
                add(period(e.title), italic: true)
                add(" ")
                if let publisher = s.publisher { add(period(publisher) + " ") }
            case .other:
                add(period(e.title) + " ")
                if let site = s.container { add(period(site) + " ") }
            }
            add(s.link ?? "")
        case .ieee:
            add(ieeeAuthors(people(e)).map { $0 + ", " } ?? "")
            let year = e.year.map(String.init) ?? "n.d."
            var tail: [String] = []
            switch s.kind {
            case .journal:
                add("“\(e.title),” ")
                if let journal = s.container { add(journal, italic: true); add(", ") }
                tail = [s.volume.map { "vol. \($0)" }, s.issue.map { "no. \($0)" },
                        s.article.map { "Art. no. \($0)" } ?? s.pages.map { "pp. \($0)" }, year].compactMap { $0 }
            case .proceedings:
                add("“\(e.title),” ")
                if let proceedings = s.container { add("in "); add(proceedings, italic: true); add(", ") }
                tail = [year, s.pages.map { "pp. \($0)" }].compactMap { $0 }
            case .preprint:
                add("“\(e.title),” ")
                tail = [year, s.arxiv.map { "arXiv:\($0)" } ?? s.container].compactMap { $0 }
            case .book:
                add(e.title, italic: true)
                add(". ")
                tail = [s.publisher, year].compactMap { $0 }
            case .other:
                add("“\(e.title),” ")
                tail = [s.container, year].compactMap { $0 }
            }
            if let doi = e.doi, !doi.isEmpty { tail.append("doi: \(doi)") }
            add(tail.joined(separator: ", ") + ".")
        }
        // 링크가 없으면 끝에 남는 빈칸을 뺀다.
        while let last = out.last, last.text.last == " " {
            out[out.count - 1].text = String(last.text.dropLast())
            if out[out.count - 1].text.isEmpty { out.removeLast() }
        }
        return out
    }

    // MARK: 도움

    private enum Kind { case journal, proceedings, preprint, book, other }

    private struct Source {
        var kind: Kind
        var container, volume, issue, pages, article, publisher, series, arxiv, link: String?

        init(_ e: LibraryEntry) {
            func field(_ names: String...) -> String? {
                names.lazy.compactMap { e.fields[$0]?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            }
            switch e.type {
            case "journalArticle": kind = .journal
            case "conferencePaper": kind = .proceedings
            case "preprint": kind = .preprint
            case "book": kind = .book
            default: kind = .other
            }
            container = field("publicationTitle", "proceedingsTitle", "conferenceName", "repository", "websiteTitle") ?? e.venue
            volume = field("volume")
            issue = field("issue")
            pages = field("pages").map { $0.replacingOccurrences(of: "-", with: "–") }
            article = kind == .journal ? field(ArticleNumber.key) : nil
            // 프리프린트의 arXiv 번호. DOI가 arXiv DOI면 거기서 읽는다(DOI를 고쳤는데 숨은 arXiv ID가 옛 값이어도 맞게).
            if kind == .preprint {
                let fromDOI = e.doi.flatMap { $0.lowercased().hasPrefix("10.48550/") ? PaperID.arxiv(in: $0) : nil }
                arxiv = fromDOI ?? e.arxivID
            }
            publisher = field("publisher")
            series = field("series")
            // 출판본은 그 버전의 DOI, 없으면 주소(ICLR은 OpenReview). 숨은 arXiv ID는 프리프린트에만 쓴다.
            if let doi = e.doi, !doi.isEmpty {
                link = "https://doi.org/\(doi)"
            } else if let arxiv {
                link = "https://doi.org/10.48550/arXiv.\(arxiv)"
            } else {
                link = e.url
            }
        }
    }

    private static func people(_ e: LibraryEntry) -> [Creator] { e.authors.isEmpty ? e.creators : e.authors }

    /// "Jean-Paul Marie" → "J.-P. M."
    private static func initials(_ given: String?) -> String {
        (given ?? "").split(separator: " ").map { word in
            word.split(separator: "-").compactMap { $0.first.map { "\($0)." } }.joined(separator: "-")
        }.joined(separator: " ")
    }

    private static func inverted(_ c: Creator) -> String {
        let i = initials(c.given)
        return i.isEmpty ? c.family : "\(c.family), \(i)"
    }

    private static func full(_ c: Creator) -> String { [c.given, c.family].compactMap { $0 }.joined(separator: " ") }

    /// APA 7: 20명까지 모두, 넘으면 19명, …, 마지막 저자.
    private static func apaAuthors(_ people: [Creator]) -> String? {
        let names = people.map(inverted)
        switch names.count {
        case 0: return nil
        case 1: return period(names[0])
        case 2...20: return period(names.dropLast().joined(separator: ", ") + ", & " + names.last!)
        default: return period(names.prefix(19).joined(separator: ", ") + ", … " + names.last!)
        }
    }

    private static func acmAuthors(_ people: [Creator]) -> String? {
        let names = people.map(full)
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
    }

    /// IEEE: 6명까지 모두, 넘으면 첫 저자 et al.
    private static func ieeeAuthors(_ people: [Creator]) -> String? {
        let names = people.map { c in [initials(c.given), c.family].filter { !$0.isEmpty }.joined(separator: " ") }
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3...6: return names.dropLast().joined(separator: ", ") + ", and " + names.last!
        default: return names[0] + " et al."
        }
    }

    /// 끝에 마침표를 붙인다. 이미 . ? ! 로 끝나면 그대로.
    private static func period(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return t }
        return ".?!".contains(last) ? t : t + "."
    }
}
