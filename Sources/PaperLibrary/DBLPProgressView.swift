import AppKit

/// 서재 아래쪽 가운데에 뜨는 DBLP 확인 진행 상황: "Checking with DBLP… 12 of 159". 끝나면 사라진다.
/// Chrome이 꺼져 있거나 DBLP가 잠시 막으면 그 사정을 대신 보인다.
final class DBLPProgressView: NSVisualEffectView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        spinner.style = .spinning
        spinner.controlSize = .small
        bar.style = .bar
        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.widthAnchor.constraint(equalToConstant: 120).isActive = true
        label.font = Style.font
        let stack = NSStackView(views: [spinner, label, bar])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: DBLPQueue.didChange, object: nil)
        // 확장이 오지 않는 것(Chrome 꺼짐)은 알림이 없으니 몇 초마다 다시 본다.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @MainActor @objc private func refresh() {
        let queue = DBLPQueue.shared
        guard let progress = queue.visibleProgress else {
            isHidden = true
            spinner.stopAnimation(nil)
            return
        }
        isHidden = false
        spinner.startAnimation(nil)
        bar.maxValue = Double(max(progress.total, 1))
        bar.doubleValue = Double(progress.done)
        var text = "Checking with DBLP… \(progress.done) of \(progress.total)"
        if let note = queue.statusNote { text += " — \(note)" }
        label.stringValue = text
    }
}
