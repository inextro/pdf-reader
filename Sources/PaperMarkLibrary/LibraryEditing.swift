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

    /// 서지 정보를 통째로 바꾼다(PDF에서 DOI를 찾아 다시 채울 때). PDF·컬렉션·태그·노트는 그대로 둔다.
    public func update(_ id: Int64, with m: PaperMetadata, citationKey: String?) throws {
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

    /// 태그를 붙인다. 없는 태그면 만든다. 이름은 Zotero처럼 앞의 "/"를 빼고 대소문자 없이 같으면 같은 태그로 본다("/To Do" = "To Do").
    public func addTag(_ name: String, to id: Int64) throws {
        func plain(_ s: String) -> String { (s.hasPrefix("/") ? String(s.dropFirst()) : s).lowercased() }
        try db.transaction {
            let existing = try db.query("SELECT id, name FROM tags").first { plain($0["name"] ?? "") == plain(name) }?.int("id")
            let tagID: Int64
            if let existing {
                tagID = existing
            } else {
                try db.run("INSERT INTO tags (name) VALUES (?)", [.text(name)])
                tagID = db.lastInsertID
            }
            try db.run("INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?,?)", [.int(id), .int(tagID)])
            try touch(id)
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
        for (position, creator) in creators.enumerated() {
            try db.run("INSERT INTO creators (item_id, position, role, family, given) VALUES (?,?,?,?,?)",
                       [.int(id), .int(Int64(position)), .text(creator.role), .text(creator.family), SQLValue(creator.given)])
        }
    }
}
