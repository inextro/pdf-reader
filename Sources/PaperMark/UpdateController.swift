import AppKit
import PaperMarkCore

/// 새 버전 알림과 설치. 앱을 켤 때와 그 뒤 하루마다 GitHub 최신 릴리스를 확인하고,
/// 새 버전이 있으면 패치 노트와 함께 묻는다. Install을 누르면 zip을 받아 앱을 바꾸고 다시 실행한다.
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private static let autoCheckKey = "checksForUpdates", lastCheckKey = "lastUpdateCheck", skippedKey = "skippedVersion"
    private static let interval: TimeInterval = 24 * 60 * 60
    private var timer: Timer?
    private var busy = false
    // 자동 확인에서 찾았지만 PaperMark가 앞에 있지 않아 아직 알리지 않은 릴리스.
    private var waiting: Updates.Release?

    var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoCheckKey) }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 앱을 켠 뒤 잠시 기다렸다 한 번, 그 뒤로는 한 시간마다 하루가 지났는지 본다(잠자기에서 깨어난 뒤도 따라잡는다).
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard checksAutomatically else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.interval else { return }
        check(userInitiated: false)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        check(userInitiated: true)
    }

    /// 직접 확인하면 결과(최신임, 실패)도 알리고 건너뛴 버전도 다시 보여 준다. 자동 확인은 새 버전이 있을 때만 말한다.
    private func check(userInitiated: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let release = try await Updates.latestRelease()
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
                if Updates.isNewer(release.version, than: currentVersion), userInitiated || release.version != skipped {
                    // 다른 앱을 쓰는 중에 PaperMark가 앞으로 튀어나오지 않게, 돌아올 때 알린다.
                    if NSApp.isActive { offer(release) } else { offerWhenActive(release) }
                } else if userInitiated {
                    inform("PaperMark is up to date", "Version \(currentVersion) is the latest.")
                }
            } catch {
                if userInitiated { inform("Couldn’t check for updates", error.localizedDescription) }
            }
        }
    }

    private func offerWhenActive(_ release: Updates.Release) {
        if waiting == nil {
            NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                                   name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        waiting = release
    }

    @objc private func appBecameActive() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        guard let release = waiting else { return }
        waiting = nil
        // 창이 다 앞으로 나온 뒤에 띄운다.
        DispatchQueue.main.async { self.offer(release) }
    }

    private func offer(_ release: Updates.Release) {
        let alert = NSAlert()
        alert.messageText = "PaperMark \(release.version) is available"
        alert.informativeText = "You have \(currentVersion). What’s new:"
        alert.accessoryView = notesView(release.changes)
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(release)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        default:
            break
        }
    }

    private func notesView(_ text: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
        scroll.borderType = .bezelBorder
        if let textView = scroll.documentView as? NSTextView {
            textView.string = text
            textView.isEditable = false
            textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            textView.textContainerInset = NSSize(width: 6, height: 6)
        }
        return scroll
    }

    // MARK: 설치

    private func install(_ release: Updates.Release) {
        let installed = Bundle.main.bundleURL
        // 내려받은 그대로(격리된 임시 위치에서) 실행 중이거나 쓸 수 없는 폴더면 바꿀 수 없으니 릴리스 페이지를 연다.
        guard !installed.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path) else {
            inform("Install the update manually",
                   "PaperMark can’t replace itself at \(installed.deletingLastPathComponent().path). "
                   + "Move PaperMark to your Applications folder, or download the new version from the release page.")
            NSWorkspace.shared.open(release.page)
            return
        }
        guard let asset = release.zip else {
            NSWorkspace.shared.open(release.page)
            return
        }
        let progress = ProgressPanel(title: "Downloading PaperMark \(release.version)…")
        progress.show()
        Task {
            do {
                let (downloaded, _) = try await URLSession.shared.download(from: asset.url)
                // 받은 임시 파일은 시스템이 언제 지울지 모르니 바로 옮겨 둔다.
                let zip = FileManager.default.temporaryDirectory.appendingPathComponent("PaperMark-\(UUID().uuidString).zip")
                try FileManager.default.moveItem(at: downloaded, to: zip)
                let bundleID = Bundle.main.bundleIdentifier ?? ""
                let app = try await Task.detached {
                    try Updates.unpack(zip: zip, digest: asset.digest, bundleID: bundleID, version: release.version)
                }.value
                try Updates.replace(installed, with: app)
                progress.close()
                relaunch(installed)
            } catch {
                progress.close()
                inform("The update couldn’t be installed", error.localizedDescription)
            }
        }
    }

    /// 이 프로세스가 끝나기를 기다렸다가 새 앱을 여는 셸을 띄우고 끝낸다. 대기 중인 저장은 문서가 끝낼 때 마친다.
    private func relaunch(_ app: URL) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                           app.path]
        try? shell.run()
        NSApp.terminate(nil)
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}

/// 내려받는 동안 띄우는 작은 창.
private final class ProgressPanel {
    private let panel: NSPanel

    init(title: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 70), styleMask: [.titled], backing: .buffered,
                        defer: false)
        panel.title = "Updating PaperMark"
        let label = NSTextField(labelWithString: title)
        let bar = NSProgressIndicator()
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        bar.widthAnchor.constraint(equalToConstant: 288).isActive = true
        panel.contentView = stack
        panel.center()
    }

    func show() { panel.makeKeyAndOrderFront(nil) }
    func close() { panel.close() }
}
