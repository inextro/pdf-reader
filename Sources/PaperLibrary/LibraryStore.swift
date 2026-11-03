import AppKit
import CoreServices
import PaperMarkLibrary

/// 앱 전체가 같이 쓰는 라이브러리. 항목은 한 번에 읽어 두고, 가져오기가 끝나면 다시 읽어 didChange를 알린다.
final class LibraryStore {
    static let shared = LibraryStore()
    static let didChange = Notification.Name("LibraryStoreDidChange")
    private static let folderKey = "libraryFolder"

    private(set) var library: Library?
    private(set) var loadError: Error?
    private(set) var items: [LibraryEntry] = []
    private(set) var collections: [LibraryCollection] = []
    private(set) var tags: [String] = []
    /// 첫 PDF가 디스크에 없는 항목.
    private(set) var missingPDF: Set<Int64> = []
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
        do { try LibraryBackup.write(library, to: folder) } catch { NSLog("PaperLibrary backup failed: \(error)") }
    }

    /// 서지 정보로 항목을 만든다. 같은 논문이 이미 있으면 만들지 않고 그 항목을 돌려준다. 다시 읽기·백업은 부르는 쪽이 한다.
    func addPaper(_ metadata: PaperMetadata, to collection: Int64?) throws -> (id: Int64, existing: Bool) {
        guard let library else { throw loadError ?? CocoaError(.fileReadUnknown) }
        if let id = try library.existingItem(for: metadata) { return (id, true) }
        let key = Naming.citationKey(pattern: Settings.citationKeyPattern, metadata: metadata, taken: try library.citationKeys())
        let id = try library.add(metadata, citationKey: key, collectionID: collection)
        try library.addTag(Self.newItemTag, to: id)
        return (id, false)
    }

    /// 새로 넣은 논문(확장, 식별자로 추가, Unlinked PDFs)에 붙이는 태그.
    static let newItemTag = "/To Do"

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

    func importFromZotero(in window: NSWindow?) {
        guard !isImporting else { return }
        if let loadError { present(alert("Library could not be opened.", loadError.localizedDescription), in: window); return }
        chooseZoteroDatabase(in: window) { zotero in
            self.confirmZoteroQuit(in: window) {
                let base = ZoteroImport.attachmentBase()
                self.chooseFolder(default: self.folder ?? base, in: window) { folder in
                    self.runImport(zotero: zotero, base: base, folder: folder, in: window)
                }
            }
        }
    }

    private func chooseZoteroDatabase(in window: NSWindow?, then next: @escaping (URL) -> Void) {
        let standard = ZoteroImport.defaultDatabase
        if FileManager.default.fileExists(atPath: standard.path) { next(standard); return }
        let panel = NSOpenPanel()
        panel.message = "Choose zotero.sqlite in your Zotero data folder."
        panel.allowedContentTypes = [.init(filenameExtension: "sqlite")].compactMap { $0 }
        begin(panel, in: window) { next($0) }
    }

    /// Zotero가 켜져 있으면 아직 파일에 쓰지 않은 최근 변경을 못 읽을 수 있다고 알린다.
    private func confirmZoteroQuit(in window: NSWindow?, then next: @escaping () -> Void) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "org.zotero.zotero").isEmpty else {
            next(); return
        }
        let warning = alert("Zotero is open.",
                            "The most recent changes in Zotero may be missed. Quit Zotero first to import everything.")
        warning.addButton(withTitle: "Import Anyway")
        warning.addButton(withTitle: "Cancel")
        present(warning, in: window) { if $0 == .alertFirstButtonReturn { next() } }
    }

    /// 라이브러리 폴더를 아직 정하지 않았고 Zotero 첨부 폴더도 모르면 묻는다.
    private func chooseFolder(default folder: URL?, in window: NSWindow?, then next: @escaping (URL) -> Void) {
        if let folder { next(folder); return }
        let panel = NSOpenPanel()
        panel.message = "Choose the folder that holds your PDFs (Zotero's linked attachment base directory)."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = Self.googleDriveFolder()
        begin(panel, in: window) { next($0) }
    }

    private func runImport(zotero: URL, base: URL?, folder: URL, in window: NSWindow?) {
        isImporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            // 연결은 스레드마다 따로 쓴다. 다 끝나면 메인 스레드의 연결로 다시 읽는다.
            let outcome = Result<(ZoteroImport.Result, Error?), Error> {
                let library = try Library(url: Self.databaseURL)
                let result = try ZoteroImport.run(zotero: zotero, attachmentBase: base, libraryFolder: folder, into: library)
                do { try LibraryBackup.write(library, to: folder); return (result, nil) } catch { return (result, error) }
            }
            DispatchQueue.main.async {
                self.isImporting = false
                switch outcome {
                case .success(let (result, backupError)):
                    self.folder = folder
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
                    self.present(self.alert("Imported from Zotero", lines.joined(separator: "\n")), in: window)
                case .failure(let error):
                    self.present(self.alert("Import failed.", error.localizedDescription), in: window)
                }
            }
        }
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

    private func begin(_ panel: NSOpenPanel, in window: NSWindow?, then next: @escaping (URL) -> Void) {
        let handler = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url { next(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }
}
