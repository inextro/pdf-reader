import Foundation

/// 서지 정보를 어디서 어떻게 채울지. PaperLibrary 설정 창에서 고른다.
public struct LookupOptions: Equatable {
    /// 페이지 메타태그와 CrossRef·arXiv가 다르면 CrossRef·arXiv를 쓴다.
    public var preferOnline = true
    /// arXiv 논문인데 arXiv에 출판본 DOI가 적혀 있으면 출판본 정보를 쓴다.
    public var usePublishedVersion = true
    /// 제목을 첫 글자만 대문자로 바꾼다(지금 라이브러리 제목들의 표기).
    public var sentenceCase = true

    public init(preferOnline: Bool = true, usePublishedVersion: Bool = true, sentenceCase: Bool = true) {
        self.preferOnline = preferOnline
        self.usePublishedVersion = usePublishedVersion
        self.sentenceCase = sentenceCase
    }
}

/// DOI는 CrossRef에서, arXiv 번호는 arXiv API에서 서지 정보를 받아 온다.
public enum MetadataLookup {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpAdditionalHeaders = ["User-Agent": "PaperLibrary/0.1"]
        return URLSession(configuration: configuration)
    }()

    /// 없는 DOI면 nil.
    public static func crossref(doi: String) async throws -> PaperMetadata? {
        let path = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://api.crossref.org/works/\(path)") else { return nil }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return PaperMetadata.crossref(data)
    }

    public static func arxiv(id: String) async throws -> (metadata: PaperMetadata, publishedDOI: String?)? {
        guard let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(id)") else { return nil }
        let (data, _) = try await session.data(from: url)
        return PaperMetadata.arxiv(data)
    }

    /// 제목과 첫 저자로 CrossRef에서 출판본(학회·저널 논문)을 찾는다. 대소문자·문장부호를 빼고 제목이 같은 것만 고른다.
    public static func publishedVersion(of preprint: PaperMetadata) async throws -> PaperMetadata? {
        guard !preprint.title.isEmpty, var components = URLComponents(string: "https://api.crossref.org/works") else { return nil }
        let family = preprint.creators.first?.family
        components.queryItems = [URLQueryItem(name: "query.bibliographic", value: preprint.title), URLQueryItem(name: "rows", value: "5")]
            + (family.map { [URLQueryItem(name: "query.author", value: $0)] } ?? [])
        guard let url = components.url else { return nil }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let works = (root["message"] as? [String: Any])?["items"] as? [[String: Any]] else { return nil }
        let title = PaperMetadata.titleKey(preprint.title)
        for work in works {
            guard let m = PaperMetadata.crossref(try JSONSerialization.data(withJSONObject: ["message": work])),
                  ["conferencePaper", "journalArticle"].contains(m.type), PaperMetadata.titleKey(m.title) == title,
                  family == nil || m.creators.first?.family.lowercased() == family?.lowercased() else { continue }
            return m
        }
        return nil
    }

    /// 페이지에서 읽은 정보를 CrossRef·arXiv로 채운다. 찾지 못하거나 실패하면 페이지 정보만 쓰고 그 사정을 warnings에 적는다.
    public static func complete(_ page: PaperMetadata, options: LookupOptions) async -> (PaperMetadata, warnings: [String]) {
        var warnings: [String] = []
        var online: PaperMetadata?
        if let id = page.arxivID, page.doi == nil || page.doi!.hasPrefix("10.48550/") {
            do {
                if let (preprint, published) = try await arxiv(id: id) {
                    online = preprint
                    // 출판본: arXiv에 적힌 DOI가 있으면 그것으로, 없으면 제목과 첫 저자로 CrossRef에서 찾는다.
                    if options.usePublishedVersion {
                        let version = if let published { try? await crossref(doi: published) }
                                      else { try? await publishedVersion(of: preprint) }
                        if let version { online = version.merged(with: preprint, preferOther: false) }
                    }
                } else {
                    warnings.append("arXiv has no paper \(id).")
                }
            } catch {
                warnings.append("arXiv lookup failed: \(error.localizedDescription)")
            }
        } else if let doi = page.doi {
            do {
                online = try await crossref(doi: doi)
                if online == nil { warnings.append("CrossRef has no record for \(doi).") }
            } catch {
                warnings.append("CrossRef lookup failed: \(error.localizedDescription)")
            }
        }
        var result = online.map { page.merged(with: $0, preferOther: options.preferOnline) } ?? page
        if options.sentenceCase { result.title = PaperMetadata.sentenceCase(result.title) }
        return (result, warnings)
    }
}
