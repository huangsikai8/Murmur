// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Core ML streaming ASR engines (Parakeet EOU, Nemotron). Apache 2.0.
        // Model weights are fetched at runtime, never bundled.
        .package(path: "/private/tmp/claude-501/-Users-sikaihuang-Projects-Murmur/09b3cd93-e08d-4670-a83f-a9c365c53e6e/scratchpad/FluidAudio"),
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
        // Speech models on MLX: Cohere Transcribe and IBM Granite Speech 4.1.
        // MIT. It carries no Metal sources of its own, so the metallib built by
        // tools/MetallibBuilder is all it needs.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", from: "0.1.3"),
        // IBM Granite Speech 5.0 TurboCTC and its punctuation model. MIT or
        // Apache 2.0. It pins mlx-swift exactly, which is what pins it below.
        .package(url: "https://github.com/kylehowells/Granite-MLX", exact: "0.1.1"),
        // Exact, because Granite-MLX requires it and because the metallib in
        // tools/MetallibBuilder has to be built from the same version.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
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
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "GraniteMLX", package: "Granite-MLX"),
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
