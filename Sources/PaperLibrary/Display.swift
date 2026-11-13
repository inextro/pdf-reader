import Foundation
import PaperMarkLibrary

/// 표의 열. 보이는 열과 순서는 설정(Settings.columns)에 두고, 표 머리글을 끌거나 오른쪽 클릭해도, 설정 창에서도 고친다.
enum LibraryColumn: String, CaseIterable {
    case title, authors, year, venue, added, modified, type, citationKey, doi, publisher, pages, tags

    /// 처음 구성(Restore Default Columns).
    static let defaults: [LibraryColumn] = [.year, .title, .authors, .citationKey, .tags]

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
        case .pages: 100
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
        case .publisher: item.fields["publisher"] ?? ""
        case .pages: item.fields["pages"] ?? item.fields[ArticleNumber.key].map { "Art. \($0)" } ?? ""
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
    case type, authors, editors, venue, date, volumeIssuePages, publisher, citationKey, doi, url,
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
    case title, citationKey, authors, year, venue, publisher, doi, tags, abstract

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
        // arXiv 번호로도 찾는다. 프리프린트는 DOI(10.48550/arXiv.…)에, 출판본은 숨은 arXiv ID에 있다.
        case .doi: [item.doi, item.arxivID].compactMap { $0 }.joined(separator: " ")
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

/// 표에서 논문을 우클릭했을 때 보이는 항목. 보이는 항목과 순서는 설정(Settings.itemMenu)에 둔다.
/// 순서상 묶음(group)이 바뀌는 곳에 구분선을 넣는다.
enum ItemMenuAction: String, CaseIterable {
    case openPDF, showInFinder, openWeb, copyCitationKey, copyCitation, copyDOI, status, moveTo, addReference, removeFromCollection, regenerateCitationKey, delete

    static let defaults = allCases

    var title: String {
        switch self {
        case .openPDF: "Open PDF"
        case .showInFinder: "Show in Finder"
        case .openWeb: "Open DOI / URL"
        case .copyCitationKey: "Copy Citation Key"
        case .copyCitation: "Copy Citation"
        case .copyDOI: "Copy DOI"
        case .status: "Status ▸"
        case .moveTo: "Move to ▸"
        case .addReference: "Add Reference to ▸"
        case .removeFromCollection: "Remove from Collection"
        case .regenerateCitationKey: "Regenerate Citation Key"
        case .delete: "Delete…"
        }
    }

    var group: Int {
        switch self {
        case .openPDF, .showInFinder, .openWeb: 0
        case .copyCitationKey, .copyCitation, .copyDOI: 1
        case .status: 2
        case .moveTo, .addReference, .removeFromCollection: 3
        case .regenerateCitationKey: 4
        case .delete: 5
        }
    }
}

extension Settings {
    static var itemMenu: [ItemMenuAction] {
        get { UserDefaults.standard.stringArray(forKey: "itemMenu")?.compactMap(ItemMenuAction.init) ?? ItemMenuAction.defaults }
        set {
            guard newValue != itemMenu else { return }
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "itemMenu")
            NotificationCenter.default.post(name: displayDidChange, object: nil)
        }
    }

    /// Copy Citation(⌘⇧C)의 참고문헌 스타일.
    static var citationStyle: CitationStyle {
        get { UserDefaults.standard.string(forKey: "citationStyle").flatMap(CitationStyle.init) ?? .apa }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "citationStyle") }
    }

    /// 읽기 상태로 쓰는 태그(순서대로). 논문에는 이 가운데 하나만 붙인다(Status ▸). 첫 태그는 새로 넣은 논문에 붙인다.
    static let defaultStatusTags = ["/To Do", "/In Process", "/Verified", "/Completed"]
    static var statusTags: [String] {
        get { UserDefaults.standard.stringArray(forKey: "statusTags") ?? defaultStatusTags }
        set {
            guard newValue != statusTags else { return }
            UserDefaults.standard.set(newValue, forKey: "statusTags")
            NotificationCenter.default.post(name: displayDidChange, object: nil)
        }
    }

    /// 켜면 논문을 다른 컬렉션에 참조로도 넣을 수 있다(⌥ 끌기, Add Reference to). 끄면 논문은 한 컬렉션에만 속한다.
    static var allowReferences: Bool {
        get { UserDefaults.standard.object(forKey: "allowReferences") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "allowReferences")
            NotificationCenter.default.post(name: displayDidChange, object: nil)
        }
    }
}

/// 사이드바 컬렉션 순서. Custom은 사용자가 끌어 놓은 순서(같은 부모 안에서만)를 컬렉션 key로 기억한다.
enum CollectionSort: String, CaseIterable {
    case nameAscending, nameDescending, custom

    var title: String {
        switch self {
        case .nameAscending: "Name A → Z"
        case .nameDescending: "Name Z → A"
        case .custom: "Custom Order"
        }
    }
}

extension Settings {
    static var collectionSort: CollectionSort {
        get { UserDefaults.standard.string(forKey: "collectionSort").flatMap(CollectionSort.init) ?? .nameAscending }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "collectionSort") }
    }

    /// Custom 순서의 컬렉션 key들. 여기 없는 컬렉션(새로 만든 것)은 형제들 뒤에 이름순으로 붙는다.
    static var collectionOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "collectionOrder") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "collectionOrder") }
    }
}
