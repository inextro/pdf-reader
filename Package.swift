// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PaperMark",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PaperMarkCore"),
        // 서지 라이브러리(SQLite, Zotero 가져오기, 백업). UI가 없어 pmcheck로 확인한다.
        .target(name: "PaperMarkLibrary"),
        // 업데이트 확인·설치 창
        .target(name: "AppUpdater", dependencies: ["PaperMarkCore"]),
        // PDF 리더(예전 PaperMark 앱). Quillo 안에서 PDF 탭으로 연다.
        .target(name: "Reader", dependencies: ["PaperMarkCore"]),
        // 서지 라이브러리 앱 Quillo(타깃 이름은 예전 이름 PaperLibrary).
        .executableTarget(name: "PaperLibrary", dependencies: ["PaperMarkLibrary", "AppUpdater", "Reader"]),
        // 형광펜 저장·재로딩을 실제 PDF로 확인하는 검증 도구
        .executableTarget(name: "pmcheck", dependencies: ["PaperMarkCore", "PaperMarkLibrary"]),
    ]
)
