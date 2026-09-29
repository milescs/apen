// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UtterKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "UtterCore", targets: ["UtterCore"]),
        .library(name: "UtterEngines", targets: ["UtterEngines"]),
        .executable(name: "utter", targets: ["utter-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11146/llama-b11146-xcframework.zip",
            checksum: "1c306afe9fe68a90c4bdc74619d8558d6e0754f085deb105dd2d70293a9a964f"
        ),
        .target(
            name: "UtterCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "UtterEngines",
            dependencies: [
                "UtterCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                "llama",
            ]
        ),
        .executableTarget(name: "utter-cli", dependencies: ["UtterEngines"]),
        .testTarget(name: "UtterCoreTests", dependencies: ["UtterCore"]),
        .testTarget(name: "UtterEnginesTests", dependencies: ["UtterEngines"]),
    ]
)
