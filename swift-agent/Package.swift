// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDictationAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDictationAgent", targets: ["MacDictationAgent"]),
        .executable(name: "FluidDictationService", targets: ["FluidDictationService"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "5fc19fcde8aff5970ab18c974b109891479384c2"
        )
    ],
    targets: [
        .target(name: "DictationServiceProtocol"),
        .target(name: "LocalTTSServiceProtocol"),
        .executableTarget(
            name: "MacDictationAgent",
            dependencies: [
                "DictationServiceProtocol",
                "LocalTTSServiceProtocol",
            ]
        ),
        .executableTarget(
            name: "FluidDictationService",
            dependencies: [
                "DictationServiceProtocol",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
