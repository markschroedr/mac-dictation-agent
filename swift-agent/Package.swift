// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacDictationAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDictationAgent", targets: ["MacDictationAgent"]),
        .executable(name: "FluidDictationService", targets: ["FluidDictationService"]),
        .executable(name: "SystemAudioCapture", targets: ["SystemAudioCapture"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "793a2c5a0e99705a55fefbad00e65ca684329349",
            traits: []
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
        .executableTarget(name: "SystemAudioCapture"),
        .executableTarget(
            name: "FluidDictationService",
            dependencies: [
                "DictationServiceProtocol",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
