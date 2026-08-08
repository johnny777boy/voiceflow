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
        .executable(name: "VoiceFlowTests", targets: ["VoiceFlowTests"])
    ],
    dependencies: [
        // On-device Whisper (Core ML / Neural Engine) for the optional High-Accuracy mode.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0")
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
        .executableTarget(
            name: "VoiceFlowApp",
            dependencies: [
                "VoiceFlowCore",
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .executableTarget(
            name: "VoiceFlowTests",
            dependencies: ["VoiceFlowCore", "VoiceFlowTestKit"]
        )
    ]
)
