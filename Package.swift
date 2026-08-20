// swift-tools-version:6.0
import PackageDescription

// NOTE ON TESTING: This machine has only the Command Line Tools, whose SDK does
// not vend XCTest or swift-testing. To keep the suite fully runnable and
// verifiable from the CLI (`swift run VoiceFlowTests`), tests are built as a
// normal executable target on top of a tiny assertion library (VoiceFlowTestKit)
// instead of an XCTest testTarget. The runner exits non-zero on any failure so
// it works in CI and scripts exactly like `swift test` would.

let package = Package(
    name: "VoiceFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VoiceFlowCore", targets: ["VoiceFlowCore"]),
        .executable(name: "VoiceFlow", targets: ["VoiceFlowApp"]),
        .executable(name: "VoiceFlowTests", targets: ["VoiceFlowTests"]),
        .executable(name: "VoiceFlowBench", targets: ["VoiceFlowBench"]),
        // Replays real dictations through the production cleanup path — the
        // answer to "how do we know it is actually working?".
        .executable(name: "VoiceFlowReplay", targets: ["VoiceFlowReplay"])
    ],
    dependencies: [
        // On-device Whisper (Core ML / Neural Engine) for the optional High-Accuracy mode.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
        // BENCH ONLY. Parakeet (NVIDIA) via CoreML — Codex's one serious engine
        // suggestion, to be judged offline on his archived audio before any
        // integration is considered. The app does NOT link this.
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.15.0")
    ],
    targets: [
        .target(
            name: "VoiceFlowCore",
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "VoiceFlowTestKit",
            dependencies: []
        ),
        // The Whisper engine lives in a LIBRARY, not the app executable, so the
        // offline benchmark can drive the EXACT production decode path. A
        // harness that reimplements the thing it measures proves nothing — and
        // measuring the real path is the whole point of the accuracy work.
        // Kept out of VoiceFlowCore so the test target never links WhisperKit.
        .target(
            name: "VoiceFlowWhisper",
            dependencies: [
                "VoiceFlowCore",
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .executableTarget(
            name: "VoiceFlowApp",
            dependencies: [
                "VoiceFlowCore",
                "VoiceFlowWhisper",
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .executableTarget(
            name: "VoiceFlowBench",
            dependencies: [
                "VoiceFlowCore",
                "VoiceFlowWhisper",
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .executableTarget(
            name: "VoiceFlowReplay",
            dependencies: ["VoiceFlowCore"]
        ),
        .executableTarget(
            name: "VoiceFlowTests",
            dependencies: ["VoiceFlowCore", "VoiceFlowTestKit"]
        )
    ]
)
