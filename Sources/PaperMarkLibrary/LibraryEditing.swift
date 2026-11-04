import Foundation

/// 브라우저 확장 등으로 PaperLibrary에서 직접 항목을 만들고 고친다. 고칠 때마다 modified_at을 새로 적는다.
extension Library {
    /// DOI, arXiv 번호, 제목 순으로 같은 논문이 이미 있는지 찾는다.
    public func existingItem(for m: PaperMetadata) throws -> Int64? {
        if let doi = m.doi,
           let id = try db.query("SELECT id FROM items WHERE lower(doi) = lower(?) LIMIT 1", [.text(doi)]).first?.int("id") {
            return id
        }
        if let arxiv = m.arxivID {
            for row in try db.query("SELECT id, arxiv_id FROM items WHERE arxiv_id LIKE ?", [.text(arxiv + "%")])
            where PaperID.arxiv(in: "arXiv:" + (row["arxiv_id"] ?? "")) == arxiv {
                return row.int("id")
            }
        }
        // 제목은 짧으면 우연히 겹칠 수 있어 어느 정도 길 때만 본다.
        let title = PaperMetadata.titleKey(m.title)
        guard title.count >= 16 else { return nil }
        return try db.query("SELECT id, title FROM items").first { PaperMetadata.titleKey($0["title"] ?? "") == title }?.int("id")
    }

    public func citationKeys() throws -> Set<String> {
        Set(try db.query("SELECT citation_key FROM items WHERE citation_key IS NOT NULL").compactMap { $0["citation_key"] })
    }

    public func item(_ id: Int64) throws -> LibraryEntry? {
        try items().first { $0.id == id }
    }

    @discardableResult
    public func add(_ m: PaperMetadata, citationKey: String?, collectionID: Int64?) throws -> Int64 {
        try db.transaction {
            let now = Library.now()
            try db.run("""
                INSERT INTO items (type, title, date, year, venue, doi, arxiv_id, url, abstract, citation_key, fields,
                  key, added_at, modified_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, try columns(of: m, citationKey: citationKey) + [.text(UUID().uuidString), .text(now), .text(now)])
            let id = db.lastInsertID
            try insertCreators(m.creators, of: id)
            if let collectionID {
                try db.run("INSERT INTO collection_items (collection_id, item_id) VALUES (?,?)", [.int(collectionID), .int(id)])
            }
            return id
        }
    }

    /// 서지 정보를 통째로 바꾼다(PDF에서 DOI를 찾아 다시 채울 때, 확장으로 다시 저장할 때). PDF·컬렉션·태그·노트는 그대로 둔다.
    /// 사용자가 손으로 고친 칸(Library.editedKey)은 바꾸지 않는다.
    public func update(_ id: Int64, with m: PaperMetadata, citationKey: String?) throws {
        guard let current = try item(id) else { return }
        var m = m, citationKey = citationKey
        let edited = Self.editedFields(of: current)
        if !edited.isEmpty {
            let mine = PaperMetadata(current)
            for name in edited {
                switch name {
                case "type": m.type = mine.type
                case "title": m.title = mine.title
                case "creators": m.creators = mine.creators
                case "date": m.date = mine.date
                case "venue": m.venue = mine.venue
                case "doi": m.doi = mine.doi
                case "arxivID": m.arxivID = mine.arxivID
                case "url": m.url = mine.url
                case "abstract": m.abstract = mine.abstract
                case "citationKey": citationKey = current.citationKey
                default: m.fields[name] = mine.fields[name]
                }
            }
            m.fields[Self.editedKey] = current.fields[Self.editedKey]
            // 고친 venue가 Zotero venue 필드에도 그대로 남게.
            if edited.contains("venue") { m.fields[m.venueField] = mine.venue }
        }
        try write(id, m, citationKey: citationKey)
    }

    /// fields에 두는, 사용자가 고친 칸 이름 목록(쉼표로 잇는다). 백업·다른 기기에도 함께 간다.
    public static let editedKey = "_edited"

    public static func editedFields(of entry: LibraryEntry) -> Set<String> {
        Set((entry.fields[editedKey] ?? "").split(separator: ",").map(String.init))
    }

    /// 사용자가 정보 패널에서 고친 내용을 저장한다. 바뀐 칸을 기억해 두고, 뒤에 확장 등이 다시 채울 때 지킨다.
    public func edit(_ id: Int64, to m: PaperMetadata, citationKey: String?) throws {
        guard let current = try item(id) else { return }
        let before = PaperMetadata(current)
        var changed = Self.editedFields(of: current)
        let pairs: [(String, Bool)] = [
            ("type", m.type != before.type), ("title", m.title != before.title), ("creators", m.creators != before.creators),
            ("date", m.date != before.date), ("venue", m.venue != before.venue), ("doi", m.doi != before.doi),
            ("arxivID", m.arxivID != before.arxivID), ("url", m.url != before.url), ("abstract", m.abstract != before.abstract),
            ("citationKey", citationKey != current.citationKey),
        ]
        for (name, differs) in pairs where differs { changed.insert(name) }
        for name in Set(m.fields.keys).union(before.fields.keys) where name != Self.editedKey && m.fields[name] != before.fields[name] {
            changed.insert(name)
        }
        var m = m
        m.fields[Self.editedKey] = changed.isEmpty ? nil : changed.sorted().joined(separator: ",")
        try write(id, m, citationKey: citationKey)
    }

    private func write(_ id: Int64, _ m: PaperMetadata, citationKey: String?) throws {
        try db.transaction {
            try db.run("""
                UPDATE items SET type=?, title=?, date=?, year=?, venue=?, doi=?, arxiv_id=?, url=?, abstract=?,
                  citation_key=?, fields=?, modified_at=? WHERE id = ?
                """, try columns(of: m, citationKey: citationKey) + [.text(Library.now()), .int(id)])
            try db.run("DELETE FROM creators WHERE item_id = ?", [.int(id)])
            try insertCreators(m.creators, of: id)
        }
    }

    public func setCitationKey(_ key: String?, of id: Int64) throws {
        try db.run("UPDATE items SET citation_key = ?, modified_at = ? WHERE id = ?", [SQLValue(key), .text(Library.now()), .int(id)])
    }

    /// 태그 이름을 비교할 꼴. Zotero처럼 앞의 "/"를 빼고 대소문자 없이 같으면 같은 태그로 본다("/To Do" = "To Do").
    public static func tagKey(_ name: String) -> String {
        name.drop { $0 == "/" }.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 이름이 같은(tagKey) 태그의 id. 없고 create면 만든다.
    @discardableResult
    public func tagID(_ name: String, create: Bool = true) throws -> Int64? {
        if let existing = try db.query("SELECT id, name FROM tags").first(where: { Self.tagKey($0["name"] ?? "") == Self.tagKey(name) })?.int("id") {
            return existing
        }
        guard create else { return nil }
        try db.run("INSERT INTO tags (name) VALUES (?)", [.text(name)])
        return db.lastInsertID
    }

    /// 태그를 붙인다. 없는 태그면 만든다.
    public func addTag(_ name: String, to id: Int64) throws {
        try setTag(name, of: [id], removing: [])
    }

    /// 묶음(읽기 상태 등) 가운데 하나만 남긴다: removing에 든 다른 태그를 떼고 name을 붙인다. name이 nil이면 떼기만 한다.
    public func setTag(_ name: String?, of ids: [Int64], removing group: [String]) throws {
        try db.transaction {
            let keep = name.map(Self.tagKey)
            let doomed = Set(group.map(Self.tagKey)).subtracting(keep.map { [$0] } ?? [])
            let doomedIDs = try db.query("SELECT id, name FROM tags").filter { doomed.contains(Self.tagKey($0["name"] ?? "")) }.compactMap { $0.int("id") }
            let tagID = try name.flatMap { try self.tagID($0) }
            for id in ids {
                for tag in doomedIDs { try db.run("DELETE FROM item_tags WHERE item_id = ? AND tag_id = ?", [.int(id), .int(tag)]) }
                if let tagID { try db.run("INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?,?)", [.int(id), .int(tagID)]) }
                try touch(id)
            }
        }
    }

    /// 태그 이름을 바꾼다. 같은 이름(tagKey)의 다른 태그가 있으면 그 태그로 합친다. 붙은 논문은 모두 고친 것으로 친다.
    public func renameTag(_ old: String, to new: String) throws {
        try db.transaction {
            guard let oldID = try tagID(old, create: false) else { return }
            let items = try db.query("SELECT item_id FROM item_tags WHERE tag_id = ?", [.int(oldID)]).compactMap { $0.int("item_id") }
            if let other = try tagID(new, create: false), other != oldID {
                try db.run("INSERT OR IGNORE INTO item_tags (item_id, tag_id) SELECT item_id, ? FROM item_tags WHERE tag_id = ?", [.int(other), .int(oldID)])
                try db.run("DELETE FROM tags WHERE id = ?", [.int(oldID)])
            } else {
                try db.run("UPDATE tags SET name = ? WHERE id = ?", [.text(new), .int(oldID)])
            }
            for id in items { try touch(id) }
        }
    }

    /// 태그를 지운다. 논문에서도 떨어진다(논문은 그대로).
    public func deleteTag(_ name: String) throws {
        try db.transaction {
            guard let tagID = try tagID(name, create: false) else { return }
            let items = try db.query("SELECT item_id FROM item_tags WHERE tag_id = ?", [.int(tagID)]).compactMap { $0.int("item_id") }
            try db.run("DELETE FROM item_tags WHERE tag_id = ?", [.int(tagID)])
            try db.run("DELETE FROM tags WHERE id = ?", [.int(tagID)])
            for id in items { try touch(id) }
        }
    }

    public func addAttachment(_ path: String, to id: Int64) throws {
        try db.transaction {
            try db.run("INSERT INTO attachments (item_id, path) VALUES (?,?)", [.int(id), .text(path)])
            try touch(id)
        }
    }

    /// 항목을 지우고 기록을 남긴다(기기 간 동기화에서 삭제를 전파할 때 쓴다). PDF 파일은 건드리지 않는다.
    public func deleteItem(_ id: Int64) throws {
        try db.transaction {
            if let key = try db.query("SELECT key FROM items WHERE id = ?", [.int(id)]).first?["key"] {
                try db.run("INSERT OR REPLACE INTO deleted_items (key, deleted_at) VALUES (?, ?)", [.text(key), .text(Library.now())])
            }
            try db.run("DELETE FROM items WHERE id = ?", [.int(id)])
        }
    }

    /// from 컬렉션에서 빼고 to 컬렉션에 넣는다. 둘 중 nil인 쪽은 건너뛴다.
    public func moveItem(_ id: Int64, from: Int64?, to: Int64?) throws {
        try db.transaction {
            if let from {
                try db.run("DELETE FROM collection_items WHERE collection_id = ? AND item_id = ?", [.int(from), .int(id)])
            }
            if let to {
                try db.run("INSERT OR IGNORE INTO collection_items (collection_id, item_id) VALUES (?,?)", [.int(to), .int(id)])
            }
            try touch(id)
        }
    }

    private func touch(_ id: Int64) throws {
        try db.run("UPDATE items SET modified_at = ? WHERE id = ?", [.text(Library.now()), .int(id)])
    }

    private func columns(of m: PaperMetadata, citationKey: String?) throws -> [SQLValue] {
        var fields = m.fields
        if let venue = m.venue, fields[m.venueField] == nil { fields[m.venueField] = venue }
        let json = String(decoding: try JSONEncoder.sorted.encode(fields), as: UTF8.self)
        return [.text(m.type), .text(m.title), SQLValue(m.date), SQLValue(m.year), SQLValue(m.venue), SQLValue(m.doi),
                SQLValue(m.arxivID), SQLValue(m.url), SQLValue(m.abstract), SQLValue(citationKey), .text(json)]
    }

    private func insertCreators(_ creators: [Creator], of id: Int64) throws {
        for (position, creator) in Creator.people(creators).enumerated() {
            try db.run("INSERT INTO creators (item_id, position, role, family, given) VALUES (?,?,?,?,?)",
                       [.int(id), .int(Int64(position)), .text(creator.role), .text(creator.family), SQLValue(creator.given)])
        }
    }
}
