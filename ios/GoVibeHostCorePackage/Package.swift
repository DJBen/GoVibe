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
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.10.0"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "9.0.0"),
    ],
    targets: [
        .target(
            name: "GoVibeHostCore",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
            ]
        ),
        .testTarget(
            name: "GoVibeHostCoreTests",
            dependencies: ["GoVibeHostCore"]
        ),
    ]
)
