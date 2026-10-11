// swift-tools-version: 6.0
import PackageDescription

// Offline comparison harness for speaker diarization. Not part of the app target.
let package = Package(
    name: "DiarizationBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Same version the app pins (Package.resolved).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "DiarizationBench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
