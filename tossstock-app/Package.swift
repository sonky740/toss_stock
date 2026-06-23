// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TossStock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TossStock",
            path: "Sources/TossStock"
        )
    ],
    // Swift 6 모드 고정: actor/Sendable/@MainActor strict-concurrency 검사를 결정적으로 적용한다.
    // (TokenStore의 refreshTask=task-before-await 패턴이 이 검사를 통과해야 한다)
    swiftLanguageModes: [.v6]
)
