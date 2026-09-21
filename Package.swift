// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenPrivacy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ScreenPrivacy", targets: ["ScreenPrivacy"])],
    targets: [
        .target(name: "AttentionCore"),
        .executableTarget(name: "ScreenPrivacy", dependencies: ["AttentionCore"]),
        .testTarget(name: "AttentionCoreTests", dependencies: ["AttentionCore"])
    ]
)
