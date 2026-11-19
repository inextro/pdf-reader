import Foundation
import PaperMarkLibrary

/// 브라우저 확장으로 논문을 넣을 때 쓰는 설정(UserDefaults). 설정 창에서 고친다.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static var citationKeyPattern: String {
        get { defaults.string(forKey: "citationKeyPattern") ?? Naming.defaultCitationKey }
        set { defaults.set(newValue, forKey: "citationKeyPattern") }
    }

    static var fileNamePattern: String {
        get { defaults.string(forKey: "fileNamePattern") ?? Naming.defaultFileName }
        set { defaults.set(newValue, forKey: "fileNamePattern") }
    }

    /// 새 PDF를 넣을 폴더. 정하지 않았으면 라이브러리 폴더의 archive(없으면 라이브러리 폴더 자체).
    static var pdfFolder: URL? {
        get {
            if let path = defaults.string(forKey: "newPDFFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
            guard let folder = LibraryStore.shared.folder else { return nil }
            let archive = folder.appendingPathComponent("archive", isDirectory: true)
            return FileManager.default.fileExists(atPath: archive.path) ? archive : folder
        }
        set { defaults.set(newValue?.path, forKey: "newPDFFolder") }
    }

    static var lookup: LookupOptions {
        get {
            LookupOptions(preferOnline: defaults.object(forKey: "preferOnlineMetadata") as? Bool ?? true,
                          usePublishedVersion: defaults.object(forKey: "usePublishedVersion") as? Bool ?? true,
                          sentenceCase: defaults.object(forKey: "sentenceCaseTitles") as? Bool ?? true)
        }
        set {
            defaults.set(newValue.preferOnline, forKey: "preferOnlineMetadata")
            defaults.set(newValue.usePublishedVersion, forKey: "usePublishedVersion")
            defaults.set(newValue.sentenceCase, forKey: "sentenceCaseTitles")
        }
    }

    /// Copy BibTeX에서 내보내지 않을 필드(Settings → BibTeX). 처음에는 ISSN·ISBN만 뺀다(ACM 참고문헌에 나오지 않는다).
    static var bibtex: BibTeXOptions {
        get {
            BibTeXOptions(omitted: Set(defaults.stringArray(forKey: "bibtexOmittedFields") ?? ["isbn", "issn"]),
                          urlWithDOI: defaults.bool(forKey: "bibtexURLWithDOI"), hiddenTags: statusTags)
        }
        set {
            defaults.set(newValue.omitted.sorted(), forKey: "bibtexOmittedFields")
            defaults.set(newValue.urlWithDOI, forKey: "bibtexURLWithDOI")
        }
    }

    /// 서재의 arXiv 논문이 학회·학술지에 실렸는지 일주일에 한 번 DBLP에서 확인한다(Chrome 확장을 거친다). 기본은 끔.
    static var checkPublishedWeekly: Bool {
        get { defaults.bool(forKey: "checkPublishedWeekly") }
        set { defaults.set(newValue, forKey: "checkPublishedWeekly") }
    }

    /// 마지막으로 주간 확인을 마친 때.
    static var lastPublishedCheck: Date? {
        get { defaults.object(forKey: "lastPublishedCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastPublishedCheck") }
    }

    /// 확장이 찾아오는 포트. 확장의 background.js와 맞춰야 한다. 숨은 설정 `connectorPort`는 시험용.
    static var connectorPort: UInt16 {
        UInt16(exactly: defaults.integer(forKey: "connectorPort")).flatMap { $0 == 0 ? nil : $0 } ?? 23120
    }
}
