import Foundation
import PaperMarkLibrary

/// 표의 열. 보이는 열과 순서는 설정(Settings.columns)에 두고, 표 머리글을 끌거나 오른쪽 클릭해도, 설정 창에서도 고친다.
enum LibraryColumn: String, CaseIterable {
    case title, authors, year, venue, added, modified, type, citationKey, doi, arxiv, publisher, pages, tags

    /// 처음 구성(Restore Default Columns).
    static let defaults: [LibraryColumn] = [.title, .authors, .year, .venue, .added]

    var title: String {
        switch self {
        case .title: "Title"
        case .authors: "Authors"
        case .year: "Year"
        case .venue: "Venue"
        case .added: "Added"
        case .modified: "Modified"
        case .type: "Item Type"
        case .citationKey: "Citation Key"
        case .doi: "DOI"
        case .arxiv: "arXiv"
        case .publisher: "Publisher"
        case .pages: "Pages"
        case .tags: "Tags"
        }
    }

    var width: CGFloat {
        switch self {
        case .title: 360
        case .authors: 140
        case .year: 56
        case .venue, .publisher: 180
        case .added, .modified: 100
        case .type: 130
        case .citationKey, .doi, .tags: 160
        case .arxiv, .pages: 100
        }
    }

    var minWidth: CGFloat { 40 }

    func text(_ item: LibraryEntry) -> String {
        switch self {
        case .title: item.title
        case .authors: item.authorSummary
        case .year: item.year.map(String.init) ?? ""
        case .venue: item.venue ?? ""
        case .added: String(item.addedAt.prefix(10))
        case .modified: String(item.modifiedAt.prefix(10))
        case .type: itemTypeName(item.type)
        case .citationKey: item.citationKey ?? ""
        case .doi: item.doi ?? ""
        case .arxiv: item.arxivID ?? ""
        case .publisher: item.fields["publisher"] ?? ""
        case .pages: item.fields["pages"] ?? ""
        case .tags: item.tags.map(TagColor.displayName).joined(separator: ", ")
        }
    }

    func sortValue(_ item: LibraryEntry) -> String {
        switch self {
        case .year: item.year.map { String(format: "%04d", $0) } ?? ""
        case .added: item.addedAt
        case .modified: item.modifiedAt
        default: text(item)
        }
    }
}

/// 오른쪽 정보 패널에 보이는 칸. 제목은 늘 보인다. 보이는 칸과 순서는 설정(Settings.infoFields)에 둔다.
enum InfoField: String, CaseIterable {
    case type, authors, editors, venue, date, volumeIssuePages, publisher, citationKey, doi, arxiv, url,
         collections, tags, pdf, added, modified, abstract, notes

    static let defaults = allCases

    var title: String {
        switch self {
        case .type: "Item Type"
        case .authors: "Authors"
        case .editors: "Editors"
        case .venue: "Venue"
        case .date: "Date"
        case .volumeIssuePages: "Volume · Issue · Pages"
        case .publisher: "Publisher"
        case .citationKey: "Citation Key"
        case .doi: "DOI"
        case .arxiv: "arXiv"
        case .url: "URL"
        case .collections: "Collections"
        case .tags: "Tags"
        case .pdf: "PDF"
        case .added: "Added"
        case .modified: "Modified"
        case .abstract: "Abstract"
        case .notes: "Notes"
        }
    }
}

func itemTypeName(_ type: String) -> String {
    ["journalArticle": "Journal Article", "conferencePaper": "Conference Paper", "preprint": "Preprint",
     "book": "Book", "webpage": "Web Page"][type] ?? "Other"
}

extension Settings {
    static let displayDidChange = Notification.Name("SettingsDisplayDidChange")

    /// 표에 보이는 열(순서대로). Title은 늘 있다.
    static var columns: [LibraryColumn] {
        get {
            let saved = UserDefaults.standard.stringArray(forKey: "libraryColumns")?.compactMap(LibraryColumn.init) ?? LibraryColumn.defaults
            return saved.contains(.title) ? saved : [.title] + saved
        }
        set {
            guard newValue != columns else { return }
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "libraryColumns")
            NotificationCenter.default.post(name: displayDidChange, object: nil)
        }
    }

    /// 정보 패널에 보이는 칸(순서대로).
    static var infoFields: [InfoField] {
        get { UserDefaults.standard.stringArray(forKey: "infoFields")?.compactMap(InfoField.init) ?? InfoField.defaults }
        set {
            guard newValue != infoFields else { return }
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "infoFields")
            NotificationCenter.default.post(name: displayDidChange, object: nil)
        }
    }
}

/// 툴바 검색이 찾는 칸. 기본은 제목과 citation key.
enum SearchField: String, CaseIterable {
    case title, citationKey, authors, year, venue, publisher, doi, arxiv, tags, abstract

    static let defaults: [SearchField] = [.title, .citationKey]

    var title: String {
        switch self {
        case .title: "Title"
        case .citationKey: "Citation Key"
        case .authors: "Authors"
        case .year: "Year"
        case .venue: "Venue"
        case .publisher: "Publisher"
        case .doi: "DOI"
        case .arxiv: "arXiv ID"
        case .tags: "Tags"
        case .abstract: "Abstract"
        }
    }

    func text(_ item: LibraryEntry) -> String {
        switch self {
        case .title: item.title
        case .citationKey: item.citationKey ?? ""
        case .authors: item.creators.flatMap { [$0.family, $0.given ?? ""] }.joined(separator: " ")
        case .year: item.year.map(String.init) ?? ""
        case .venue: item.venue ?? ""
        case .publisher: item.fields["publisher"] ?? ""
        case .doi: item.doi ?? ""
        case .arxiv: item.arxivID ?? ""
        case .tags: item.tags.map(TagColor.displayName).joined(separator: " ")
        case .abstract: item.abstract ?? ""
        }
    }

    /// 검색어의 낱말이 모두 고른 칸들 중 어딘가에 있으면 맞는다(대소문자·악센트 무시, 낱말 일부도 맞음).
    static func matches(_ item: LibraryEntry, _ query: String, in fields: [SearchField]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = fields.map { $0.text(item) }.joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

extension Settings {
    static let searchDidChange = Notification.Name("SettingsSearchDidChange")

    /// 검색이 찾는 칸.
    static var searchFields: [SearchField] {
        get {
            let saved = UserDefaults.standard.stringArray(forKey: "searchFields")?.compactMap(SearchField.init) ?? SearchField.defaults
            return saved.isEmpty ? SearchField.defaults : saved
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "searchFields")
            NotificationCenter.default.post(name: searchDidChange, object: nil)
        }
    }

    /// 켜면 사이드바에서 고른 컬렉션·태그 안에서만 찾는다. 기본은 꺼져 있어 늘 전체에서 찾는다.
    static var searchWithinSelection: Bool {
        get { UserDefaults.standard.bool(forKey: "searchWithinSelection") }
        set {
            UserDefaults.standard.set(newValue, forKey: "searchWithinSelection")
            NotificationCenter.default.post(name: searchDidChange, object: nil)
        }
    }
}
