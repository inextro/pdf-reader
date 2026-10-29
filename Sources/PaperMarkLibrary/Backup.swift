import Foundation

/// 라이브러리 전체를 JSON 하나로 내보낸다(Drive의 라이브러리 폴더에 두는 백업).
/// 다른 기기의 DB에서도 그대로 읽히도록 내부 id 대신 key로 서로를 가리킨다.
public enum LibraryBackup {
    public static let fileName = "PaperLibrary.json"

    public struct File: Codable, Equatable {
        public var version = 1
        public var exportedAt: String
        public var items: [Item]
        public var collections: [Collection]
        public var deleted: [Deleted]
    }

    public struct Item: Codable, Equatable {
        public var key, type, title: String
        public var date: String?
        public var venue, doi, arxivID, url, abstract, citationKey: String?
        public var fields: [String: String]
        public var addedAt, modifiedAt: String
        public var creators: [Creator]
        public var attachments: [String]
        public var collections: [String]
        public var tags: [String]
        public var notes: [String]
    }

    public struct Collection: Codable, Equatable {
        public var key: String
        public var parent: String?
        public var name: String
    }

    public struct Deleted: Codable, Equatable {
        public var key, deletedAt: String
    }

    public static func make(from library: Library) throws -> File {
        let collections = try library.collections()
        let keyOf = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.key) })
        let items = try library.items().sorted { $0.key < $1.key }.map { item in
            Item(key: item.key, type: item.type, title: item.title, date: item.date, venue: item.venue, doi: item.doi,
                 arxivID: item.arxivID, url: item.url, abstract: item.abstract, citationKey: item.citationKey,
                 fields: item.fields, addedAt: item.addedAt, modifiedAt: item.modifiedAt, creators: item.creators,
                 attachments: item.attachments, collections: item.collectionIDs.compactMap { keyOf[$0] }.sorted(),
                 tags: item.tags, notes: try library.notes(of: item.id))
        }
        let deleted = try library.db.query("SELECT key, deleted_at FROM deleted_items ORDER BY key").map {
            Deleted(key: $0["key"] ?? "", deletedAt: $0["deleted_at"] ?? "")
        }
        return File(exportedAt: Library.now(), items: items,
                    collections: collections.sorted { $0.key < $1.key }
                        .map { Collection(key: $0.key, parent: $0.parentID.flatMap { keyOf[$0] }, name: $0.name) },
                    deleted: deleted)
    }

    /// folder에 백업 파일을 쓴다. 중간에 끊겨도 이전 백업이 남도록 통째로 바꿔 쓴다.
    @discardableResult
    public static func write(_ library: Library, to folder: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = folder.appendingPathComponent(fileName)
        try encoder.encode(make(from: library)).write(to: url, options: .atomic)
        return url
    }
}
