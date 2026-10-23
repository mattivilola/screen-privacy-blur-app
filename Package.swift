// swift-tools-version: 6.0
import PackageDescription
import Foundation

let helperInfoPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Packaging/PowerHelper-Info.plist").path

let package = Package(
    name: "ScreenPrivacy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ScreenPrivacy", targets: ["ScreenPrivacy"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "AttentionCore"),
        .target(name: "MotionSensorCore"),
        .testTarget(name: "MotionSensorCoreTests", dependencies: ["MotionSensorCore"]),
        .target(name: "OverlayUI"),
        .target(name: "SnapshotCore"),
        .target(name: "PowerHelperKit"),
        .executableTarget(name: "ScreenPrivacyPowerHelper", dependencies: ["PowerHelperKit"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", helperInfoPath])]),
        .testTarget(name: "PowerHelperKitTests", dependencies: ["PowerHelperKit"]),
        .executableTarget(name: "ScreenPrivacy", dependencies: [
            "AttentionCore", "MotionSensorCore", "OverlayUI", "SnapshotCore", "PowerHelperKit",
            .product(name: "Sparkle", package: "Sparkle")
        ]),
        .testTarget(name: "ScreenPrivacyTests", dependencies: ["ScreenPrivacy"]),
        .testTarget(name: "AttentionCoreTests", dependencies: ["AttentionCore"]),
        .testTarget(name: "OverlayUITests", dependencies: ["OverlayUI"]),
        .testTarget(name: "SnapshotCoreTests", dependencies: ["SnapshotCore"])
    ]
)
