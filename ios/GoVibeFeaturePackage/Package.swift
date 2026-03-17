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
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.10.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(path: "../ThirdParty/SwiftTerm")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "GoVibeFeature",
            dependencies: [
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseMessaging", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
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
