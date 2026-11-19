import AppKit
import CoreServices
import PaperMarkLibrary

/// 앱 전체가 같이 쓰는 라이브러리. 항목은 한 번에 읽어 두고, 가져오기가 끝나면 다시 읽어 didChange를 알린다.
final class LibraryStore {
    static let shared = LibraryStore()
    /// 라이브러리 창의 되돌리기(⌘Z). 논문·컬렉션 지우기를 되살린다.
    let undoManager = UndoManager()
    static let didChange = Notification.Name("LibraryStoreDidChange")
    private static let folderKey = "libraryFolder"

    private(set) var library: Library?
    private(set) var loadError: Error?
    private(set) var items: [LibraryEntry] = []
    private(set) var collections: [LibraryCollection] = []
    private(set) var tags: [String] = []
    /// 첫 PDF가 디스크에 없는 항목.
    private(set) var missingPDF: Set<Int64> = []
    /// 항목 id → 같은 논문으로 보이는 다른 항목 id들(사이드바 Duplicates, 정보 패널 알림).
    private(set) var duplicates: [Int64: Set<Int64>] = [:]
    private(set) var isImporting = false
    /// workspace 안에 있지만 라이브러리에 없는 PDF(workspace 기준 경로). 사이드바 Unlinked PDFs에 보인다.
    var newFiles: [String] = []
    /// 사이드바에서 고른 컬렉션(All Items 등이면 nil). 확장으로 저장한 논문은 여기에 들어간다.
    var selectedCollection: Int64? {
        get { _selectedCollection.flatMap { c in collections.contains { $0.id == c } ? c : nil } }
        set { _selectedCollection = newValue }
    }
    private var _selectedCollection: Int64?
    var watcher: FSEventStreamRef?
    var reconcileTimer: Timer?

    /// PDF가 있는 폴더(Drive). DB의 PDF 경로는 이 폴더 기준이다. 처음 가져올 때 Zotero 첨부 폴더로 정한다.
    var folder: URL? {
        get { UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: Self.folderKey)
            reload()
            reconcileWorkspace()
            watchWorkspace()
        }
    }

    /// DB 위치. 숨은 설정 `libraryDatabase`로 바꿀 수 있다(시험할 때 실제 라이브러리를 건드리지 않게).
    static var databaseURL: URL {
        UserDefaults.standard.string(forKey: "libraryDatabase").map { URL(fileURLWithPath: $0) } ?? Library.defaultURL
    }

    private init() {
        do { library = try Library(url: Self.databaseURL) } catch { loadError = error }
        load()
    }

    func reload() {
        load()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// PaperLibrary에서 항목을 고친 뒤: 다시 읽어 알리고 Drive의 백업을 새로 쓴다.
    func didModify() {
        reload()
        guard let library, let folder else { return }
        do { try LibraryBackup.write(library, to: folder) } catch { NSLog("%@", "PaperLibrary backup failed: \(error)") }
    }

    /// 서지 정보로 항목을 만든다. 같은 논문이 이미 있으면 만들지 않고 그 항목을 돌려준다. 다시 읽기·백업은 부르는 쪽이 한다.
    func addPaper(_ metadata: PaperMetadata, to collection: Int64?) throws -> (id: Int64, existing: Bool) {
        guard let library else { throw loadError ?? CocoaError(.fileReadUnknown) }
        if let id = try library.existingItem(for: metadata) { return (id, true) }
        let key = Naming.citationKey(pattern: Settings.citationKeyPattern, metadata: metadata, taken: try library.citationKeys())
        let id = try library.add(metadata, citationKey: key, collectionID: collection)
        if let tag = Self.newItemTag { try library.addTag(tag, to: id) }
        return (id, false)
    }

    /// 새로 넣은 논문(확장, 식별자로 추가, Unlinked PDFs)에 붙이는 태그: 첫 읽기 상태.
    static var newItemTag: String? { Settings.statusTags.first }

    /// 정보 패널에서 고친 서지 정보를 저장한다.
    func editItem(_ id: Int64, to metadata: PaperMetadata, citationKey: String?) throws {
        guard let library else { throw loadError ?? CocoaError(.fileReadUnknown) }
        try library.edit(id, to: metadata, citationKey: citationKey)
        didModify()
    }

    // MARK: 태그

    /// 읽기 상태를 바꾼다: 다른 상태 태그를 떼고 tag를 붙인다. nil이면 상태 태그를 모두 뗀다.
    func setStatus(_ tag: String?, of ids: [Int64]) throws {
        guard let library else { throw loadError ?? CocoaError(.fileReadUnknown) }
        try library.setTag(tag, of: ids, removing: Settings.statusTags)
        didModify()
    }

    /// 이름이 이미 있으면 그 태그를 쓴다. 상태 목록에 넣으면 Status ▸에도 보인다.
    func createTag(_ name: String, asStatus: Bool) throws {
        guard let library else { throw loadError ?? CocoaError(.fileReadUnknown) }
        try library.tagID(name)
        if asStatus, !Settings.statusTags.contains(where: { Library.tagKey($0) == Library.tagKey(name) }) {
            Settings.statusTags.append(name)
        }
        didModify()
    }

    /// 태그 이름을 바꾼다. Zotero에서 가져온 "/" 앞붙임은 그대로 둔다. 상태 목록의 이름도 함께 바꾼다.
    @discardableResult
    func renameTag(_ old: String, to name: String) throws -> String {
        guard let library else { throw loadError ?? CocoaError(.fileReadUnknown) }
        let new = old.hasPrefix("/") && !name.hasPrefix("/") ? "/" + name : name
        try library.renameTag(old, to: new)
        var statuses = Settings.statusTags.map { Library.tagKey($0) == Library.tagKey(old) ? new : $0 }
        statuses = statuses.enumerated().filter { i, tag in !statuses[..<i].contains { Library.tagKey($0) == Library.tagKey(tag) } }.map(\.element)
        Settings.statusTags = statuses
        didModify()
        return tags.first { Library.tagKey($0) == Library.tagKey(new) } ?? new
    }

    func deleteTag(_ name: String) throws {
        guard let library else { throw loadError ?? CocoaError(.fileReadUnknown) }
        try library.deleteTag(name)
        Settings.statusTags.removeAll { Library.tagKey($0) == Library.tagKey(name) }
        didModify()
    }

    /// 지금 패턴으로 citation key를 새로 짓는다(Zotero에서 가져온 key 등).
    func regenerateCitationKeys(of items: [LibraryEntry]) throws {
        guard let library else { throw loadError ?? CocoaError(.fileReadUnknown) }
        var taken = try library.citationKeys().subtracting(items.compactMap(\.citationKey))
        for item in items {
            let key = Naming.citationKey(pattern: Settings.citationKeyPattern, metadata: PaperMetadata(item), taken: taken)
            taken.insert(key)
            try library.setCitationKey(key, of: item.id)
        }
        didModify()
    }

    /// 알림 없이 읽는다. init 중에 알리면 받는 쪽이 아직 다 만들어지지 않은 `shared`를 다시 불러 멈춘다.
    private func load() {
        guard let library else { return }
        do {
            items = try library.items()
            collections = try library.collections()
            tags = try library.tags()
        } catch {
            loadError = error
        }
        duplicates = Duplicates.find(items)
        missingPDF = Set(items.filter { item in
            pdfURL(of: item).map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        }.map(\.id))
    }

    func pdfURL(of item: LibraryEntry) -> URL? {
        guard let path = item.attachments.first else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return folder.map { Library.resolve(path, in: $0) }
    }

    func notes(of item: LibraryEntry) -> [String] { (try? library?.notes(of: item.id)) ?? [] }

    /// PDF가 없는 항목에서 대신 열 웹 주소(DOI, 없으면 URL).
    func webURL(of item: LibraryEntry) -> URL? {
        if let doi = item.doi, !doi.isEmpty { return URL(string: "https://doi.org/\(doi)") }
        return item.url.flatMap(URL.init(string:))
    }

    // MARK: Zotero 가져오기

    /// finished: 가져오기를 마치거나 도중에 취소하면 부른다(처음 켤 때 workspace를 정했는지 다시 보려고).
    func importFromZotero(in window: NSWindow?, finished: @escaping () -> Void = {}) {
        guard !isImporting else { return }
        if let loadError {
            present(alert("Library could not be opened.", loadError.localizedDescription), in: window) { _ in finished() }
            return
        }
        chooseZoteroDatabase(in: window, cancelled: finished) { zotero in
            self.confirmZoteroQuit(in: window, cancelled: finished) {
                let base = ZoteroImport.attachmentBase()
                self.chooseFolder(default: self.folder ?? base, in: window, cancelled: finished) { folder in
                    self.runImport(zotero: zotero, base: base, folder: folder, in: window, finished: finished)
                }
            }
        }
    }

    private func chooseZoteroDatabase(in window: NSWindow?, cancelled: @escaping () -> Void, then next: @escaping (URL) -> Void) {
        let standard = ZoteroImport.defaultDatabase
        if FileManager.default.fileExists(atPath: standard.path) { next(standard); return }
        let panel = NSOpenPanel()
        panel.message = "Choose zotero.sqlite in your Zotero data folder."
        panel.allowedContentTypes = [.init(filenameExtension: "sqlite")].compactMap { $0 }
        begin(panel, in: window, cancelled: cancelled) { next($0) }
    }

    /// Zotero가 켜져 있으면 아직 파일에 쓰지 않은 최근 변경을 못 읽을 수 있다고 알린다.
    private func confirmZoteroQuit(in window: NSWindow?, cancelled: @escaping () -> Void, then next: @escaping () -> Void) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "org.zotero.zotero").isEmpty else {
            next(); return
        }
        let warning = alert("Zotero is open.",
                            "The most recent changes in Zotero may be missed. Quit Zotero first to import everything.")
        warning.addButton(withTitle: "Import Anyway")
        warning.addButton(withTitle: "Cancel")
        present(warning, in: window) { if $0 == .alertFirstButtonReturn { next() } else { cancelled() } }
    }

    /// 라이브러리 폴더를 아직 정하지 않았고 Zotero 첨부 폴더도 모르면 묻는다.
    private func chooseFolder(default folder: URL?, in window: NSWindow?, cancelled: @escaping () -> Void, then next: @escaping (URL) -> Void) {
        if let folder { next(folder); return }
        let panel = NSOpenPanel()
        panel.message = "Choose the folder that holds your PDFs (Zotero's linked attachment base directory)."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = Self.googleDriveFolder()
        begin(panel, in: window, cancelled: cancelled) { next($0) }
    }

    private func runImport(zotero: URL, base: URL?, folder: URL, in window: NSWindow?, finished: @escaping () -> Void) {
        isImporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            // 연결은 스레드마다 따로 쓴다. 다 끝나면 메인 스레드의 연결로 다시 읽는다.
            let outcome = Result<(ZoteroImport.Result, Error?), Error> {
                let library = try Library(url: Self.databaseURL)
                let result = try ZoteroImport.run(zotero: zotero, attachmentBase: base, libraryFolder: folder, into: library)
                try library.normalizeItems()
                do { try LibraryBackup.write(library, to: folder); return (result, nil) } catch { return (result, error) }
            }
            DispatchQueue.main.async {
                self.isImporting = false
                switch outcome {
                case .success(let (result, backupError)):
                    self.folder = folder
                    self.fillArticleNumbers(force: true)
                    var lines = ["\(result.items) papers, \(result.attachments) PDFs, \(result.collections) collections, "
                                 + "\(result.tags) tags, \(result.notes) notes."]
                    if result.removed > 0 { lines.append("\(result.removed) papers deleted in Zotero were removed.") }
                    if result.skippedAttachments > 0 {
                        lines.append("\(result.skippedAttachments) attachments stored inside Zotero (not linked PDFs) were skipped.")
                    }
                    if result.unresolvedAttachments > 0 {
                        lines.append("\(result.unresolvedAttachments) PDFs were skipped because Zotero's attachment folder is unknown.")
                    }
                    if !self.missingPDF.isEmpty { lines.append("\(self.missingPDF.count) PDFs are not in \(folder.path).") }
                    if let backupError { lines.append("Backup failed: \(backupError.localizedDescription)") }
                    self.present(self.alert("Imported from Zotero", lines.joined(separator: "\n")), in: window) { _ in finished() }
                case .failure(let error):
                    self.present(self.alert("Import failed.", error.localizedDescription), in: window) { _ in finished() }
                }
            }
        }
    }

    // MARK: 백업에서 되살리기

    /// 서재가 비었는데 workspace의 백업에 논문이 있으면(DB를 잃었거나 새 Mac) 되살릴지 묻는다. 켤 때 본다.
    func offerRestoreIfEmpty(in window: NSWindow?, then done: @escaping () -> Void) {
        guard library != nil, items.isEmpty, let folder,
              let file = try? LibraryBackup.read(from: folder), !file.items.isEmpty else { done(); return }
        let ask = alert("Restore your library from the backup?",
                        "The library on this Mac is empty, but your workspace has a backup (\(LibraryBackup.fileName)) "
                        + "from \(Self.describe(file.exportedAt)) with \(Self.summary(file)).")
        ask.addButton(withTitle: "Restore")
        ask.addButton(withTitle: "Not Now")
        present(ask, in: window) { response in
            guard response == .alertFirstButtonReturn else { done(); return }
            self.restore(file, in: window, then: done)
        }
    }

    /// File → Restore Library from Backup…: 지금 백업이나 날짜별 사본을 골라 서재를 그 내용으로 바꾼다.
    func restoreFromBackup(in window: NSWindow?) {
        guard let folder else { return }
        // 고를 수 있는 백업: 지금 백업, 그리고 오늘보다 앞선 날짜별 사본(오늘 사본은 지금 백업과 같다).
        var choices: [(title: String, file: LibraryBackup.File)] = []
        var unreadable: Error?
        do {
            if let current = try LibraryBackup.read(from: folder) {
                choices.append(("Latest — \(Self.describe(current.exportedAt)) · \(current.items.count) papers", current))
            }
        } catch { unreadable = error }
        let today = LibraryBackup.day(of: URL(fileURLWithPath: LibraryBackup.dailyName(for: Date())))
        for url in LibraryBackup.dailyBackups(in: folder) where LibraryBackup.day(of: url) != today {
            guard let file = try? LibraryBackup.read(url) else { continue }
            choices.append(("\(Self.describe(file.exportedAt)) · \(file.items.count) papers", file))
        }
        guard !choices.isEmpty else {
            let text = unreadable?.localizedDescription ?? "There is no backup in \(LibraryBackup.backupFolder(in: folder).path)."
            present(alert(unreadable == nil ? "No backup found." : "The backup could not be read.", text), in: window)
            return
        }
        let ask = alert("Restore your library from a backup?",
                        "Quillo keeps the latest backup and one copy per day for the last \(LibraryBackup.dailyCopies) days "
                        + "you changed the library. The library on this Mac (\(items.count) papers) is replaced; a copy of it "
                        + "is kept in ~/Library/Application Support/PaperLibrary. PDFs and highlights are not changed.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        popup.addItems(withTitles: choices.map(\.title))
        ask.accessoryView = popup
        ask.addButton(withTitle: "Restore").hasDestructiveAction = true
        ask.addButton(withTitle: "Cancel")
        ask.addButton(withTitle: "Show in Finder")
        present(ask, in: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                self.restore(choices[max(popup.indexOfSelectedItem, 0)].file, in: window) {}
            case .alertThirdButtonReturn:
                let current = LibraryBackup.currentURL(in: folder)
                let target = FileManager.default.fileExists(atPath: current.path) ? current : folder
                NSWorkspace.shared.activateFileViewerSelecting([target])
            default:
                break
            }
        }
    }

    /// 지금 DB의 사본을 남기고 백업으로 바꾼 뒤 workspace와 맞춘다.
    func performRestore(_ file: LibraryBackup.File) throws -> LibraryBackup.RestoreResult {
        guard let library else { throw loadError ?? CocoaError(.fileReadUnknown) }
        let copy = Self.databaseURL.deletingLastPathComponent()
            .appendingPathComponent("library-before-restore-\(Int(Date().timeIntervalSince1970)).sqlite")
        try library.db.execute("VACUUM INTO '\(copy.path.replacingOccurrences(of: "'", with: "''"))'")
        let result = try LibraryBackup.restore(file, into: library)
        // 지우기 되돌리기는 예전 id를 가리키므로 버린다.
        undoManager.removeAllActions()
        // 폴더가 없는 컬렉션은 지우지 않고 폴더를 만든다(처음 쓰는 workspace처럼 맞춘다).
        UserDefaults.standard.removeObject(forKey: Self.adoptedKey)
        reload()
        reconcileWorkspace()
        return result
    }

    private func restore(_ file: LibraryBackup.File, in window: NSWindow?, then done: @escaping () -> Void) {
        do {
            let result = try performRestore(file)
            var lines = ["\(result.items) papers, \(result.collections) collections, \(result.tags) tags, \(result.notes) notes."]
            if !missingPDF.isEmpty { lines.append("\(missingPDF.count) PDFs are not in the workspace folder.") }
            present(alert("Library restored", lines.joined(separator: "\n")), in: window) { _ in done() }
        } catch {
            reload()
            present(alert("Restore failed.", error.localizedDescription), in: window) { _ in done() }
        }
    }

    private static func summary(_ file: LibraryBackup.File) -> String {
        "\(file.items.count) papers and \(file.collections.count) collections"
    }

    /// 백업의 exportedAt(UTC ISO 8601)을 이 Mac의 날짜 표기로.
    private static func describe(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    static func googleDriveFolder() -> URL? {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let drive = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix("GoogleDrive-") }) else { return nil }
        let myDrive = drive.appendingPathComponent("My Drive")
        return FileManager.default.fileExists(atPath: myDrive.path) ? myDrive : drive
    }

    // MARK: 창

    private func alert(_ title: String, _ text: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        return alert
    }

    private func present(_ alert: NSAlert, in window: NSWindow?, then done: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window { alert.beginSheetModal(for: window) { done?($0) } } else { done?(alert.runModal()) }
    }

    private func begin(_ panel: NSOpenPanel, in window: NSWindow?, cancelled: @escaping () -> Void = {}, then next: @escaping (URL) -> Void) {
        let handler = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url { next(url) } else { cancelled() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }
}
