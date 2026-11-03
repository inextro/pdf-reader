import Foundation

/// 지우기 직전의 DB 행과 휴지통으로 간 파일. Workspace.restore로 되살린다(⌘Z).
public struct DeletionSnapshot {
    /// 되살릴 때 넣는 순서대로: 컬렉션(부모 먼저), 논문, 저자, 첨부, 소속, 태그, 노트.
    var tables: [(name: String, rows: [SQLRow])] = []
    /// deleted_items에서 다시 뺄 key(동기화용 삭제 기록).
    var deletedKeys: [String] = []
    /// workspace 기준 원래 경로 → 휴지통의 실제 위치.
    var files: [(original: String, trashed: URL)] = []
    /// PDF를 휴지통으로 보내지 못해 남긴 논문이 있으면 그 오류. 지운 나머지는 그래도 되살릴 수 있다.
    public var failure: Workspace.Failure?

    public var isEmpty: Bool { tables.allSatisfy { $0.rows.isEmpty } }
    public var itemCount: Int { itemIDs.count }
    public var itemIDs: [Int64] { tables.first { $0.name == "items" }?.rows.compactMap { $0.int("id") } ?? [] }
    /// 지운 컬렉션 중 맨 위 컬렉션(하위 컬렉션은 함께 지워진다).
    public var collectionID: Int64? { tables.first { $0.name == "collections" }?.rows.first?.int("id") }
}

extension Library {
    /// 지우기 전에 부른다. items와 collections(하위 컬렉션 포함해 넘긴다)에 딸린 행을 모두 읽어 둔다.
    func snapshot(items ids: [Int64], collections cids: [Int64] = []) throws -> DeletionSnapshot {
        func list(_ values: [Int64]) -> String { values.isEmpty ? "NULL" : values.map(String.init).joined(separator: ",") }
        let items = list(ids), collections = list(cids)
        var s = DeletionSnapshot()
        // 부모가 먼저 들어가야 하므로 깊이 순으로 놓는다.
        let collectionRows = try db.query("SELECT * FROM collections WHERE id IN (\(collections))")
        var ordered: [SQLRow] = [], placed = Set<Int64>(), pending = collectionRows
        let inSet = Set(cids)
        while !pending.isEmpty {
            let (ready, rest) = (pending.filter { row in row.int("parent_id").map { !inSet.contains($0) || placed.contains($0) } ?? true },
                                 pending.filter { row in !(row.int("parent_id").map { !inSet.contains($0) || placed.contains($0) } ?? true) })
            guard !ready.isEmpty else { ordered += rest; break }
            ordered += ready
            placed.formUnion(ready.compactMap { $0.int("id") })
            pending = rest
        }
        s.tables.append(("collections", ordered))
        s.tables.append(("items", try db.query("SELECT * FROM items WHERE id IN (\(items))")))
        for table in ["creators", "attachments"] {
            s.tables.append((table, try db.query("SELECT * FROM \(table) WHERE item_id IN (\(items))")))
        }
        s.tables.append(("collection_items", try db.query(
            "SELECT * FROM collection_items WHERE item_id IN (\(items)) OR collection_id IN (\(collections))")))
        for table in ["item_tags", "notes"] {
            s.tables.append((table, try db.query("SELECT * FROM \(table) WHERE item_id IN (\(items))")))
        }
        s.deletedKeys = s.tables.first { $0.name == "items" }?.rows.compactMap { $0["key"] } ?? []
        return s
    }

    /// 읽어 둔 행을 그대로(같은 id로) 다시 넣는다. 그사이 같은 citation key 등이 생겨 겹치는 행은 건너뛴다.
    func restoreRows(_ s: DeletionSnapshot, attachmentPaths: [String: String] = [:]) throws {
        try db.transaction {
            for (table, rows) in s.tables {
                for row in rows {
                    var values = row.values
                    if table == "attachments", let path = values["path"]?.string, let moved = attachmentPaths[path] {
                        values["path"] = .text(moved)
                    }
                    let columns = values.keys.sorted()
                    try db.run("INSERT OR IGNORE INTO \(table) (\(columns.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ",")))",
                               columns.map { values[$0] ?? .null })
                }
            }
            for key in s.deletedKeys { try db.run("DELETE FROM deleted_items WHERE key = ?", [.text(key)]) }
        }
    }
}

extension Workspace {
    /// 지운 논문·컬렉션을 되살린다. 휴지통의 파일은 원래 자리로 되돌린다(이름을 바꿔 보냈어도 원래 이름으로).
    /// 원래 자리에 같은 이름의 파일이 생겼으면 겹치지 않는 이름으로 두고 첨부 경로를 맞춘다.
    /// 휴지통을 비워 파일이 없으면 서지 정보만 되살린다.
    public func restore(_ s: DeletionSnapshot) throws {
        let fm = FileManager.default
        var moved: [String: String] = [:]
        // 폴더(컬렉션)를 먼저 되돌려야 그 안의 PDF 자리가 생긴다.
        for (original, trashed) in s.files.sorted(by: { $0.original.count < $1.original.count }) {
            guard fm.fileExists(atPath: trashed.path) else { continue }
            var target = original
            var n = 2
            while fm.fileExists(atPath: Library.resolve(target, in: root).path) {
                let ext = (original as NSString).pathExtension
                let base = ext.isEmpty ? original : String(original.dropLast(ext.count + 1))
                target = "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
                n += 1
            }
            let destination = Library.resolve(target, in: root)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: trashed, to: destination)
            if target != original { moved[original] = target }
        }
        // 폴더를 되돌리지 못한 컬렉션은 빈 폴더라도 만들어 둔다(workspace에서는 컬렉션 = 폴더).
        let paths = Workspace.paths(of: try library.collections())
        try library.restoreRows(s, attachmentPaths: moved)
        let restoredPaths = Workspace.paths(of: try library.collections())
        for (id, path) in restoredPaths where paths[id] == nil {
            try? fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
    }
}
