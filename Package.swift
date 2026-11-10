// swift-tools-version: 5.10
import PackageDescription
import Foundation

// Cloud builds need neither MLX nor the Metal compiler/model weights.
let cloudOnly = ProcessInfo.processInfo.environment["MEOW_CLOUD_ONLY"] == "1"
let mlxDependencies: [Target.Dependency] = cloudOnly ? [] : [
    .product(name: "MLXLLM", package: "mlx-swift-examples"),
    .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
]

let package = Package(
    name: "Meow",
    platforms: [.macOS("14.4")],
    dependencies: [.package(path: "vendor/iroh-ffi")] + (cloudOnly ? [] : [
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.29.1")
    ]),
    targets: [
        .target(name: "MeowCloud"),
        .target(name: "MeowMemory"),
        .target(name: "MeowNews"),
        .target(name: "MeowMemos"),
        .target(name: "MeowMailbox"),
        .target(name: "MeowIroh", dependencies: [.target(name: "MeowMailbox"), .product(name: "IrohLib", package: "iroh-ffi")]),
        .executableTarget(
            name: "Meow",
            dependencies: [.target(name: "MeowCloud"), .target(name: "MeowMemory"), .target(name: "MeowNews"), .target(name: "MeowMemos"), .target(name: "MeowMailbox"), .target(name: "MeowIroh")] + mlxDependencies,
            path: "Sources/Meow"
        ),
        .testTarget(name: "MeowCloudTests", dependencies: ["MeowCloud"]),
        .testTarget(name: "MeowMemoryTests", dependencies: ["MeowMemory"]),
        .testTarget(name: "MeowNewsTests", dependencies: ["MeowNews"]),
        .testTarget(name: "MeowMemosTests", dependencies: ["MeowMemos"]),
        .testTarget(name: "MeowMailboxTests", dependencies: ["MeowMailbox"]),
    ] + (cloudOnly ? [] : [
        .executableTarget(
            name: "meow-cli",
            dependencies: mlxDependencies,
            path: "Sources/MeowCLI"
        ),
    ])
)
