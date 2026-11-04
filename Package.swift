// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Muesli",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Muesli", targets: ["Muesli"]),
    ],
    dependencies: [
        // Speaker diarization (CoreML). Only the Diarizer trait: no TTS, no NeMo text-processing binary.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: ["Diarizer"]),
    ],
    targets: [
        // Everything that isn't UI: detection, capture, transcription, file layout. Testable without the app.
        .target(name: "MuesliCore", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        // Menu bar app + CLI (same binary).
        .executableTarget(name: "Muesli", dependencies: ["MuesliCore"]),
        .testTarget(name: "MuesliCoreTests", dependencies: ["MuesliCore"]),
    ]
)
