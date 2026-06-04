// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MagpieRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MagpieCore",
            path: "Sources",
            exclude: [
                "App.swift",
                "RecorderView.swift",
                "OnboardingView.swift",
                "EqualizerView.swift",
                "FloatingPillView.swift",
            ]
        ),
        // No XCTest or runnable Swift Testing on this Command Line Tools
        // install (no Xcode; the bundled Testing.framework is missing its
        // runtime interop dylib). Tests run as a plain executable with a small
        // assert harness — `swift run MagpieCoreTests`.
        .executableTarget(
            name: "MagpieCoreTests",
            dependencies: ["MagpieCore"],
            path: "Tests/MagpieCore"
        ),
    ]
)
