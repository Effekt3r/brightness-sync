// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "brightness-sync",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BrightnessSyncCore"),
        .testTarget(name: "BrightnessSyncCoreTests", dependencies: ["BrightnessSyncCore"]),
    ]
)
