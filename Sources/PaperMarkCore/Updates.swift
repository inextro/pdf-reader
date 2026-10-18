import CryptoKit
import Foundation

/// GitHub 최신 릴리스를 확인하고, 내려받은 zip의 앱으로 지금 앱을 바꾼다.
/// 앱이 직접 받은 파일에는 quarantine이 붙지 않아서 바꾼 앱을 열 때 Gatekeeper 확인이 다시 뜨지 않는다.
public enum Updates {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/inextro/pdf-reader/releases/latest")!

    public struct Release: Decodable, Equatable {
        public struct Asset: Decodable, Equatable {
            public let name: String
            public let url: URL
            /// GitHub가 계산한 "sha256:…". 예전 릴리스에는 없을 수 있다.
            public let digest: String?

            enum CodingKeys: String, CodingKey {
                case name, digest
                case url = "browser_download_url"
            }
        }

        public let tag: String
        public let notes: String
        public let page: URL
        public let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case assets
            case tag = "tag_name"
            case notes = "body"
            case page = "html_url"
        }

        /// "v0.5.0" → "0.5.0"
        public var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

        /// release.sh가 올리는 PaperMark-<버전>.zip
        public var zip: Asset? { assets.first { $0.name == "PaperMark-\(version).zip" } }

        /// 설명 끝의 설치 안내("---" 아래)는 앱 안에서는 필요 없어서 뺀다.
        public var changes: String {
            let body = notes.components(separatedBy: "\n---").first ?? notes
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public static func latestRelease(from url: URL = latestReleaseURL) async throws -> Release {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PaperMark", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// 점으로 나눈 숫자로 비교한다: 0.10.0 > 0.9.1. 앞의 "v"는 무시한다.
    public static func isNewer(_ version: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            (s.hasPrefix("v") ? String(s.dropFirst()) : s).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let (a, b) = (parts(version), parts(current))
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y }
        }
        return false
    }

    public enum UpdateError: LocalizedError, Equatable {
        case badResponse(Int)
        case noDownload
        case checksumMismatch
        case notTheApp(String)
        case unzipFailed

        public var errorDescription: String? {
            switch self {
            case .badResponse(let code): "GitHub answered with status \(code)."
            case .noDownload: "This release has no PaperMark download."
            case .checksumMismatch: "The download is damaged (checksum mismatch)."
            case .notTheApp(let reason): "The download is not the expected PaperMark app (\(reason))."
            case .unzipFailed: "The download could not be unzipped."
            }
        }
    }

    /// 내려받은 zip을 풀어 그 안의 PaperMark.app을 돌려준다. 체크섬, 번들 ID, 버전이 맞아야 한다.
    public static func unpack(zip: URL, digest: String?, bundleID: String, version: String) throws -> URL {
        if let digest, digest.hasPrefix("sha256:") {
            let hash = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard hash == digest.dropFirst("sha256:".count).lowercased() else { throw UpdateError.checksumMismatch }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperMarkUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.unzipFailed }

        let app = folder.appendingPathComponent("PaperMark.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.notTheApp("no Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.notTheApp("bundle ID") }
        guard info["CFBundleShortVersionString"] as? String == version else { throw UpdateError.notTheApp("version") }
        return app
    }

    /// 실행 중인 앱 자리에 새 앱을 넣는다. 이미 떠 있는 프로세스는 옛 파일로 계속 돌고, 다시 실행하면 새 앱이 뜬다.
    public static func replace(_ installed: URL, with app: URL) throws {
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: app, backupItemName: nil, options: [])
    }
}
