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
            ]
        ),
    ]
)
