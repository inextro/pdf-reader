import AppKit

/// 앱에 든 Chrome 확장(Contents/Resources/ChromeExtension). 웹 스토어에 올리지 않아서 사용자가 Load unpacked로 한 번 불러온다.
/// Chrome은 불러온 폴더를 계속 쓰므로, 앱 업데이트와 상관없이 그대로 있는 Application Support에 복사해 두고 그 폴더를 불러오게 한다.
enum ChromeExtension {
    static var installedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperLibrary/ChromeExtension", isDirectory: true)
    }

    private static var bundledURL: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("ChromeExtension", isDirectory: true) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// 켤 때: 복사해 둔 확장이 있고 앱에 든 것과 다르면 바꿔 둔다(Chrome에서는 Reload만 누르면 된다).
    static func refresh() {
        guard FileManager.default.fileExists(atPath: installedURL.path), let bundled = bundledURL, !same(bundled, installedURL) else { return }
        do { try copy(from: bundled) } catch { NSLog("%@", "PaperLibrary: could not update the Chrome extension: \(error)") }
    }

    /// 처음 켰을 때 한 번: 확장을 아직 복사한 적이 없으면 설치를 권한다. 나중에는 메뉴에서 설치한다.
    static func offerOnFirstLaunch(in window: NSWindow?) {
        let key = "chromeExtensionOffered"
        guard !UserDefaults.standard.bool(forKey: key), bundledURL != nil,
              !FileManager.default.fileExists(atPath: installedURL.path) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "Save papers from Chrome?"
        alert.informativeText = "The Save to PaperLibrary extension adds the paper on the page you are reading, with its PDF, in one click. "
            + "You can also install it later from PaperLibrary > Install Chrome Extension…."
        alert.addButton(withTitle: "Install Chrome Extension…")
        alert.addButton(withTitle: "Not Now")
        let run = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { DispatchQueue.main.async { install(in: window) } }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    /// PaperLibrary > Install Chrome Extension…: 복사하고 불러오는 방법을 안내한다.
    static func install(in window: NSWindow?) {
        guard let bundled = bundledURL else {
            NSApp.presentError(CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "This copy of PaperLibrary does not include the Chrome extension."]))
            return
        }
        do { try copy(from: bundled) } catch { NSApp.presentError(error); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installedURL.path, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Install the Chrome extension"
        alert.informativeText = """
            1. Click Open Chrome Extensions, then turn on Developer mode (top right).
            2. Click Load unpacked and choose the ChromeExtension folder. Its path is on the clipboard: press ⌘⇧G in the dialog and paste.
            3. Pin “Save to PaperLibrary” from the puzzle icon.

            Keep PaperLibrary running while you save papers. After PaperLibrary updates, click Reload on the extension in Chrome.
            """
        alert.addButton(withTitle: "Open Chrome Extensions")
        alert.addButton(withTitle: "Show Folder")
        alert.addButton(withTitle: "Done")
        let run = { (response: NSApplication.ModalResponse) in
            switch response {
            case .alertFirstButtonReturn: openChromeExtensions()
            case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([installedURL])
            default: break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    private static func openChromeExtensions() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let page = URL(string: "chrome://extensions") else {
            NSWorkspace.shared.activateFileViewerSelecting([installedURL])
            return
        }
        NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func copy(from bundled: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: installedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: installedURL.path) { try fm.removeItem(at: installedURL) }
        try fm.copyItem(at: bundled, to: installedURL)
    }

    /// 두 폴더의 파일 목록과 내용이 같은가.
    private static func same(_ a: URL, _ b: URL) -> Bool {
        func files(_ root: URL) -> [String: Data] {
            let base = root.standardizedFileURL.path + "/"
            var out: [String: Data] = [:]
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return out }
            for case let url as URL in walk {
                if let data = try? Data(contentsOf: url) { out[url.standardizedFileURL.path.replacingOccurrences(of: base, with: "")] = data }
            }
            return out
        }
        return files(a) == files(b)
    }
}
