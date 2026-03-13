// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GoVibeFeature",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "GoVibeFeature",
            targets: ["GoVibeFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../ThirdParty/SwiftTerm")
    ],
    targets: [
        .target(
            name: "GoVibeFeature",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(
            name: "GoVibeFeatureTests",
            dependencies: [
                "GoVibeFeature"
            ]
        ),
    ]
)
