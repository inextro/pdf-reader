import Foundation

/// workspace 폴더와 DB를 맞춘다. 컬렉션은 workspace 안의 폴더이고, PDF가 있는 폴더의 컬렉션이 그 논문의 원본 자리다.
/// 다른 컬렉션 소속은 참조다(DB에만 있고 폴더에는 파일이 없다). 원본·참조는 PDF 경로와 컬렉션 경로를 비교해 정한다.
public struct Workspace {
    public let library: Library
    public let root: URL
    private var fm: FileManager { .default }
    /// 지울 파일·폴더를 휴지통으로 보낸다. 검사에서는 바로 지우게 바꾼다.
    public var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    public init(library: Library, root: URL) {
        self.library = library
        self.root = root
    }

    public enum Failure: LocalizedError {
        case missingRoot(URL)
        case invalidName(String)
        case nameTaken(String)
        case scanFailed(String)
        case trashFailed([String], String)

        public var errorDescription: String? {
            switch self {
            case .missingRoot(let url): "The workspace folder is not available: \(url.path)"
            case .invalidName(let name): "“\(name)” cannot be used as a collection name."
            case .nameTaken(let name): "A collection or folder named “\(name)” already exists here."
            case .scanFailed(let message): "The workspace folder could not be read: \(message)"
            case .trashFailed(let names, let reason):
                (names.count == 1 ? "“\(names[0])” couldn’t be moved to the Trash, so its paper was kept in the library."
                    : "\(names.count) PDFs couldn’t be moved to the Trash, so their papers were kept in the library: "
                    + names.map { "“\($0)”" }.joined(separator: ", ") + ".")
                + " The other papers were deleted. Try again in a moment, or move the file to the Trash in Finder. (\(reason))"
            }
        }
    }

    // MARK: 경로

    /// 컬렉션 id → workspace 기준 폴더 경로("temp/ToDo").
    public static func paths(of collections: [LibraryCollection]) -> [Int64: String] {
        let byID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        var paths: [Int64: String] = [:]
        func path(_ c: LibraryCollection, depth: Int) -> String {
            if let known = paths[c.id] { return known }
            guard depth < 64, let parent = c.parentID.flatMap({ byID[$0] }) else { return c.name }
            return path(parent, depth: depth + 1) + "/" + c.name
        }
        for c in collections { paths[c.id] = path(c, depth: 0) }
        return paths
    }

    /// 상대 경로의 폴더 부분("temp/ToDo/a.pdf" → "temp/ToDo", "a.pdf" → ""). 절대 경로(workspace 밖)는 nil.
    public static func folder(of path: String) -> String? {
        guard !path.hasPrefix("/") else { return nil }
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// 경로를 비교할 때 쓰는 열쇠. Drive와 APFS는 대소문자와 유니코드 정규화를 가리지 않는다.
    public static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    /// 컬렉션 이름을 폴더 이름으로 쓸 수 있게 다듬는다. 쓸 수 없으면 nil.
    public static func folderName(_ name: String) -> String? {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? nil : cleaned
    }

    public enum Home: Equatable {
        /// PDF가 없거나 workspace 밖에 있다.
        case none
        /// workspace 맨 위(Unfiled).
        case top
        case collection(Int64)
    }

    /// 논문의 원본 자리: 첫 PDF가 있는 폴더의 컬렉션.
    public static func home(of item: LibraryEntry, paths: [Int64: String]) -> Home {
        guard let path = item.attachments.first, let folder = folder(of: path) else { return .none }
        if folder.isEmpty { return .top }
        let k = key(folder)
        return paths.first { key($0.value) == k }.map { .collection($0.key) } ?? .none
    }

    /// 이 컬렉션에서 참조로 보이는가(원본 PDF가 다른 폴더에 있다).
    public static func isReference(_ item: LibraryEntry, in collection: Int64, paths: [Int64: String]) -> Bool {
        switch home(of: item, paths: paths) {
        case .none: false
        case .top: true
        case .collection(let id): id != collection
        }
    }

    private func url(_ relative: String) -> URL {
        relative.isEmpty ? root : root.appendingPathComponent(relative)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    private func currentPaths() throws -> [Int64: String] { Self.paths(of: try library.collections()) }

    // MARK: 컬렉션 만들기·이름 바꾸기·지우기

    @discardableResult
    public func createCollection(_ name: String, parent: Int64?) throws -> Int64 {
        guard isDirectory(root) else { throw Failure.missingRoot(root) }
        guard let name = Self.folderName(name) else { throw Failure.invalidName(name) }
        let paths = try currentPaths()
        let parentPath = parent.flatMap { paths[$0] }
        let path = parentPath.map { $0 + "/" + name } ?? name
        if paths.values.contains(where: { Self.key($0) == Self.key(path) }) { throw Failure.nameTaken(name) }
        // 폴더가 이미 있으면(감시가 아직 못 따라온 것) 그대로 컬렉션으로 쓴다.
        try fm.createDirectory(at: url(path), withIntermediateDirectories: true)
        return try library.insertCollection(name: name, parent: parent)
    }

    public func renameCollection(_ id: Int64, to newName: String) throws {
        guard isDirectory(root) else { throw Failure.missingRoot(root) }
        guard let name = Self.folderName(newName) else { throw Failure.invalidName(newName) }
        let paths = try currentPaths()
        guard let old = paths[id] else { return }
        let parent = Self.folder(of: old) ?? ""
        let new = parent.isEmpty ? name : parent + "/" + name
        guard new != old else { return }
        let caseOnly = Self.key(new) == Self.key(old)
        if !caseOnly, paths.values.contains(where: { Self.key($0) == Self.key(new) }) || fm.fileExists(atPath: url(new).path) {
            throw Failure.nameTaken(name)
        }
        if isDirectory(url(old)) {
            if caseOnly {
                // 대소문자만 바꿀 때는 같은 이름으로 보여 한 번에 못 옮긴다.
                let temp = url(old).deletingLastPathComponent().appendingPathComponent(".rename-" + UUID().uuidString)
                try fm.moveItem(at: url(old), to: temp)
                try fm.moveItem(at: temp, to: url(new))
            } else {
                try fm.moveItem(at: url(old), to: url(new))
            }
        } else {
            try fm.createDirectory(at: url(new), withIntermediateDirectories: true)
        }
        do {
            try library.db.transaction {
                try library.setCollection(id, name: name)
                try library.replacePathPrefix(old, with: new)
            }
        } catch {
            try? fm.moveItem(at: url(new), to: url(old))
            throw error
        }
    }

    /// 지울 때 확인 창에 보일 수: 폴더 안의 PDF 파일과, 원본 자리가 그 안이라 함께 지워질 논문.
    public func deletionSummary(_ id: Int64) throws -> (pdfs: Int, items: Int) {
        let paths = try currentPaths()
        guard let path = paths[id] else { return (0, 0) }
        let pdfs = (fm.enumerator(at: url(path), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "pdf" }.count) ?? 0
        return (pdfs, try homeItems(under: path).count)
    }

    /// 폴더째 휴지통으로 보내고, 원본 자리가 그 안인 논문을 지운다. 참조는 소속만 사라진다(하위 컬렉션도 함께).
    public func deleteCollection(_ id: Int64) throws {
        let paths = try currentPaths()
        guard let path = paths[id] else { return }
        let doomed = try homeItems(under: path)
        if isDirectory(url(path)) {
            guard isDirectory(root) else { throw Failure.missingRoot(root) }
            try trash(url(path))
        }
        try library.db.transaction {
            for item in doomed { try library.deleteItem(item) }
            try library.db.run("DELETE FROM collections WHERE id = ?", [.int(id)])
        }
    }

    /// 논문들을 라이브러리에서 지우고 PDF를 휴지통으로 보낸다. 지우지 않는 다른 논문도 쓰는 PDF와 없는 파일은 건너뛴다.
    /// PDF를 휴지통으로 보내지 못한 논문(Google Drive가 아직 올리는 중일 때 등)은 파일과 어긋나지 않게 라이브러리에 남기고,
    /// 나머지는 지운 뒤 trashFailed로 알린다.
    public func deleteItems(_ ids: [Int64]) throws {
        guard isDirectory(root) else { throw Failure.missingRoot(root) }
        let items = try library.items()
        let doomed = Set(ids)
        let kept = Set(items.filter { !doomed.contains($0.id) }.flatMap(\.attachments).map(Self.key))
        var failed: [String] = [], reason = ""
        var failedKeys: Set<String> = []
        for path in Set(items.filter { doomed.contains($0.id) }.flatMap(\.attachments)) where !kept.contains(Self.key(path)) {
            let file = Library.resolve(path, in: root)
            guard fm.fileExists(atPath: file.path) else { continue }
            do {
                try trash(file)
            } catch {
                failed.append(file.lastPathComponent)
                failedKeys.insert(Self.key(path))
                reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
            }
        }
        let keep = Set(items.filter { item in item.attachments.contains { failedKeys.contains(Self.key($0)) } }.map(\.id))
        try library.db.transaction {
            for id in ids where !keep.contains(id) { try library.deleteItem(id) }
        }
        if !failed.isEmpty { throw Failure.trashFailed(failed.sorted(), reason) }
    }

    private func homeItems(under path: String) throws -> [Int64] {
        let prefix = Self.key(path) + "/"
        return try library.items().filter { item in
            guard let first = item.attachments.first, !first.hasPrefix("/") else { return false }
            return Self.key(first).hasPrefix(prefix)
        }.map(\.id)
    }

    // MARK: 옮기기와 참조

    /// 논문 하나를 옮기는 계획. file이 있으면 PDF도 옮긴다.
    public struct Move: Equatable {
        public var itemID: Int64
        public var removeFrom: Int64?
        public var addTo: Int64?
        /// (지금 경로, 옮길 경로) workspace 기준.
        public var file: (from: String, to: String)?
        /// 옮길 자리에 같은 이름의 다른 파일이 있다.
        public var conflict: Bool

        public init(itemID: Int64, removeFrom: Int64?, addTo: Int64?, file: (from: String, to: String)?, conflict: Bool) {
            (self.itemID, self.removeFrom, self.addTo, self.file, self.conflict) = (itemID, removeFrom, addTo, file, conflict)
        }

        public static func == (a: Move, b: Move) -> Bool {
            a.itemID == b.itemID && a.removeFrom == b.removeFrom && a.addTo == b.addTo
                && a.file?.from == b.file?.from && a.file?.to == b.file?.to && a.conflict == b.conflict
        }
    }

    public enum Resolution {
        case replace, keepBoth, skip
    }

    /// 논문들을 target 컬렉션(nil이면 Unfiled = workspace 맨 위)으로 옮기는 계획을 세운다.
    /// viewing은 사이드바에서 보고 있는 컬렉션: 그 안에서 참조인 논문은 참조만 옮기고, 원본이면 PDF와 함께 옮긴다.
    /// 컬렉션을 보고 있지 않으면 원본 자리에서 옮긴다. PDF가 없는 논문은 소속이 하나일 때 그것을 옮기고, 아니면 소속만 더한다.
    public func planMove(_ ids: [Int64], viewing: Int64?, to target: Int64?) throws -> [Move] {
        let paths = try currentPaths()
        let items = Dictionary(uniqueKeysWithValues: try library.items().map { ($0.id, $0) })
        let targetFolder = target.flatMap { paths[$0] } ?? ""
        var claimed = Set<String>()
        return ids.compactMap { id -> Move? in
            guard let item = items[id] else { return nil }
            let home = Self.home(of: item, paths: paths)
            let homeID: Int64? = if case .collection(let h) = home { h } else { nil }
            let hasFile = home != .none
            let source: Int64? = viewing.flatMap { item.collectionIDs.contains($0) ? $0 : nil }
            // 보고 있는 컬렉션에서 참조(또는 PDF 없는 소속)면 소속만 옮긴다. 원본 자리로 옮기면 참조만 빠진다.
            if let source, !(hasFile && homeID == source) {
                guard source != target else { return nil }
                return Move(itemID: id, removeFrom: source, addTo: hasFile && target == homeID ? nil : target, file: nil, conflict: false)
            }
            if hasFile, let path = item.attachments.first {
                let alreadyThere = target == nil ? home == .top : homeID == target
                if alreadyThere { return nil }
                let name = (path as NSString).lastPathComponent
                let destination = targetFolder.isEmpty ? name : targetFolder + "/" + name
                let taken = fm.fileExists(atPath: url(destination).path) || claimed.contains(Self.key(destination))
                claimed.insert(Self.key(destination))
                return Move(itemID: id, removeFrom: homeID, addTo: target, file: (path, destination), conflict: taken)
            }
            // PDF 없는 논문을 컬렉션 밖에서 끌었을 때.
            let only = item.collectionIDs.count == 1 ? item.collectionIDs.first : nil
            guard only != target || target == nil else { return nil }
            return Move(itemID: id, removeFrom: only, addTo: target, file: nil, conflict: false)
        }
    }

    /// 계획대로 옮긴다. 겹치는 파일은 resolve로 정한다. 파일을 못 옮긴 논문은 DB도 그대로 두고 오류를 모아 던진다.
    @discardableResult
    public func perform(_ moves: [Move], resolve: (Move) -> Resolution) throws -> Int {
        guard moves.allSatisfy({ $0.file == nil }) || isDirectory(root) else { throw Failure.missingRoot(root) }
        var done = 0
        var errors: [Error] = []
        for move in moves {
            var newPath: String?
            if let file = move.file {
                let source = url(file.from)
                var destination = file.to
                if fm.fileExists(atPath: url(destination).path), Self.key(destination) != Self.key(file.from) {
                    switch resolve(move) {
                    case .skip: continue
                    case .keepBoth: destination = uniquePath(destination)
                    case .replace:
                        do {
                            try trash(url(destination))
                            // 바꿔 넣은 파일을 쓰던 다른 논문은 PDF를 잃는다.
                            try library.db.run("DELETE FROM attachments WHERE path = ? AND item_id != ?",
                                               [.text(destination), .int(move.itemID)])
                        } catch { errors.append(error); continue }
                    }
                }
                do {
                    try fm.createDirectory(at: url(destination).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: source, to: url(destination))
                } catch { errors.append(error); continue }
                newPath = destination
            }
            do {
                try library.db.transaction {
                    if let newPath, let old = move.file?.from {
                        try library.db.run("UPDATE attachments SET path = ? WHERE item_id = ? AND path = ?",
                                           [.text(newPath), .int(move.itemID), .text(old)])
                    }
                    try library.moveItem(move.itemID, from: move.removeFrom, to: move.addTo)
                }
                done += 1
            } catch {
                if let newPath, let old = move.file?.from { try? fm.moveItem(at: url(newPath), to: url(old)) }
                errors.append(error)
            }
        }
        if let first = errors.first { throw first }
        return done
    }

    /// "a/X.pdf"가 있으면 "a/X (2).pdf", "a/X (3).pdf" …
    public func uniquePath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension
        let base = (path as NSString).deletingPathExtension
        var n = 2
        var candidate = path
        while fm.fileExists(atPath: url(candidate).path) {
            candidate = "\(base) (\(n))" + (ext.isEmpty ? "" : "." + ext)
            n += 1
        }
        return candidate
    }

    /// 파일은 그대로 두고 target 컬렉션에 참조로 넣는다.
    public func addReferences(_ ids: [Int64], to target: Int64) throws {
        try library.db.transaction {
            for id in ids { try library.moveItem(id, from: nil, to: target) }
        }
    }

    /// 컬렉션에서 참조를 뺀다. 원본 자리인 논문은 건너뛴다(빼려면 다른 곳으로 옮긴다). 뺀 수를 돌려준다.
    @discardableResult
    public func removeReferences(_ ids: [Int64], from collection: Int64) throws -> Int {
        let paths = try currentPaths()
        let items = try library.items().filter { ids.contains($0.id) && $0.collectionIDs.contains(collection) }
        let removable = items.filter { Self.home(of: $0, paths: paths) != .collection(collection) }
        try library.db.transaction {
            for item in removable { try library.moveItem(item.id, from: collection, to: nil) }
        }
        return removable.count
    }

    // MARK: 맞추기

    public struct Report: Equatable {
        public var relinked = 0
        public var createdCollections = 0
        public var renamedCollections = 0
        public var deletedCollections = 0
        public var createdFolders = 0
        public var homesAdded = 0
        /// 라이브러리에 없는 PDF(workspace 기준 경로).
        public var newFiles: [String] = []

        public init(newFiles: [String] = []) { self.newFiles = newFiles }

        public var changed: Bool {
            relinked + createdCollections + renamedCollections + deletedCollections + createdFolders + homesAdded > 0
        }
    }

    /// 폴더 트리와 DB를 맞춘다(§10.2). createMissingFolders면 폴더가 없는 컬렉션은 지우지 않고 폴더를 만든다(처음 쓸 때).
    public func reconcile(createMissingFolders: Bool = false) throws -> Report {
        guard isDirectory(root) else { throw Failure.missingRoot(root) }
        let (folders, pdfs) = try scan()
        let folderByKey = Dictionary(folders.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })
        var report = Report()
        try library.db.transaction {
            let initialPaths = try currentPaths()
            let pathToID = Dictionary(initialPaths.map { (Self.key($0.value), $0.key) }, uniquingKeysWith: { a, _ in a })

            // 1. 경로에 없는 PDF: 같은 이름의 새 파일이 하나면 그리로 옮긴 것으로 본다.
            let attachments = try library.db.query("SELECT id, item_id, path FROM attachments WHERE path NOT LIKE '/%'")
            let linked = Set(attachments.compactMap { $0["path"] }.map(Self.key))
            var unlinked = pdfs.filter { !linked.contains(Self.key($0)) }
            var byName = Dictionary(grouping: unlinked) { Self.key(($0 as NSString).lastPathComponent) }
            var moves: [(old: String, new: String)] = []
            var oldHomes: [Int64: Int64] = [:]
            for row in attachments {
                guard let id = row.int("id"), let item = row.int("item_id"), let path = row["path"],
                      !fm.fileExists(atPath: url(path).path) else { continue }
                let name = Self.key((path as NSString).lastPathComponent)
                guard let candidates = byName[name], candidates.count == 1 else { continue }
                let found = candidates[0]
                byName[name] = []
                unlinked.removeAll { $0 == found }
                try library.db.run("UPDATE attachments SET path = ? WHERE id = ?", [.text(found), .int(id)])
                let oldFolder = Self.folder(of: path) ?? ""
                moves.append((oldFolder, Self.folder(of: found) ?? ""))
                if let old = pathToID[Self.key(oldFolder)] { oldHomes[item] = old }
                report.relinked += 1
            }

            // 2. 폴더가 사라진 컬렉션: 이름을 바꾼 것이면 따라가고, 아니면 지운다. 얕은 것부터.
            let order = initialPaths.sorted { $0.value.split(separator: "/").count < $1.value.split(separator: "/").count }.map(\.key)
            for id in order {
                let paths = try currentPaths()
                guard let path = paths[id], folderByKey[Self.key(path)] == nil else { continue }
                if createMissingFolders {
                    try fm.createDirectory(at: url(path), withIntermediateDirectories: true)
                    report.createdFolders += 1
                } else if let renamed = renameTarget(of: path, moves: moves, folders: folders, paths: paths) {
                    let parentPath = Self.folder(of: renamed) ?? ""
                    let parent = parentPath.isEmpty ? nil : try ensureCollection(parentPath, report: &report)
                    try library.setCollection(id, name: (renamed as NSString).lastPathComponent, parent: .some(parent))
                    report.renamedCollections += 1
                } else {
                    try library.db.run("DELETE FROM collections WHERE id = ?", [.int(id)])
                    report.deletedCollections += 1
                }
            }

            // 3. 컬렉션이 없는 폴더는 컬렉션으로.
            for folder in folders.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
                _ = try ensureCollection(folder, report: &report)
            }

            // 4. 원본 자리 소속: PDF가 있는 폴더의 컬렉션에 넣고, 옮겨 온 논문은 예전 원본 자리에서 뺀다.
            let paths = try currentPaths()
            let finalIDs = Dictionary(paths.map { (Self.key($0.value), $0.key) }, uniquingKeysWith: { a, _ in a })
            for item in try library.items() {
                guard let first = item.attachments.first, let folder = Self.folder(of: first), !folder.isEmpty,
                      let home = finalIDs[Self.key(folder)] else {
                    if let old = oldHomes[item.id], item.collectionIDs.contains(old) {
                        try library.moveItem(item.id, from: old, to: nil)
                    }
                    continue
                }
                if !item.collectionIDs.contains(home) {
                    try library.db.run("INSERT OR IGNORE INTO collection_items (collection_id, item_id) VALUES (?,?)", [.int(home), .int(item.id)])
                    report.homesAdded += 1
                }
                if let old = oldHomes[item.id], old != home, item.collectionIDs.contains(old) {
                    try library.db.run("DELETE FROM collection_items WHERE collection_id = ? AND item_id = ?", [.int(old), .int(item.id)])
                }
            }
            report.newFiles = unlinked.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return report
    }

    /// 사라진 컬렉션 폴더 path가 어디로 갔는지: 안의 PDF가 함께 옮겨 간 폴더, 또는 같은 부모 아래 하나뿐인 새 폴더.
    private func renameTarget(of path: String, moves: [(old: String, new: String)], folders: [String], paths: [Int64: String]) -> String? {
        let taken = Set(paths.values.map(Self.key))
        let isFree = { (folder: String) in !taken.contains(Self.key(folder)) && folders.contains { Self.key($0) == Self.key(folder) } }
        let k = Self.key(path)
        var targets = Set<String>()
        for move in moves {
            let old = Self.key(move.old)
            guard old == k || old.hasPrefix(k + "/") else { continue }
            let suffix = String(move.old.dropFirst(path.count))
            guard move.new.count >= suffix.count, Self.key(String(move.new.suffix(suffix.count))) == Self.key(suffix) else { continue }
            targets.insert(String(move.new.dropLast(suffix.count)))
        }
        if targets.count == 1, let target = targets.first, isFree(target) { return target }
        guard targets.isEmpty else { return nil }
        let parent = Self.key(Self.folder(of: path) ?? "")
        let newSiblings = folders.filter { Self.key(Self.folder(of: $0) ?? "") == parent && !taken.contains(Self.key($0)) }
        let folderKeys = Set(folders.map(Self.key))
        let missingSiblings = paths.values.filter { Self.key(Self.folder(of: $0) ?? "") == parent && !folderKeys.contains(Self.key($0)) }
        return newSiblings.count == 1 && missingSiblings.count == 1 ? newSiblings[0] : nil
    }

    /// 폴더 경로에 맞는 컬렉션을 찾고, 없으면 부모부터 만든다.
    private func ensureCollection(_ path: String, report: inout Report) throws -> Int64 {
        var parent: Int64?
        var collections = try library.collections()
        for name in path.split(separator: "/").map(String.init) {
            if let found = collections.first(where: { $0.parentID == parent && Self.key($0.name) == Self.key(name) }) {
                parent = found.id
            } else {
                parent = try library.insertCollection(name: name, parent: parent)
                collections = try library.collections()
                report.createdCollections += 1
            }
        }
        return parent!
    }

    /// workspace 안의 폴더와 PDF(숨은 파일 제외), workspace 기준 경로로.
    private func scan() throws -> (folders: [String], pdfs: [String]) {
        var failure: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { _, error in failure = error; return false }) else {
            throw Failure.scanFailed(root.path)
        }
        var folders: [String] = [], pdfs: [String] = []
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents.count
        for case let file as URL in enumerator {
            let parts = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard parts.count > base else { continue }
            let relative = parts[base...].joined(separator: "/")
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                folders.append(relative)
            } else if file.pathExtension.lowercased() == "pdf" {
                pdfs.append(relative)
            }
        }
        if let failure { throw Failure.scanFailed(failure.localizedDescription) }
        return (folders, pdfs)
    }
}

extension Library {
    public func insertCollection(name: String, parent: Int64?) throws -> Int64 {
        try db.run("INSERT INTO collections (key, parent_id, name) VALUES (?,?,?)", [.text(UUID().uuidString), SQLValue(parent), .text(name)])
        return db.lastInsertID
    }

    /// 이름을 바꾸고, parent를 주면 부모도 바꾼다(.some(nil)이면 맨 위로).
    public func setCollection(_ id: Int64, name: String, parent: Int64?? = nil) throws {
        if let parent {
            try db.run("UPDATE collections SET name = ?, parent_id = ? WHERE id = ?", [.text(name), SQLValue(parent), .int(id)])
        } else {
            try db.run("UPDATE collections SET name = ? WHERE id = ?", [.text(name), .int(id)])
        }
    }

    /// 폴더 이름을 바꾼 뒤 그 안의 PDF 경로를 고친다.
    public func replacePathPrefix(_ old: String, with new: String) throws {
        for row in try db.query("SELECT id, path FROM attachments WHERE path NOT LIKE '/%'") {
            guard let id = row.int("id"), let path = row["path"],
                  Workspace.key(path).hasPrefix(Workspace.key(old) + "/") else { continue }
            try db.run("UPDATE attachments SET path = ? WHERE id = ?", [.text(new + path.dropFirst(old.count)), .int(id)])
        }
    }
}
