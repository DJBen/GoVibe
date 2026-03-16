// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GoVibeMacCli",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(path: "../GoVibeHostCorePackage"),
    ],
    targets: [
        .executableTarget(
            name: "GoVibeMacCli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GoVibeHostCore", package: "GoVibeHostCorePackage"),
            ],
            path: ".",
            exclude: [
                "Logger.swift",
                "Package.swift",
                "PtySession.swift",
                "SessionCoordinator.swift",
                "SignalBridge.swift",
                "SimulatorBridge.swift",
                "SimulatorSessionCoordinator.swift",
            ],
            sources: ["main.swift"]
        ),
    ]
)
