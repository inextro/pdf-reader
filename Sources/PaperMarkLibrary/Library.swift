import Foundation

/// Mac 로컬 SQLite에 둔 서지 라이브러리. PDF는 라이브러리 폴더(Drive)에 있고 DB에는 그 안의 경로만 적는다.
public final class Library {
    public let db: SQLiteDatabase
    public static let schemaVersion = 1

    /// `~/Library/Application Support/PaperLibrary/library.sqlite`
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperLibrary/library.sqlite")
    }

    public init(url: URL = Library.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: url.path)
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        try migrate()
    }

    public var version: Int { Int(((try? db.query("PRAGMA user_version"))?.first?.int("user_version")) ?? 0) }

    private func migrate() throws {
        guard version < Self.schemaVersion else { return }
        try db.transaction {
            if version < 1 { try db.execute(Self.schemaV1) }
            try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    private static let schemaV1 = """
        CREATE TABLE items (
          id INTEGER PRIMARY KEY,
          key TEXT NOT NULL UNIQUE,
          type TEXT NOT NULL,
          title TEXT NOT NULL DEFAULT '',
          date TEXT,
          year INTEGER,
          venue TEXT,
          doi TEXT,
          arxiv_id TEXT,
          url TEXT,
          abstract TEXT,
          citation_key TEXT UNIQUE,
          fields TEXT NOT NULL DEFAULT '{}',
          added_at TEXT NOT NULL,
          modified_at TEXT NOT NULL,
          zotero_key TEXT UNIQUE
        );
        CREATE TABLE creators (
          item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          role TEXT NOT NULL,
          family TEXT,
          given TEXT,
          PRIMARY KEY (item_id, position)
        );
        CREATE TABLE attachments (
          id INTEGER PRIMARY KEY,
          item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
          path TEXT NOT NULL,
          zotero_key TEXT UNIQUE
        );
        CREATE TABLE collections (
          id INTEGER PRIMARY KEY,
          key TEXT NOT NULL UNIQUE,
          parent_id INTEGER REFERENCES collections(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          zotero_key TEXT UNIQUE
        );
        CREATE TABLE collection_items (
          collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
          item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
          PRIMARY KEY (collection_id, item_id)
        );
        CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
        CREATE TABLE item_tags (
          item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
          tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
          PRIMARY KEY (item_id, tag_id)
        );
        CREATE TABLE notes (
          id INTEGER PRIMARY KEY,
          item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
          html TEXT NOT NULL,
          zotero_key TEXT UNIQUE
        );
        CREATE TABLE deleted_items (key TEXT PRIMARY KEY, deleted_at TEXT NOT NULL);
        CREATE INDEX attachments_item ON attachments(item_id);
        CREATE INDEX attachments_path ON attachments(path);
        CREATE INDEX items_doi ON items(doi);
        """

    // MARK: 읽기

    /// 모든 항목. 몇천 개까지는 한 번에 읽어 메모리에서 거르는 편이 단순하고 빠르다.
    public func items() throws -> [LibraryEntry] {
        var items: [Int64: LibraryEntry] = [:]
        var order: [Int64] = []
        for row in try db.query("SELECT * FROM items ORDER BY added_at DESC") {
            guard let id = row.int("id") else { continue }
            let fields = row["fields"].flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
            items[id] = LibraryEntry(
                id: id, key: row["key"] ?? "", type: row["type"] ?? "other", title: row["title"] ?? "",
                date: row["date"], year: row.int("year").map(Int.init), venue: row["venue"], doi: row["doi"],
                arxivID: row["arxiv_id"], url: row["url"], abstract: row["abstract"], citationKey: row["citation_key"],
                fields: fields ?? [:], addedAt: row["added_at"] ?? "", modifiedAt: row["modified_at"] ?? "")
            order.append(id)
        }
        for row in try db.query("SELECT * FROM creators ORDER BY item_id, position") {
            guard let id = row.int("item_id") else { continue }
            items[id]?.creators.append(Creator(role: row["role"] ?? "author", family: row["family"] ?? "", given: row["given"]))
        }
        for row in try db.query("SELECT item_id, path FROM attachments ORDER BY id") {
            if let id = row.int("item_id"), let path = row["path"] { items[id]?.attachments.append(path) }
        }
        for row in try db.query("SELECT * FROM collection_items") {
            if let id = row.int("item_id"), let c = row.int("collection_id") { items[id]?.collectionIDs.insert(c) }
        }
        for row in try db.query("SELECT item_id, name FROM item_tags JOIN tags ON tags.id = tag_id ORDER BY name") {
            if let id = row.int("item_id"), let name = row["name"] { items[id]?.tags.append(name) }
        }
        for row in try db.query("SELECT item_id, count(*) AS n FROM notes GROUP BY item_id") {
            if let id = row.int("item_id") { items[id]?.noteCount = Int(row.int("n") ?? 0) }
        }
        return order.compactMap { items[$0] }
    }

    /// 컬렉션들(이름순). 트리는 parentID로 만든다.
    public func collections() throws -> [LibraryCollection] {
        try db.query("SELECT * FROM collections ORDER BY name COLLATE NOCASE").compactMap { row in
            guard let id = row.int("id") else { return nil }
            return LibraryCollection(id: id, key: row["key"] ?? "", parentID: row.int("parent_id"), name: row["name"] ?? "")
        }
    }

    public func tags() throws -> [String] {
        try db.query("SELECT name FROM tags ORDER BY name COLLATE NOCASE").compactMap { $0["name"] }
    }

    public func notes(of itemID: Int64) throws -> [String] {
        try db.query("SELECT html FROM notes WHERE item_id = ? ORDER BY id", [.int(itemID)]).compactMap { $0["html"] }
    }

    /// 열린 PDF가 라이브러리 항목의 첨부인지 찾는다.
    public func itemID(forPDF url: URL, in folder: URL) throws -> Int64? {
        let path = Self.storedPath(for: url, in: folder)
        return try db.query("SELECT item_id FROM attachments WHERE path = ? LIMIT 1", [.text(path)]).first?.int("item_id")
    }

    // MARK: 경로

    /// 라이브러리 폴더 안이면 상대 경로, 밖이면 절대 경로.
    public static func storedPath(for url: URL, in folder: URL) -> String {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let target = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard target.count > base.count, Array(target.prefix(base.count)) == base else { return url.standardizedFileURL.path }
        return target[base.count...].joined(separator: "/")
    }

    public static func resolve(_ path: String, in folder: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
    }

    /// 지금 시각(UTC ISO 8601). 기기끼리 맞출 때 그대로 비교할 수 있게 초 단위 UTC로 쓴다.
    public static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
