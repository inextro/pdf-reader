import Foundation

/// Zotero 라이브러리(`zotero.sqlite`)를 읽기 전용으로 열어 서지·저자·PDF 경로·컬렉션·태그·노트를 가져온다.
/// 여러 번 가져와도 결과가 같다: Zotero 항목 키로 같은 항목을 찾아 Zotero 내용으로 고치고,
/// Zotero에서 지운 항목은 여기서도 지운다. Zotero DB에는 절대 쓰지 않는다.
public enum ZoteroImport {
    public struct Result: Equatable {
        public var items = 0, attachments = 0, collections = 0, tags = 0, notes = 0
        public var removed = 0
        /// PDF가 아니거나 Zotero storage 안에 저장된(연결 파일이 아닌) 첨부.
        public var skippedAttachments = 0
        /// `attachments:` 경로인데 첨부 base 폴더를 몰라서 위치를 정하지 못한 첨부.
        public var unresolvedAttachments = 0
    }

    public static var defaultDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Zotero/zotero.sqlite")
    }

    /// Zotero 설정의 첨부 base 폴더(`extensions.zotero.baseAttachmentPath`). 프로필이 여럿이면 처음 찾은 것.
    public static func attachmentBase(profiles: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Zotero/Profiles")) -> URL? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs.sorted(by: { $0.path < $1.path }) {
            guard let prefs = try? String(contentsOf: dir.appendingPathComponent("prefs.js"), encoding: .utf8),
                  let path = prefValue("extensions.zotero.baseAttachmentPath", in: prefs) else { continue }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    /// prefs.js의 `user_pref("name", "value");` 줄에서 문자열 값을 꺼낸다.
    public static func prefValue(_ name: String, in prefs: String) -> String? {
        for line in prefs.split(separator: "\n") where line.contains("\"\(name)\"") {
            guard let comma = line.range(of: "\"\(name)\",") else { continue }
            let rest = line[comma.upperBound...].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") else { continue }
            return String(rest[rest.index(after: rest.startIndex)..<end])
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return nil
    }

    /// Zotero의 `date` 값("2023-10-31 2023-10-31", "1994-12-00 1994-12")에서 원문과 연도를 뽑는다.
    public static func parseDate(_ value: String?) -> (text: String?, year: Int?) {
        guard let value, !value.isEmpty else { return (nil, nil) }
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        let sql = parts[0]
        let isSQL = sql.count == 10 && sql.dropFirst(4).first == "-"
        let text = isSQL ? (parts.count > 1 ? parts[1] : sql) : value
        let year = isSQL ? Int(sql.prefix(4)).flatMap { $0 > 0 ? $0 : nil } : firstYear(in: value)
        return (text, year)
    }

    private static func firstYear(in text: String) -> Int? {
        guard let r = text.range(of: #"\b(1[5-9]|20)\d{2}\b"#, options: .regularExpression) else { return nil }
        return Int(text[r])
    }

    /// archiveID("arXiv:2310.20453"), extra("arXiv:2310.20453 [cs]"), arxiv.org URL 순으로 찾는다.
    public static func arxivID(archiveID: String?, extra: String?, url: String?) -> String? {
        let id = #"(\d{4}\.\d{4,5}|[a-z\-]+(\.[A-Z]{2})?/\d{7})(v\d+)?"#
        for text in [archiveID, extra].compactMap({ $0 }) {
            if let r = text.range(of: #"arXiv:\s*"# + id, options: .regularExpression) {
                return text[r].replacingOccurrences(of: #"arXiv:\s*"#, with: "", options: .regularExpression)
            }
        }
        if let url, url.contains("arxiv.org/"), let r = url.range(of: #"(abs|pdf)/"# + id, options: .regularExpression) {
            return String(url[r].drop(while: { $0 != "/" }).dropFirst())
                .replacingOccurrences(of: ".pdf", with: "")
        }
        return nil
    }

    public static func itemType(_ zotero: String) -> String {
        ["journalArticle", "conferencePaper", "preprint", "book", "webpage"].contains(zotero) ? zotero : "other"
    }

    /// Zotero 시각("2026-02-09 05:30:49", UTC)을 ISO 8601로.
    public static func isoDate(_ zotero: String?) -> String {
        guard let zotero, zotero.count == 19 else { return Library.now() }
        return zotero.replacingOccurrences(of: " ", with: "T") + "Z"
    }

    /// 열로 뽑아 두는 필드. 나머지는 `fields` JSON에 그대로 담는다.
    private static let columnFields: Set<String> = ["title", "date", "DOI", "url", "abstractNote", "citationKey"]
    private static let venueFields = ["publicationTitle", "proceedingsTitle", "conferenceName", "bookTitle",
                                      "websiteTitle", "repository"]

    /// zotero: zotero.sqlite 경로. base: Zotero 첨부 base 폴더. folder: 이 라이브러리의 PDF 폴더.
    @discardableResult
    public static func run(zotero: URL, attachmentBase base: URL?, libraryFolder folder: URL,
                           into library: Library) throws -> Result {
        let encoded = zotero.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? zotero.path
        // immutable: Zotero가 켜져 있어도 잠그지 않고 읽는다(아직 WAL에만 있는 최근 변경은 못 볼 수 있다).
        let z = try SQLiteDatabase(path: "file:\(encoded)?immutable=1", readOnly: true)
        let userLibrary = try z.query("SELECT libraryID FROM libraries WHERE type = 'user'").first?.int("libraryID") ?? 1
        let lib = SQLValue.int(userLibrary)

        // 휴지통에 있는 것은 빼고, 첨부·노트·주석이 아닌 서지만.
        let zItems = try z.query("""
            SELECT i.itemID, i.key, t.typeName, i.dateAdded, i.dateModified FROM items i
            JOIN itemTypes t USING (itemTypeID)
            WHERE i.libraryID = ? AND t.typeName NOT IN ('attachment', 'note', 'annotation')
              AND i.itemID NOT IN (SELECT itemID FROM deletedItems)
            """, [lib])
        var fieldsByItem: [Int64: [String: String]] = [:]
        for row in try z.query("""
            SELECT d.itemID, f.fieldName, v.value FROM itemData d
            JOIN fields f USING (fieldID) JOIN itemDataValues v USING (valueID)
            """) {
            guard let id = row.int("itemID"), let name = row["fieldName"], let value = row["value"] else { continue }
            fieldsByItem[id, default: [:]][name] = value
        }
        var creatorsByItem: [Int64: [Creator]] = [:]
        for row in try z.query("""
            SELECT ic.itemID, c.firstName, c.lastName, ct.creatorType FROM itemCreators ic
            JOIN creators c USING (creatorID) JOIN creatorTypes ct USING (creatorTypeID)
            ORDER BY ic.itemID, ic.orderIndex
            """) {
            guard let id = row.int("itemID") else { continue }
            let given = row["firstName"].flatMap { $0.isEmpty ? nil : $0 }
            creatorsByItem[id, default: []].append(Creator(role: row["creatorType"] ?? "author",
                                                           family: row["lastName"] ?? "", given: given))
        }
        let zAttachments = try z.query("""
            SELECT a.parentItemID, a.linkMode, a.contentType, a.path, i.key FROM itemAttachments a
            JOIN items i USING (itemID)
            WHERE a.parentItemID IS NOT NULL AND a.itemID NOT IN (SELECT itemID FROM deletedItems)
            ORDER BY a.itemID
            """)
        let zNotes = try z.query("""
            SELECT n.parentItemID, n.note, i.key FROM itemNotes n JOIN items i USING (itemID)
            WHERE n.parentItemID IS NOT NULL AND n.itemID NOT IN (SELECT itemID FROM deletedItems)
            ORDER BY n.itemID
            """)
        let zCollections = try z.query("""
            SELECT collectionID, collectionName, parentCollectionID, key FROM collections
            WHERE libraryID = ? AND collectionID NOT IN (SELECT collectionID FROM deletedCollections)
            """, [lib])
        let zCollectionItems = try z.query("SELECT collectionID, itemID FROM collectionItems")
        let zTags = try z.query("SELECT it.itemID, t.name FROM itemTags it JOIN tags t USING (tagID)")

        let db = library.db
        return try db.transaction {
            var result = Result()
            let now = Library.now()

            // 서지
            var localID: [Int64: Int64] = [:]   // Zotero itemID → items.id
            // citation key는 UNIQUE라서, 두 항목이 key를 맞바꾸거나 Zotero에 같은 key가 둘 있어도 막히지 않게
            // 먼저 비우고 처음 나온 항목에만 준다.
            try db.run("UPDATE items SET citation_key = NULL WHERE zotero_key IS NOT NULL")
            var seenKeys: Set<String> = []
            for row in zItems {
                guard let zid = row.int("itemID"), let zkey = row["key"] else { continue }
                let f = fieldsByItem[zid] ?? [:]
                let (dateText, year) = parseDate(f["date"])
                let citationKey = f["citationKey"].flatMap { $0.isEmpty || seenKeys.contains($0) ? nil : $0 }
                if let citationKey { seenKeys.insert(citationKey) }
                let extra = f.filter { !columnFields.contains($0.key) }
                let json = String(decoding: try JSONEncoder.sorted.encode(extra), as: UTF8.self)
                let values: [SQLValue] = [
                    .text(itemType(row["typeName"] ?? "")), .text(f["title"] ?? ""), SQLValue(dateText), SQLValue(year),
                    SQLValue(venueFields.lazy.compactMap { f[$0] }.first), SQLValue(f["DOI"]),
                    SQLValue(arxivID(archiveID: f["archiveID"], extra: f["extra"], url: f["url"])), SQLValue(f["url"]),
                    SQLValue(f["abstractNote"]), SQLValue(citationKey),
                    .text(json), .text(isoDate(row["dateAdded"])), .text(isoDate(row["dateModified"])),
                ]
                if let id = try db.query("SELECT id FROM items WHERE zotero_key = ?", [.text(zkey)]).first?.int("id") {
                    try db.run("""
                        UPDATE items SET type=?, title=?, date=?, year=?, venue=?, doi=?, arxiv_id=?, url=?, abstract=?,
                          citation_key=?, fields=?, added_at=?, modified_at=? WHERE id = ?
                        """, values + [.int(id)])
                    localID[zid] = id
                    try db.run("DELETE FROM creators WHERE item_id = ?", [.int(id)])
                    try db.run("DELETE FROM attachments WHERE item_id = ?", [.int(id)])
                    try db.run("DELETE FROM notes WHERE item_id = ?", [.int(id)])
                    try db.run("DELETE FROM item_tags WHERE item_id = ?", [.int(id)])
                    try db.run("DELETE FROM collection_items WHERE item_id = ?", [.int(id)])
                } else {
                    try db.run("""
                        INSERT INTO items (type, title, date, year, venue, doi, arxiv_id, url, abstract, citation_key,
                          fields, added_at, modified_at, key, zotero_key) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """, values + [.text(UUID().uuidString), .text(zkey)])
                    localID[zid] = db.lastInsertID
                }
                for (position, creator) in (creatorsByItem[zid] ?? []).enumerated() {
                    try db.run("INSERT INTO creators (item_id, position, role, family, given) VALUES (?,?,?,?,?)",
                               [.int(localID[zid]!), .int(Int64(position)), .text(creator.role), .text(creator.family),
                                SQLValue(creator.given)])
                }
                result.items += 1
            }

            // Zotero에서 지운 항목은 여기서도 지우고 기록을 남긴다.
            let kept = Set(zItems.compactMap { $0["key"] })
            for row in try db.query("SELECT id, key, zotero_key FROM items WHERE zotero_key IS NOT NULL")
            where !kept.contains(row["zotero_key"] ?? "") {
                try db.run("DELETE FROM items WHERE id = ?", [SQLValue(row.int("id"))])
                try db.run("INSERT OR REPLACE INTO deleted_items (key, deleted_at) VALUES (?, ?)",
                           [SQLValue(row["key"]), .text(now)])
                result.removed += 1
            }

            // PDF: linked file만. "attachments:" 경로는 base 폴더 기준이다.
            for row in zAttachments {
                guard let parent = row.int("parentItemID"), let id = localID[parent] else { continue }
                guard row.int("linkMode") == 2, row["contentType"] == "application/pdf", let raw = row["path"] else {
                    result.skippedAttachments += 1
                    continue
                }
                let file: URL
                if raw.hasPrefix("attachments:") {
                    guard let base else { result.unresolvedAttachments += 1; continue }
                    file = base.appendingPathComponent(String(raw.dropFirst("attachments:".count)))
                } else {
                    file = URL(fileURLWithPath: raw)
                }
                try db.run("INSERT INTO attachments (item_id, path, zotero_key) VALUES (?,?,?)",
                           [.int(id), .text(Library.storedPath(for: file, in: folder)), SQLValue(row["key"])])
                result.attachments += 1
            }

            for row in zNotes {
                guard let parent = row.int("parentItemID"), let id = localID[parent] else { continue }
                try db.run("INSERT INTO notes (item_id, html, zotero_key) VALUES (?,?,?)",
                           [.int(id), .text(row["note"] ?? ""), SQLValue(row["key"])])
                result.notes += 1
            }

            // 컬렉션: 먼저 모두 만들거나 이름을 고친 뒤 부모를 잇는다.
            var collectionID: [Int64: Int64] = [:]
            for row in zCollections {
                guard let zid = row.int("collectionID"), let zkey = row["key"] else { continue }
                let name = SQLValue(row["collectionName"] ?? "")
                if let id = try db.query("SELECT id FROM collections WHERE zotero_key = ?", [.text(zkey)]).first?.int("id") {
                    try db.run("UPDATE collections SET name = ? WHERE id = ?", [name, .int(id)])
                    collectionID[zid] = id
                } else {
                    try db.run("INSERT INTO collections (key, name, zotero_key) VALUES (?,?,?)",
                               [.text(UUID().uuidString), name, .text(zkey)])
                    collectionID[zid] = db.lastInsertID
                }
            }
            for row in zCollections {
                guard let zid = row.int("collectionID"), let id = collectionID[zid] else { continue }
                try db.run("UPDATE collections SET parent_id = ? WHERE id = ?",
                           [SQLValue(row.int("parentCollectionID").flatMap { collectionID[$0] }), .int(id)])
            }
            let keptCollections = Set(zCollections.compactMap { $0["key"] })
            for row in try db.query("SELECT id, zotero_key FROM collections WHERE zotero_key IS NOT NULL")
            where !keptCollections.contains(row["zotero_key"] ?? "") {
                try db.run("DELETE FROM collections WHERE id = ?", [SQLValue(row.int("id"))])
            }
            result.collections = collectionID.count
            for row in zCollectionItems {
                guard let c = row.int("collectionID").flatMap({ collectionID[$0] }),
                      let i = row.int("itemID").flatMap({ localID[$0] }) else { continue }
                try db.run("INSERT OR IGNORE INTO collection_items (collection_id, item_id) VALUES (?,?)", [.int(c), .int(i)])
            }

            // 태그: 이름으로 찾거나 만들고, 아무 항목에도 안 붙은 태그는 지운다.
            for row in zTags {
                guard let i = row.int("itemID").flatMap({ localID[$0] }), let name = row["name"] else { continue }
                try db.run("INSERT OR IGNORE INTO tags (name) VALUES (?)", [.text(name)])
                try db.run("INSERT OR IGNORE INTO item_tags (item_id, tag_id) SELECT ?, id FROM tags WHERE name = ?",
                           [.int(i), .text(name)])
            }
            try db.run("DELETE FROM tags WHERE id NOT IN (SELECT tag_id FROM item_tags)")
            result.tags = Int(try db.query("SELECT count(*) AS n FROM tags").first?.int("n") ?? 0)
            return result
        }
    }
}

extension JSONEncoder {
    /// 키 순서를 고정해 같은 내용이면 같은 JSON이 나오게 한다.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
