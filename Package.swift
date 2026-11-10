// swift-tools-version: 5.10
import PackageDescription
import Foundation

// Cloud builds need neither MLX nor the Metal compiler/model weights.
let cloudOnly = ProcessInfo.processInfo.environment["KOKOSUKI_CLOUD_ONLY"] == "1"
let mlxDependencies: [Target.Dependency] = cloudOnly ? [] : [
    .product(name: "MLXLLM", package: "mlx-swift-examples"),
    .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
]

let package = Package(
    name: "Kokosuki",
    platforms: [.macOS("14.4")],
    dependencies: [.package(path: "vendor/iroh-ffi")] + (cloudOnly ? [] : [
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.29.1")
    ]),
    targets: [
        .target(name: "KokosukiCloud"),
        .target(name: "KokosukiMemory"),
        .target(name: "KokosukiNews"),
        .target(name: "KokosukiMemos"),
        .target(name: "KokosukiMailbox"),
        .target(name: "KokosukiIroh", dependencies: [.target(name: "KokosukiMailbox"), .product(name: "IrohLib", package: "iroh-ffi")]),
        .executableTarget(
            name: "Kokosuki",
            dependencies: [.target(name: "KokosukiCloud"), .target(name: "KokosukiMemory"), .target(name: "KokosukiNews"), .target(name: "KokosukiMemos"), .target(name: "KokosukiMailbox"), .target(name: "KokosukiIroh")] + mlxDependencies,
            path: "Sources/Kokosuki"
        ),
        .testTarget(name: "KokosukiCloudTests", dependencies: ["KokosukiCloud"]),
        .testTarget(name: "KokosukiMemoryTests", dependencies: ["KokosukiMemory"]),
        .testTarget(name: "KokosukiNewsTests", dependencies: ["KokosukiNews"]),
        .testTarget(name: "KokosukiMemosTests", dependencies: ["KokosukiMemos"]),
        .testTarget(name: "KokosukiMailboxTests", dependencies: ["KokosukiMailbox"]),
    ] + (cloudOnly ? [] : [
        .executableTarget(
            name: "kokosuki-cli",
            dependencies: mlxDependencies,
            path: "Sources/KokosukiCLI"
        ),
    ])
)
