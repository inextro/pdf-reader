import AppKit
import PaperMarkCore
import UniformTypeIdentifiers

/// Quillo를 기본 PDF 앱으로 쓸 때의 일(예전 PaperMark, 그 전에는 PDFRouter 앱).
/// 사용자가 허락하면 Quillo가 기본 PDF 앱이 되고, Finder·Raycast 등에서 연 PDF 중
/// workspace 안의 PDF만 리더로 열고 나머지는 Preview로 넘긴다.
@MainActor
public enum DefaultPDFApp {
    static let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
    static let paperMarkBundleID = "com.inextro.papermark"
    private static let askedKey = "didAskDefaultPDFApp"

    private static var defaultAppID: String? {
        NSWorkspace.shared.urlForApplication(toOpen: .pdf).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    public static var isDefault: Bool { defaultAppID == Bundle.main.bundleIdentifier }

    /// workspace 폴더. Quillo 설정(UserDefaults.standard)의 libraryFolder.
    static var workspace: URL? { PDFRouting.workspaceFolder(defaults: .standard) }

    /// 받은 PDF를 리더로 열 것과 Preview로 넘길 것으로 나눈다.
    /// Quillo가 기본 앱이 아니면(직접 "다음으로 열기"를 골랐거나 Open PDF…로 연 것) 모두 연다.
    public static func split(_ urls: [URL], sender: String?) -> (open: [URL], forward: [URL]) {
        guard isDefault, sender != Bundle.main.bundleIdentifier else { return (urls, []) }
        guard let workspace else { return ([], urls) }
        let open = urls.filter { PDFRouting.isInside($0, workspace) }
        return (open, urls.filter { !open.contains($0) })
    }

    /// 지금 처리 중인 Apple Event(파일 열기)를 보낸 앱의 bundle ID.
    public static var currentSender: String? {
        guard let pid = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public static func forward(_ urls: [URL], done: @escaping () -> Void) {
        NSWorkspace.shared.open(urls, withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("%@", "Quillo: Preview로 넘기기 실패: \(error)") }
            DispatchQueue.main.async(execute: done)
        }
    }

    /// workspace가 있고 아직 기본 앱이 아니면 처음 한 번만 묻는다.
    public static func askOnce() {
        guard !UserDefaults.standard.bool(forKey: askedKey), !isDefault, workspace != nil else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        ask()
    }

    /// Quillo 메뉴의 "Default PDF App…"에서도 부른다.
    public static func ask() {
        let alert = NSAlert()
        alert.messageText = isDefault ? "Quillo is your default PDF app." : "Use Quillo as your default PDF app?"
        let folder = workspace.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        var text = folder.map {
            "PDFs inside your workspace (\($0)) will open in Quillo. Every other PDF will open in Preview."
        } ?? "Choose a workspace first. Until then, every PDF will open in Preview."
        if !isDefault, defaultAppID == paperMarkBundleID {
            text += "\n\nPaperMark is now built into Quillo, so Quillo takes over from PaperMark."
        }
        alert.informativeText = text
        if isDefault {
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Use Preview Instead")
            if alert.runModal() == .alertSecondButtonReturn { setDefault(preview) }
        } else {
            alert.addButton(withTitle: "Use Quillo")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn { setDefault(Bundle.main.bundleURL) }
        }
    }

    private static func setDefault(_ app: URL) {
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .pdf) { error in
            guard let error else { return }
            DispatchQueue.main.async { NSApp.presentError(error) }
        }
    }
}
