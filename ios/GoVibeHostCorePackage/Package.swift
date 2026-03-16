// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GoVibeHostCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "GoVibeHostCore",
            targets: ["GoVibeHostCore"]
        ),
    ],
    targets: [
        .target(
            name: "GoVibeHostCore"
        ),
        .testTarget(
            name: "GoVibeHostCoreTests",
            dependencies: ["GoVibeHostCore"]
        ),
    ]
)
