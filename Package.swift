// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenPrivacy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ScreenPrivacy", targets: ["ScreenPrivacy"])],
    targets: [
        .target(name: "AttentionCore"),
        .target(name: "OverlayUI"),
        .executableTarget(name: "ScreenPrivacy", dependencies: ["AttentionCore", "OverlayUI"]),
        .testTarget(name: "AttentionCoreTests", dependencies: ["AttentionCore"]),
        .testTarget(name: "OverlayUITests", dependencies: ["OverlayUI"])
    ]
)
