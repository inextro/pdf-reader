// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PaperMark",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PaperMarkCore"),
        // 서지 라이브러리(SQLite, Zotero 가져오기, 백업). UI가 없어 pmcheck로 확인한다.
        .target(name: "PaperMarkLibrary"),
        // 두 앱이 같이 쓰는 업데이트 확인·설치 창
        .target(name: "AppUpdater", dependencies: ["PaperMarkCore"]),
        .executableTarget(name: "PaperMark", dependencies: ["PaperMarkCore", "AppUpdater"]),
        // 서지 라이브러리 앱. PDF는 PaperMark로 연다.
        .executableTarget(name: "PaperLibrary", dependencies: ["PaperMarkLibrary", "AppUpdater"]),
        // 형광펜 저장·재로딩을 실제 PDF로 확인하는 검증 도구
        .executableTarget(name: "pmcheck", dependencies: ["PaperMarkCore", "PaperMarkLibrary"]),
    ]
)
