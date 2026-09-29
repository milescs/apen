// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ApenKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ApenCore", targets: ["ApenCore"]),
        .library(name: "ApenEngines", targets: ["ApenEngines"]),
        .executable(name: "apen", targets: ["apen-cli"]),
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
            name: "ApenCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "ApenEngines",
            dependencies: [
                "ApenCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                "llama",
            ]
        ),
        .executableTarget(name: "apen-cli", dependencies: ["ApenEngines"]),
        .testTarget(
            name: "ApenCoreTests",
            dependencies: ["ApenCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "ApenEnginesTests", dependencies: ["ApenEngines"]),
    ]
)
