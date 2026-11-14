import Foundation

/// PaperMark가 Quillo의 리더로 들어오면서(1.0.5) PaperMark 설정을 한 번 가져온다.
/// Quillo에 이미 있는 값은 덮어쓰지 않는다. PaperMark를 쓴 적이 없으면 가져올 것이 없다.
public enum PaperMarkSettings {
    public static let suiteName = "com.inextro.papermark"
    private static let doneKey = "didImportPaperMarkSettings"

    /// 형광펜 팔레트, 형광펜 모드, 단축키, 열려 있던 PDF와 마지막 페이지, 리더 창 크기와 사이드바 폭.
    /// 업데이트 확인, Files 탭, 기본 앱 질문 기록은 가져오지 않는다.
    public static let keys = ["presets", "currentColor", "paletteVersion", "highlightMode", "shortcuts", "openFiles", "lastPages",
                       "NSWindow Frame PaperMarkDocumentWindow", "NSSplitView Subview Frames PaperMarkSidebarWidth"]

    public static func importOnce(from source: UserDefaults? = UserDefaults(suiteName: suiteName), into target: UserDefaults = .standard) {
        guard !target.bool(forKey: doneKey) else { return }
        target.set(true, forKey: doneKey)
        guard let source else { return }
        for key in keys where target.object(forKey: key) == nil {
            if let value = source.object(forKey: key) { target.set(value, forKey: key) }
        }
    }
}
