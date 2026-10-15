import AppKit

/// 첫 열기 창을 Google Drive 폴더에서 시작하게 한다. 이후에는 마지막으로 연 폴더를 시스템이 기억한다.
final class PMDocumentController: NSDocumentController {
    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        let key = "didSuggestDriveFolder"
        if !UserDefaults.standard.bool(forKey: key), let drive = Self.googleDriveFolder() {
            openPanel.directoryURL = drive
            UserDefaults.standard.set(true, forKey: key)
        }
        super.beginOpenPanel(openPanel, forTypes: inTypes, completionHandler: completionHandler)
    }

    static func googleDriveFolder() -> URL? {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let drive = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix("GoogleDrive-") }) else { return nil }
        let myDrive = drive.appendingPathComponent("My Drive")
        return FileManager.default.fileExists(atPath: myDrive.path) ? myDrive : drive
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        // Dock에서 그냥 실행했을 때는 바로 열기 창을 띄운다(파일을 더블클릭해 실행한 경우 제외).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if NSDocumentController.shared.documents.isEmpty { NSDocumentController.shared.openDocument(nil) }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(of: main, title: "PaperMark")
        app.addItem(withTitle: "PaperMark에 관하여", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "PaperMark 가리기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "기타 가리기", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "모두 보기", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "PaperMark 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(of: main, title: "파일")
        file.addItem(withTitle: "열기…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recentItem = file.addItem(withTitle: "최근 항목 열기", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "최근 항목 열기")
        // AppKit이 이 메뉴를 최근 문서 목록으로 채우게 하는 비공개 표식. 없으면 그냥 빈 메뉴로 남는다.
        let marker = NSSelectorFromString("_setMenuName:")
        if recent.responds(to: marker) { recent.perform(marker, with: "NSRecentDocumentsMenu") }
        recent.addItem(withTitle: "메뉴 지우기", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recentItem.submenu = recent
        file.addItem(.separator())
        file.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "저장", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")

        let edit = submenu(of: main, title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "찾기…", action: #selector(DocumentWindowController.focusSearch(_:)), keyEquivalent: "f")
        edit.addItem(withTitle: "다음 찾기", action: #selector(DocumentWindowController.findNextResult(_:)), keyEquivalent: "g")
        edit.addItem(withTitle: "이전 찾기", action: #selector(DocumentWindowController.findPreviousResult(_:)), keyEquivalent: "G")

        let marker2 = submenu(of: main, title: "형광펜")
        marker2.addItem(withTitle: "선택 영역 칠하기", action: #selector(DocumentWindowController.highlightSelection(_:)), keyEquivalent: "d")
        marker2.addItem(withTitle: "형광펜 모드", action: #selector(DocumentWindowController.toggleHighlightMode(_:)), keyEquivalent: "D")

        let view = submenu(of: main, title: "보기")
        view.addItem(withTitle: "확대", action: #selector(DocumentWindowController.zoomInPDF(_:)), keyEquivalent: "=")
        view.addItem(withTitle: "축소", action: #selector(DocumentWindowController.zoomOutPDF(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "창에 맞추기", action: #selector(DocumentWindowController.zoomToFit(_:)), keyEquivalent: "0")

        let window = submenu(of: main, title: "윈도우")
        window.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "확대/축소", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "모두 앞으로 가져오기", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private func submenu(of main: NSMenu, title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }
}
