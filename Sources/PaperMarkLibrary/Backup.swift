import Foundation

/// 라이브러리 전체를 JSON 하나로 내보낸다(Drive의 workspace 안 `.Quillo` 폴더에 두는 백업과 날짜별 사본).
/// 다른 기기의 DB에서도 그대로 읽히도록 내부 id 대신 key로 서로를 가리킨다.
public enum LibraryBackup {
    public static let fileName = "Quillo.json"
    /// 앱 이름이 PaperLibrary였을 때의 백업 파일. 남아 있으면 새 이름으로 옮겨 쓴다.
    public static let oldFileName = "PaperLibrary.json"

    public struct File: Codable, Equatable {
        public var version = 1
        public var exportedAt: String
        public var items: [Item]
        public var collections: [Collection]
        public var deleted: [Deleted]
        /// 모든 태그 이름(붙은 논문이 없는 태그도). 1.0.10부터 적는다.
        public var tags: [String]?
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
        /// 1.0.10부터 적는다. 없으면 되살릴 때 date에서 읽는다.
        public var year: Int?
        /// Zotero에서 가져온 항목의 Zotero key. 되살린 뒤 Zotero에서 다시 가져와도 겹치지 않게 남긴다.
        public var zoteroKey: String?
    }

    public struct Collection: Codable, Equatable {
        public var key: String
        public var parent: String?
        public var name: String
        public var zoteroKey: String?
    }

    public struct Deleted: Codable, Equatable {
        public var key, deletedAt: String
    }

    public static func make(from library: Library) throws -> File {
        let collections = try library.collections()
        let keyOf = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.key) })
        var zoteroKeyOf: [String: String] = [:]
        for table in ["items", "collections"] {
            for row in try library.db.query("SELECT key, zotero_key FROM \(table) WHERE zotero_key IS NOT NULL") {
                if let key = row["key"], let z = row["zotero_key"] { zoteroKeyOf[key] = z }
            }
        }
        let items = try library.items().sorted { $0.key < $1.key }.map { item in
            Item(key: item.key, type: item.type, title: item.title, date: item.date, venue: item.venue, doi: item.doi,
                 arxivID: item.arxivID, url: item.url, abstract: item.abstract, citationKey: item.citationKey,
                 fields: item.fields, addedAt: item.addedAt, modifiedAt: item.modifiedAt, creators: item.creators,
                 attachments: item.attachments, collections: item.collectionIDs.compactMap { keyOf[$0] }.sorted(),
                 tags: item.tags, notes: try library.notes(of: item.id), year: item.year, zoteroKey: zoteroKeyOf[item.key])
        }
        let deleted = try library.db.query("SELECT key, deleted_at FROM deleted_items ORDER BY key").map {
            Deleted(key: $0["key"] ?? "", deletedAt: $0["deleted_at"] ?? "")
        }
        return File(exportedAt: Library.now(), items: items,
                    collections: collections.sorted { $0.key < $1.key }
                        .map { Collection(key: $0.key, parent: $0.parentID.flatMap { keyOf[$0] }, name: $0.name,
                                          zoteroKey: zoteroKeyOf[$0.key]) },
                    deleted: deleted, tags: try library.tags())
    }

    /// 백업을 두는 workspace 안의 숨김 폴더. 숨김 폴더라 컬렉션으로 보지 않는다(Drive에는 올라간다).
    public static let folderName = ".Quillo"
    /// 날짜별 사본을 몇 개 남길지(바꾼 날 기준).
    public static let dailyCopies = 30

    public static func backupFolder(in workspace: URL) -> URL { workspace.appendingPathComponent(folderName, isDirectory: true) }

    /// 지금 백업 파일: `<workspace>/.Quillo/Quillo.json`.
    public static func currentURL(in workspace: URL) -> URL { backupFolder(in: workspace).appendingPathComponent(fileName) }

    /// 날짜별 사본 이름: `Quillo-2026-11-19.json`(이 Mac의 날짜).
    public static func dailyName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "Quillo-\(f.string(from: date)).json"
    }

    /// 1.0.9까지 workspace 바로 아래에 쓰던 백업을 숨김 폴더로 옮긴다. 새 자리에 이미 있으면 옛 파일은 그대로 둔다.
    private static func moveOldBackup(in workspace: URL) {
        let files = FileManager.default
        let current = currentURL(in: workspace)
        guard !files.fileExists(atPath: current.path) else { return }
        for name in [fileName, oldFileName] {
            let old = workspace.appendingPathComponent(name)
            if files.fileExists(atPath: old.path) { try? files.moveItem(at: old, to: current); return }
        }
    }

    /// workspace에 백업을 쓴다: 지금 백업과 오늘 날짜 사본(그날 마지막 상태가 남는다). 오래된 사본은 지운다.
    /// 중간에 끊겨도 이전 백업이 남도록 통째로 바꿔 쓴다.
    @discardableResult
    public static func write(_ library: Library, to workspace: URL, now: Date = Date()) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let folder = backupFolder(in: workspace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        moveOldBackup(in: workspace)
        let url = currentURL(in: workspace)
        let file = try make(from: library)
        // DB를 잃어 서재가 비었을 때 좋은 백업을 빈 백업으로 덮지 않는다. 되살리기는 이 파일에서 한다.
        if file.items.isEmpty, let existing = try? read(from: workspace), !existing.items.isEmpty { return url }
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
        try data.write(to: folder.appendingPathComponent(dailyName(for: now)), options: .atomic)
        for old in dailyBackups(in: workspace).dropFirst(dailyCopies) { try? FileManager.default.removeItem(at: old) }
        return url
    }

    /// 날짜별 사본, 최근 것부터.
    public static func dailyBackups(in workspace: URL) -> [URL] {
        let folder = backupFolder(in: workspace)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.range(of: #"^Quillo-\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil }
            .sorted(by: >).map { folder.appendingPathComponent($0) }
    }

    /// 사본 이름의 날짜(`2026-11-19`).
    public static func day(of url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        return name.hasPrefix("Quillo-") ? String(name.dropFirst("Quillo-".count)) : nil
    }

    /// workspace의 지금 백업. 숨김 폴더에 없으면 예전 자리(workspace 바로 아래)를 본다. 없으면 nil.
    public static func read(from workspace: URL) throws -> File? {
        for url in [currentURL(in: workspace), workspace.appendingPathComponent(fileName), workspace.appendingPathComponent(oldFileName)]
        where FileManager.default.fileExists(atPath: url.path) {
            return try read(url)
        }
        return nil
    }

    public static func read(_ url: URL) throws -> File {
        try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    public struct RestoreResult: Equatable {
        public var items = 0, collections = 0, attachments = 0, notes = 0, tags = 0
    }

    /// 서재를 백업 내용으로 통째로 바꾼다(한 트랜잭션이라 중간에 실패하면 그대로 남는다).
    /// 지금 DB의 사본은 부르는 쪽이 먼저 남긴다.
    @discardableResult
    public static func restore(_ file: File, into library: Library) throws -> RestoreResult {
        let db = library.db
        return try db.transaction {
            for table in ["collection_items", "item_tags", "notes", "attachments", "creators", "items",
                          "collections", "tags", "deleted_items"] {
                try db.run("DELETE FROM \(table)")
            }
            var result = RestoreResult()
            var collectionID: [String: Int64] = [:]
            for c in file.collections {
                try db.run("INSERT INTO collections (key, name, zotero_key) VALUES (?,?,?)",
                           [.text(c.key), .text(c.name), SQLValue(c.zoteroKey)])
                collectionID[c.key] = db.lastInsertID
            }
            for c in file.collections {
                guard let parent = c.parent.flatMap({ collectionID[$0] }), let id = collectionID[c.key] else { continue }
                try db.run("UPDATE collections SET parent_id = ? WHERE id = ?", [.int(parent), .int(id)])
            }
            result.collections = collectionID.count
            var tagID: [String: Int64] = [:]
            for item in file.items {
                let fields = String(decoding: try JSONEncoder.sorted.encode(item.fields), as: UTF8.self)
                let values: [SQLValue] = [
                    .text(item.key), .text(item.type), .text(item.title), SQLValue(item.date),
                    SQLValue(item.year ?? ZoteroImport.parseDate(item.date).year), SQLValue(item.venue),
                    SQLValue(item.doi), SQLValue(item.arxivID), SQLValue(item.url), SQLValue(item.abstract),
                    SQLValue(item.citationKey), .text(fields), .text(item.addedAt), .text(item.modifiedAt),
                    SQLValue(item.zoteroKey),
                ]
                try db.run("INSERT INTO items (key, type, title, date, year, venue, doi, arxiv_id, url, abstract, "
                           + "citation_key, fields, added_at, modified_at, zotero_key) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                           values)
                let id = db.lastInsertID
                for (position, creator) in item.creators.enumerated() {
                    try db.run("INSERT INTO creators (item_id, position, role, family, given) VALUES (?,?,?,?,?)",
                               [.int(id), .int(Int64(position)), .text(creator.role), .text(creator.family),
                                SQLValue(creator.given)])
                }
                for path in item.attachments {
                    try db.run("INSERT INTO attachments (item_id, path) VALUES (?,?)", [.int(id), .text(path)])
                    result.attachments += 1
                }
                for key in item.collections {
                    guard let c = collectionID[key] else { continue }
                    try db.run("INSERT OR IGNORE INTO collection_items (collection_id, item_id) VALUES (?,?)",
                               [.int(c), .int(id)])
                }
                for name in item.tags {
                    let tag: Int64
                    if let known = tagID[name] {
                        tag = known
                    } else {
                        try db.run("INSERT INTO tags (name) VALUES (?)", [.text(name)])
                        tag = db.lastInsertID
                        tagID[name] = tag
                    }
                    try db.run("INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?,?)", [.int(id), .int(tag)])
                }
                for html in item.notes {
                    try db.run("INSERT INTO notes (item_id, html) VALUES (?,?)", [.int(id), .text(html)])
                    result.notes += 1
                }
                result.items += 1
            }
            for name in file.tags ?? [] where tagID[name] == nil {
                try db.run("INSERT OR IGNORE INTO tags (name) VALUES (?)", [.text(name)])
                tagID[name] = db.lastInsertID
            }
            result.tags = tagID.count
            for d in file.deleted {
                try db.run("INSERT OR REPLACE INTO deleted_items (key, deleted_at) VALUES (?,?)",
                           [.text(d.key), .text(d.deletedAt)])
            }
            return result
        }
    }
}
