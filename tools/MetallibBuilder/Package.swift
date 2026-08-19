// swift-tools-version: 6.0
import PackageDescription

// Exists only so xcodebuild will compile MLX's Metal kernels into
// mlx-swift_Cmlx.bundle. SwiftPM cannot compile .metal sources, and the main
// app cannot be built by xcodebuild because two of its binary dependencies
// collide over include/module.modulemap.
let package = Package(
    name: "MetallibBuilder",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.4")
    ],
    targets: [
        .executableTarget(
            name: "MetallibBuilder",
            dependencies: [.product(name: "MLX", package: "mlx-swift")]
        )
    ]
)
