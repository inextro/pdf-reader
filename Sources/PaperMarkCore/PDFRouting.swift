import Foundation

/// PaperMark가 기본 PDF 앱일 때 받은 PDF를 직접 열지, Preview로 넘길지 정한다(예전 PDFRouter 앱의 일).
/// PaperLibrary의 workspace 폴더 안의 PDF만 PaperMark가 열고, 나머지는 Preview로 넘긴다.
public enum PDFRouting {
    /// PaperLibrary의 bundle ID. 설정(UserDefaults) 이름이기도 하다.
    public static let libraryBundleID = "com.inextro.paperlibrary"
    public static let libraryFolderKey = "libraryFolder"

    /// PaperLibrary 설정에 저장된 workspace 폴더. PaperLibrary를 쓰지 않으면 nil.
    public static func workspaceFolder(defaults: UserDefaults? = UserDefaults(suiteName: libraryBundleID)) -> URL? {
        guard let path = defaults?.string(forKey: libraryFolderKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 틸드를 펼치고 심링크를 풀어, 다른 경로로 들어와도 같은 문자열로 비교한다.
    /// 아직 없는 파일은 심링크가 풀리지 않으므로, 있는 가장 가까운 상위 폴더까지 풀고 나머지를 붙인다.
    public static func canonicalPath(_ url: URL) -> String {
        var base = URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath).standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: base.path), base.pathComponents.count > 1 {
            rest.insert(base.lastPathComponent, at: 0)
            base.deleteLastPathComponent()
        }
        return rest.reduce(base.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    /// file이 folder 안(하위 폴더 포함)에 있는가.
    public static func isInside(_ file: URL, _ folder: URL) -> Bool {
        let root = canonicalPath(folder)
        return canonicalPath(file).hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
