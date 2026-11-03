import AppKit
import PaperMarkCore
import UniformTypeIdentifiers

/// PaperMark를 기본 PDF 앱으로 쓸 때의 일(예전 PDFRouter 앱).
/// 사용자가 허락하면 PaperMark가 기본 PDF 앱이 되고, Finder·Raycast 등에서 연 PDF 중
/// PaperLibrary workspace 안의 PDF만 직접 열고 나머지는 Preview로 넘긴다.
enum DefaultPDFApp {
    static let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
    private static let askedKey = "didAskDefaultPDFApp"

    static var isDefault: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: .pdf)
            .flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
    }

    /// 받은 PDF를 PaperMark가 열 것과 Preview로 넘길 것으로 나눈다.
    /// PaperMark가 기본 앱이 아니면(직접 "다음으로 열기"를 골랐거나 PaperLibrary가 보낸 것) 모두 연다.
    /// PaperLibrary가 보낸 PDF도 모두 연다.
    static func split(_ urls: [URL], sender: String?) -> (open: [URL], forward: [URL]) {
        guard isDefault, sender != PDFRouting.libraryBundleID else { return (urls, []) }
        guard let workspace = PDFRouting.workspaceFolder() else { return ([], urls) }
        let open = urls.filter { PDFRouting.isInside($0, workspace) }
        return (open, urls.filter { !open.contains($0) })
    }

    /// 지금 처리 중인 Apple Event(파일 열기)를 보낸 앱의 bundle ID.
    static var currentSender: String? {
        guard let pid = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    static func forward(_ urls: [URL], done: @escaping () -> Void) {
        NSWorkspace.shared.open(urls, withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("PaperMark: Preview로 넘기기 실패: \(error)") }
            DispatchQueue.main.async(execute: done)
        }
    }

    /// PaperLibrary workspace가 있고 아직 기본 앱이 아니면 처음 한 번만 묻는다.
    static func askOnce() {
        guard !UserDefaults.standard.bool(forKey: askedKey), !isDefault, PDFRouting.workspaceFolder() != nil else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        ask()
    }

    /// 메뉴의 "Use as Default PDF App…"에서도 부른다.
    static func ask() {
        let alert = NSAlert()
        alert.messageText = isDefault ? "PaperMark is your default PDF app." : "Use PaperMark as your default PDF app?"
        let folder = PDFRouting.workspaceFolder().map { ($0.path as NSString).abbreviatingWithTildeInPath }
        alert.informativeText = folder.map {
            "PDFs inside your PaperLibrary workspace (\($0)) will open in PaperMark. Every other PDF will open in Preview."
        } ?? "Set a workspace in PaperLibrary first. Until then, every PDF will open in Preview."
        if isDefault {
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Use Preview Instead")
            if alert.runModal() == .alertSecondButtonReturn { setDefault(preview) }
        } else {
            alert.addButton(withTitle: "Use PaperMark")
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
