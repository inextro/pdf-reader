// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PaperMark",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PaperMarkCore"),
        .executableTarget(name: "PaperMark", dependencies: ["PaperMarkCore"]),
        // 형광펜 저장·재로딩을 실제 PDF로 확인하는 검증 도구
        .executableTarget(name: "pmcheck", dependencies: ["PaperMarkCore"]),
    ]
)
