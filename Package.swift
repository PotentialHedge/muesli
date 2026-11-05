// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "tinyMuesli",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "tinyMuesli", targets: ["tinyMuesli"]),
    ],
    dependencies: [
        // Speaker diarization (CoreML). Only the Diarizer trait: no TTS, no NeMo text-processing binary.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: ["Diarizer"]),
        // App updates. Only the menu bar app uses it; the CLI and MCP server never touch the network.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.1"),
    ],
    targets: [
        // Everything that isn't UI: detection, capture, transcription, file layout. Testable without the app.
        .target(name: "TinyMuesliCore", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        // Menu bar app + CLI (same binary).
        .executableTarget(
            name: "tinyMuesli",
            dependencies: ["TinyMuesliCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is embedded in Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "TinyMuesliCoreTests", dependencies: ["TinyMuesliCore"]),
    ]
)
