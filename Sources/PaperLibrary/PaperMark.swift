import AppKit

/// PDF는 리더 앱 PaperMark로 연다. PaperMark가 이미 켜져 있으면 그 창에 탭으로 붙는다.
enum PaperMark {
    static let bundleID = "com.inextro.papermark"

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static func open(_ pdf: URL, from window: NSWindow?) {
        guard let app = appURL else {
            let alert = NSAlert()
            alert.messageText = "PaperMark is not installed."
            alert.informativeText = "PaperLibrary opens PDFs in PaperMark. Open this PDF in the default app instead?"
            alert.addButton(withTitle: "Open in Default App")
            alert.addButton(withTitle: "Cancel")
            let handler = { (response: NSApplication.ModalResponse) in
                if response == .alertFirstButtonReturn { NSWorkspace.shared.open(pdf) }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: handler) } else { handler(alert.runModal()) }
            return
        }
        NSWorkspace.shared.open([pdf], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                let alert = NSAlert(error: error)
                if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            }
        }
    }
}
