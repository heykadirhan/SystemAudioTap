// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SystemAudioTap",
    platforms: [
        // Core Audio process taps arrived in macOS 14.2.
        .macOS("14.2")
    ],
    products: [
        .library(name: "SystemAudioTap", targets: ["SystemAudioTap"]),
        .executable(name: "tap-demo", targets: ["tap-demo"])
    ],
    targets: [
        .target(
            name: "AudioTapBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SystemAudioTap",
            dependencies: ["AudioTapBridge"],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "tap-demo",
            dependencies: ["SystemAudioTap"],
            path: "Examples/tap-demo"
        ),
        // C checks, run from Tests/SystemAudioTapTests/CTests.swift.
        .target(
            name: "AudioTapBridgeTests",
            dependencies: ["AudioTapBridge"]
        ),
        .testTarget(
            name: "SystemAudioTapTests",
            dependencies: ["SystemAudioTap", "AudioTapBridgeTests"]
        )
    ]
)
