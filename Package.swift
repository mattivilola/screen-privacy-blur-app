// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenPrivacy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ScreenPrivacy", targets: ["ScreenPrivacy"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "AttentionCore"),
        .target(name: "OverlayUI"),
        .target(name: "SnapshotCore"),
        .executableTarget(name: "ScreenPrivacy", dependencies: [
            "AttentionCore", "OverlayUI", "SnapshotCore",
            .product(name: "Sparkle", package: "Sparkle")
        ]),
        .testTarget(name: "AttentionCoreTests", dependencies: ["AttentionCore"]),
        .testTarget(name: "OverlayUITests", dependencies: ["OverlayUI"]),
        .testTarget(name: "SnapshotCoreTests", dependencies: ["SnapshotCore"])
    ]
)
