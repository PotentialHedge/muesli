// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Muesli",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Muesli", targets: ["Muesli"]),
    ],
    targets: [
        // Everything that isn't UI: detection, capture, file layout. Testable without the app.
        .target(name: "MuesliCore"),
        // Menu bar app + CLI (same binary).
        .executableTarget(name: "Muesli", dependencies: ["MuesliCore"]),
        .testTarget(name: "MuesliCoreTests", dependencies: ["MuesliCore"]),
    ]
)
