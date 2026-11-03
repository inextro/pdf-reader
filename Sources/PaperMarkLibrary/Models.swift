import Foundation

public struct Creator: Codable, Equatable {
    public var role: String          // author | editor
    public var family: String
    public var given: String?

    public init(role: String, family: String, given: String?) {
        self.role = role
        self.family = family
        self.given = given
    }
}

/// 서지 항목 하나와 거기 딸린 저자·PDF·컬렉션·태그.
public struct LibraryEntry: Equatable {
    public var id: Int64
    public var key: String
    public var type: String
    public var title: String
    public var date: String?
    public var year: Int?
    public var venue: String?
    public var doi: String?
    public var arxivID: String?
    public var url: String?
    public var abstract: String?
    public var citationKey: String?
    public var fields: [String: String]
    public var addedAt: String
    public var modifiedAt: String
    public var creators: [Creator] = []
    /// 라이브러리 폴더 기준 상대 경로(또는 폴더 밖이면 절대 경로).
    public var attachments: [String] = []
    public var collectionIDs: Set<Int64> = []
    public var tags: [String] = []
    public var noteCount = 0

    public var authors: [Creator] { creators.filter { $0.role == "author" } }

    /// 표에 보일 저자: "Liu", "Liu & Mao", "Liu et al.". 저자가 없으면 편집자.
    public var authorSummary: String {
        let people = authors.isEmpty ? creators : authors
        switch people.count {
        case 0: return ""
        case 1: return people[0].family
        case 2: return "\(people[0].family) & \(people[1].family)"
        default: return "\(people[0].family) et al."
        }
    }

    /// 검색어의 낱말이 모두 제목·저자·venue·citation key·DOI 중 어딘가에 있으면 맞는다.
    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = ([title, venue ?? "", citationKey ?? "", doi ?? "", arxivID ?? ""]
                        + creators.flatMap { [$0.family, $0.given ?? ""] }).joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public struct LibraryCollection: Equatable {
    public var id: Int64
    public var key: String
    public var parentID: Int64?
    public var name: String
}

/// 사이드바에서 고르는 범위.
public enum LibraryFilter: Equatable {
    case all
    case unfiled
    case collection(Int64)
    case tag(String)

    public func includes(_ item: LibraryEntry) -> Bool {
        switch self {
        case .all: return true
        case .unfiled: return item.collectionIDs.isEmpty
        case .collection(let id): return item.collectionIDs.contains(id)
        case .tag(let name): return item.tags.contains(name)
        }
    }
}
