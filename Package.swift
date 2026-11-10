// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Paneport",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Paneport", targets: ["Paneport"]),
    ],
    targets: [
        // Declarations for Apple's private CGVirtualDisplay API (Objective-C header only).
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay"
        ),
        // The menu-bar app: virtual displays, capture, encoding, streaming and the settings UI.
        .executableTarget(
            name: "Paneport",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/Paneport",
            resources: [.copy("Resources/receiver")]
        ),
        .testTarget(
            name: "PaneportTests",
            dependencies: ["Paneport"],
            path: "Tests/PaneportTests"
        ),
    ]
)
