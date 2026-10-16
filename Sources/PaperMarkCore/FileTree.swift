import Foundation

/// 사이드바 파일 트리에 보일 폴더 내용.
public enum FileTree {
    /// 폴더 바로 아래의 하위 폴더와 PDF. 숨김 파일과 패키지(.app 등)는 빼고, 폴더를 먼저 Finder 순서로 놓는다.
    public static func children(of folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let shown = urls.filter { isFolder($0) || $0.pathExtension.lowercased() == "pdf" }
        return shown.sorted { a, b in
            let (fa, fb) = (isFolder(a), isFolder(b))
            if fa != fb { return fa }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    public static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// root 안에 있는 url까지 내려가는 폴더들(root 바로 아래부터, url 자신은 뺌). root 밖이면 nil.
    public static func folders(from root: URL, to url: URL) -> [URL]? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let target = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard target.count > base.count, Array(target.prefix(base.count)) == base else { return nil }
        var folder = root
        return target[base.count..<(target.count - 1)].map {
            folder = folder.appendingPathComponent($0, isDirectory: true)
            return folder
        }
    }
}
