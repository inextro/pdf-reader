import AppKit
import CoreServices
import PaperMarkLibrary

/// workspace(라이브러리 폴더)와 DB를 맞춘다. 켤 때와 폴더가 바뀔 때(FSEvents) 맞추고,
/// 컬렉션 편집·논문 옮기기를 파일과 함께 한다(docs/library-design.md §10).
extension LibraryStore {
    static let newFilesDidChange = Notification.Name("LibraryStoreNewFilesDidChange")

    var workspace: Workspace? {
        guard let library, let folder else { return nil }
        return Workspace(library: library, root: folder)
    }

    /// 컬렉션 id → workspace 기준 폴더 경로.
    var collectionPaths: [Int64: String] { Workspace.paths(of: collections) }

    /// 이 컬렉션에서 참조로 보이는가(원본 PDF가 다른 폴더에 있다).
    func isReference(_ item: LibraryEntry, in collection: Int64) -> Bool {
        Workspace.isReference(item, in: collection, paths: collectionPaths)
    }

    func folderURL(of collection: Int64) -> URL? {
        guard let folder, let path = collectionPaths[collection] else { return nil }
        return folder.appendingPathComponent(path, isDirectory: true)
    }

    // MARK: 맞추기

    /// 켤 때 부른다: 한 번 맞추고 폴더를 감시한다.
    func startWorkspaceSync() {
        reconcileWorkspace()
        watchWorkspace()
    }

    /// 폴더와 DB를 맞춘다. 이 workspace를 처음 쓰면 DB를 백업하고, 폴더가 없는 컬렉션은 지우지 않고 폴더를 만든다.
    func reconcileWorkspace() {
        guard !isImporting, let library, let folder else { return }
        let adoptedKey = "workspaceAdopted"
        let first = UserDefaults.standard.string(forKey: adoptedKey) != folder.path
        if first { backupBeforeAdopting(library) }
        do {
            let report = try Workspace(library: library, root: folder).reconcile(createMissingFolders: first)
            if first { UserDefaults.standard.set(folder.path, forKey: adoptedKey) }
            if report.changed {
                NSLog("PaperLibrary workspace: \(report)")
                didModify()
            }
            if report.newFiles != newFiles {
                newFiles = report.newFiles
                NotificationCenter.default.post(name: Self.newFilesDidChange, object: self)
            }
        } catch Workspace.Failure.missingRoot {
            // Drive가 꺼져 있거나 폴더 이름이 바뀌었다. 아무것도 바꾸지 않는다.
        } catch {
            NSLog("PaperLibrary workspace reconcile failed: \(error)")
        }
    }

    private func backupBeforeAdopting(_ library: Library) {
        let backup = Self.databaseURL.deletingLastPathComponent()
            .appendingPathComponent("library-before-workspace-\(Int(Date().timeIntervalSince1970)).sqlite")
        try? library.db.execute("VACUUM INTO '\(backup.path.replacingOccurrences(of: "'", with: "''"))'")
    }

    /// workspace 폴더를 FSEvents로 감시한다. 바뀌면 잠깐 기다렸다가 한 번 맞춘다(여러 변경을 묶는다).
    func watchWorkspace() {
        if let stream = watcher {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            watcher = nil
        }
        guard let folder else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<LibraryStore>.fromOpaque(info).takeUnretainedValue()
            store.scheduleReconcile()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        watcher = stream
    }

    private func scheduleReconcile() {
        reconcileTimer?.invalidate()
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.reconcileWorkspace() }
    }

    // MARK: 컬렉션 편집

    func createCollection(_ name: String, parent: Int64?) throws -> Int64 {
        guard let workspace else { throw Workspace.Failure.missingRoot(folder ?? URL(fileURLWithPath: "/")) }
        let id = try workspace.createCollection(name, parent: parent)
        didModify()
        return id
    }

    func renameCollection(_ id: Int64, to name: String) throws {
        guard let workspace else { return }
        try workspace.renameCollection(id, to: name)
        didModify()
    }

    func deleteCollection(_ id: Int64) throws {
        guard let workspace else { return }
        try workspace.deleteCollection(id)
        didModify()
    }

    func deleteItems(_ ids: [Int64]) throws {
        guard let workspace else { return }
        try workspace.deleteItems(ids)
        didModify()
    }

    // MARK: 옮기기와 참조

    /// 논문들을 target(nil이면 Unfiled)으로 옮긴다. 같은 이름의 파일이 있으면 alert로 묻는다.
    func move(_ ids: [Int64], viewing: Int64?, to target: Int64?, in window: NSWindow?) {
        guard let workspace else { return }
        do {
            let moves = try workspace.planMove(ids, viewing: viewing, to: target)
            guard !moves.isEmpty else { return }
            var remembered: Workspace.Resolution?
            let conflicts = moves.filter(\.conflict).count
            try workspace.perform(moves) { move in
                if let remembered { return remembered }
                let (choice, applyToAll) = askConflict(move, others: conflicts - 1, in: window)
                if applyToAll { remembered = choice }
                return choice
            }
        } catch {
            presentError(error, in: window)
        }
        didModify()
    }

    func addReferences(_ ids: [Int64], to target: Int64, in window: NSWindow?) {
        guard let workspace else { return }
        do { try workspace.addReferences(ids, to: target) } catch { presentError(error, in: window) }
        didModify()
    }

    func removeReferences(_ ids: [Int64], from collection: Int64, in window: NSWindow?) {
        guard let workspace else { return }
        do { try workspace.removeReferences(ids, from: collection) } catch { presentError(error, in: window) }
        didModify()
    }

    /// 같은 이름의 파일이 있을 때: 교체 / 둘 다 유지 / 건너뛰기. 겹치는 것이 더 있으면 "모두에 적용"을 보인다.
    private func askConflict(_ move: Workspace.Move, others: Int, in window: NSWindow?) -> (Workspace.Resolution, Bool) {
        let alert = NSAlert()
        let name = ((move.file?.to ?? "") as NSString).lastPathComponent
        let folder = Workspace.folder(of: move.file?.to ?? "").map { $0.isEmpty ? "the workspace" : "“\($0)”" } ?? ""
        alert.messageText = "“\(name)” already exists in \(folder)."
        alert.informativeText = "Replace moves the existing file to the Trash. Keep Both adds a number to the moved file’s name."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        if others > 0 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to the other \(others) conflict\(others == 1 ? "" : "s")"
        }
        let response = alert.runModal()
        let choice: Workspace.Resolution = switch response {
        case .alertFirstButtonReturn: .keepBoth
        case .alertSecondButtonReturn: .replace
        default: .skip
        }
        return (choice, alert.suppressionButton?.state == .on)
    }

    func presentError(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Unlinked PDFs

    /// 라이브러리에 없는 PDF를 논문으로 넣는다. 이름은 파일 이름으로 두고, 첫 쪽의 DOI·arXiv 번호로 서지 정보를 채운다.
    func addNewFiles(_ paths: [String]) -> [Int64] {
        guard let library, let folder else { return [] }
        var added: [Int64] = []
        for path in paths {
            var metadata = PaperMetadata()
            metadata.title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            do {
                let id = try library.add(metadata, citationKey: nil, collectionID: nil)
                try library.addAttachment(path, to: id)
                try library.addTag(Self.newItemTag, to: id)
                added.append(id)
                fillMetadata(of: id, from: Library.resolve(path, in: folder))
            } catch {
                NSLog("PaperLibrary add new file failed: \(error)")
            }
        }
        reconcileWorkspace()
        didModify()
        return added
    }

    private func fillMetadata(of id: Int64, from file: URL) {
        guard let data = try? Data(contentsOf: file), let found = Connector.identify(data) else { return }
        Task { @MainActor in
            let (metadata, _) = await MetadataLookup.complete(found, options: Settings.lookup)
            guard let library = self.library, !metadata.title.isEmpty else { return }
            let key = Naming.citationKey(pattern: Settings.citationKeyPattern, metadata: metadata, taken: (try? library.citationKeys()) ?? [])
            try? library.update(id, with: metadata, citationKey: key)
            self.didModify()
        }
    }
}
