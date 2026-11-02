import AppKit
import PDFKit
import PaperMarkLibrary

/// Chrome 확장(Extension/Chrome)의 요청을 받아 라이브러리에 논문을 넣는다. Zotero Connector처럼 동작한다.
///
/// 1. `POST /save`: 확장이 보낸 페이지 정보(주소, 메타태그, PDF 링크)로 서지 정보를 채워 항목을 만들고,
///    받아 볼 PDF 주소들을 돌려준다. 같은 논문이 이미 있으면 새로 만들지 않는다.
/// 2. `POST /attach?id=`: 확장이 브라우저 로그인 상태로 받은 PDF를 새 PDF 폴더에 저장하고 항목에 붙인다.
/// 3. `POST /collection`: 확장 팝업에서 고른 컬렉션으로 옮긴다. `GET /collections`: 고를 목록.
final class Connector {
    static let shared = Connector()
    static let statusDidChange = Notification.Name("ConnectorStatusDidChange")

    private var server: ConnectorServer?
    private(set) var status = "Not started"

    private struct Failure: LocalizedError {
        var status = 400
        var message: String
        var errorDescription: String? { message }
    }

    func start() {
        let port = Settings.connectorPort
        do {
            let server = try ConnectorServer(port: port) { request, reply in
                Task { @MainActor in reply(await self.handle(request)) }
            }
            server.start { [weak self] state in
                switch state {
                case .ready: self?.setStatus("Listening on 127.0.0.1:\(port)")
                case .failed(let error): self?.setStatus("Could not listen on port \(port): \(error.localizedDescription)")
                default: break
                }
            }
            self.server = server
        } catch {
            setStatus("Could not listen on port \(port): \(error.localizedDescription)")
        }
    }

    private func setStatus(_ text: String) {
        status = text
        NotificationCenter.default.post(name: Self.statusDidChange, object: self)
    }

    // MARK: 요청

    @MainActor
    private func handle(_ request: ConnectorServer.Request) async -> ConnectorServer.Response {
        // 웹 페이지의 스크립트가 보낸 요청은 받지 않는다. 확장이 보내면 Origin이 chrome-extension://이다.
        if let origin = request.headers["origin"], !origin.hasPrefix("chrome-extension://") {
            return .error(403, "Requests from web pages are not accepted.")
        }
        guard request.headers["x-paperlibrary"] == "1" else { return .error(403, "Missing X-PaperLibrary header.") }
        do {
            switch (request.method, request.path) {
            case ("GET", "/ping"):
                return .json(["app": "PaperLibrary", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev"])
            case ("GET", "/collections"):
                return .json(["collections": collectionList(), "selected": Settings.lastCollection.map { $0 as Any } ?? NSNull()])
            case ("POST", "/save"):
                return try await save(request.body)
            case ("POST", "/attach"):
                return try await attach(request)
            case ("POST", "/collection"):
                return try move(request.body)
            default:
                return .error(404, "Not found")
            }
        } catch let failure as Failure {
            return .error(failure.status, failure.message)
        } catch {
            return .error(400, error.localizedDescription)
        }
    }

    private struct Page: Decodable {
        var url: String
        var title: String?
        var meta: [[String]]?
        var links: [String]?
        var isPDF: Bool?
    }

    @MainActor
    private func save(_ body: Data) async throws -> ConnectorServer.Response {
        let store = LibraryStore.shared
        let page = try JSONDecoder().decode(Page.self, from: body)
        let isPDF = page.isPDF ?? false
        let meta = (page.meta ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        // PDF 탭의 제목은 파일 이름이라 쓰지 않는다. PDF를 받은 뒤 그 안에서 찾는다.
        let scraped = PaperMetadata.page(meta: meta, url: page.url, title: isPDF ? nil : page.title)
        var (metadata, warnings) = await MetadataLookup.complete(scraped, options: Settings.lookup)
        if metadata.title.isEmpty {
            metadata.title = URL(string: page.url)?.deletingPathExtension().lastPathComponent ?? page.url
        }

        _ = try openLibrary()
        let target = Settings.lastCollection.flatMap { c in store.collections.contains { $0.id == c } ? c : nil }
        let (id, existing) = try store.addPaper(metadata, to: target)
        let collection = existing ? nil : target
        store.didModify()
        guard let entry = store.items.first(where: { $0.id == id }) else { throw Failure(status: 500, message: "The paper was not saved.") }
        if Settings.pdfFolder == nil { warnings.append("Choose a folder for new PDFs in PaperLibrary Settings.") }
        var json = itemJSON(entry)
        json["existing"] = existing
        json["collection"] = collection.map { $0 as Any } ?? NSNull()
        json["pdfCandidates"] = entry.attachments.isEmpty
            ? PaperID.pdfCandidates(for: metadata, pageURL: page.url, isPDF: isPDF, links: page.links ?? []) : []
        json["warnings"] = warnings
        return .json(json)
    }

    @MainActor
    private func attach(_ request: ConnectorServer.Request) async throws -> ConnectorServer.Response {
        let store = LibraryStore.shared
        let library = try openLibrary()
        guard var id = request.query["id"].flatMap(Int64.init), var entry = store.items.first(where: { $0.id == id }) else {
            throw Failure(status: 404, message: "The paper is no longer in the library.")
        }
        guard request.body.starts(with: Data("%PDF-".utf8)) else { throw Failure(message: "The downloaded file is not a PDF.") }
        guard let folder = Settings.pdfFolder else { throw Failure(message: "Choose a folder for new PDFs in PaperLibrary Settings.") }

        // PDF만 보고 저장한 경우(PDF 탭): 첫 페이지의 DOI·arXiv 번호로 서지 정보를 다시 채운다.
        if entry.doi == nil && entry.arxivID == nil, let found = Self.identify(request.body) {
            let (metadata, _) = await MetadataLookup.complete(found, options: Settings.lookup)
            // 논문 페이지에서 PDF를 못 받아 PDF 탭에서 다시 누른 경우: 방금 만든 이름뿐인 항목 대신 원래 항목에 붙인다.
            if let original = try library.existingItem(for: metadata), original != id,
               let target = store.items.first(where: { $0.id == original }) {
                try library.deleteItem(id)
                (id, entry) = (original, target)
                if !target.attachments.isEmpty {
                    store.didModify()
                    var json = itemJSON(target)
                    json["existing"] = true
                    return .json(json)
                }
            } else if !metadata.creators.isEmpty {
                var taken = try library.citationKeys()
                if let old = entry.citationKey { taken.remove(old) }
                var merged = metadata
                merged.url = entry.url ?? metadata.url
                try library.update(id, with: merged,
                                   citationKey: Naming.citationKey(pattern: Settings.citationKeyPattern, metadata: merged, taken: taken))
                entry = try library.item(id) ?? entry
            }
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Naming.fileName(pattern: Settings.fileNamePattern, metadata: PaperMetadata(entry))
        var file = folder.appendingPathComponent(name + ".pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appendingPathComponent("\(name) (\(n)).pdf")
            n += 1
        }
        try request.body.write(to: file, options: .withoutOverwriting)
        if store.folder == nil { store.folder = folder }
        try library.addAttachment(Library.storedPath(for: file, in: store.folder ?? folder), to: id)
        store.didModify()
        guard let updated = store.items.first(where: { $0.id == id }) else { throw Failure(status: 500, message: "The PDF was not saved.") }
        var json = itemJSON(updated)
        json["file"] = file.lastPathComponent
        return .json(json)
    }

    private struct Move: Decodable {
        var id: Int64
        var from: Int64?
        var to: Int64?
    }

    @MainActor
    private func move(_ body: Data) throws -> ConnectorServer.Response {
        let library = try openLibrary()
        let move = try JSONDecoder().decode(Move.self, from: body)
        try library.moveItem(move.id, from: move.from, to: move.to)
        Settings.lastCollection = move.to
        LibraryStore.shared.didModify()
        return .json(["ok": true])
    }

    // MARK: 도움

    @MainActor
    private func openLibrary() throws -> Library {
        let store = LibraryStore.shared
        guard !store.isImporting else { throw Failure(status: 409, message: "PaperLibrary is importing from Zotero. Try again shortly.") }
        guard let library = store.library else {
            throw Failure(status: 500, message: "The library could not be opened: \(store.loadError?.localizedDescription ?? "")")
        }
        return library
    }

    private func itemJSON(_ entry: LibraryEntry) -> [String: Any] {
        let people = entry.authors.isEmpty ? entry.creators : entry.authors
        var authors = people.prefix(3).map { [$0.given, $0.family].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", ")
        if people.count > 3 { authors += " et al." }
        return ["id": entry.id, "title": entry.title, "authors": authors, "venue": entry.venue ?? "",
                "year": entry.year.map { $0 as Any } ?? NSNull(), "citationKey": entry.citationKey ?? "",
                "hasPDF": !entry.attachments.isEmpty, "collections": Array(entry.collectionIDs)]
    }

    /// 사이드바와 같은 순서(부모 아래 자식)로, 들여쓰기 깊이와 함께.
    private func collectionList() -> [[String: Any]] {
        let all = LibraryStore.shared.collections
        func children(of parent: Int64?, depth: Int) -> [[String: Any]] {
            all.filter { $0.parentID == parent }.flatMap { c in
                [["id": c.id, "name": c.name, "depth": depth]] + children(of: c.id, depth: depth + 1)
            }
        }
        return children(of: nil, depth: 0)
    }

    /// PDF 첫 쪽에서 DOI나 arXiv 번호를 찾는다. 참고문헌의 DOI를 잘못 집지 않도록 첫 쪽만 본다.
    static func identify(_ data: Data) -> PaperMetadata? {
        guard let text = PDFDocument(data: data)?.page(at: 0)?.string else { return nil }
        var m = PaperMetadata()
        m.doi = PaperID.doi(in: text)
        m.arxivID = m.doi == nil ? PaperID.arxiv(in: text) : nil
        return m.doi != nil || m.arxivID != nil ? m : nil
    }
}
