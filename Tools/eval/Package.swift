// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tx-eval",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "tx-eval",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources"
        ),
    ]
)
