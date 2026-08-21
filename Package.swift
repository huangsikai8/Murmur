// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Core ML streaming ASR engines (Parakeet EOU, Nemotron). Apache 2.0.
        // Model weights are fetched at runtime, never bundled.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
        // Downloadable local LLMs for the cleanup layer. Requires the Metal
        // toolchain, so a full Xcode install is needed to build this target.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // Moonshine streaming ASR. Its C++ core embeds ONNX Runtime, so no
        // separate runtime dependency is needed.
        .package(url: "https://github.com/moonshine-ai/moonshine-swift", branch: "main"),
        // Whisper on Core ML. Pure Swift with no binary targets, so it does not
        // hit the duplicate `module.modulemap` that keeps this build on SwiftPM.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
    ],
    targets: [
        // ONNX Runtime C API headers only. The implementation is already in the
        // binary: moonshine-swift's static library embeds ORT 1.23.0 and
        // exports its C entry points, so smart-turn runs on that runtime
        // without adding a second copy. Requesting ORT_API_VERSION 23 matches
        // the embedded build exactly.
        .target(name: "COnnxRuntime"),
        .target(
            name: "MurmurCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MoonshineVoice", package: "moonshine-swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                "COnnxRuntime",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MurmurApp",
            dependencies: ["MurmurCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Dependency-free test runner. XCTest and Swift Testing both ship only
        // with full Xcode; this runs under Command Line Tools alone via
        // `swift run MurmurTests`.
        .executableTarget(
            name: "MurmurTests",
            dependencies: ["MurmurCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
