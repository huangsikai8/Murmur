import Foundation

/// Which stage of the pipeline a model serves.
public enum ModelLayer: String, Sendable, CaseIterable, Identifiable {
    case speechRecognition
    case correction

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .speechRecognition: "Speech recognition"
        case .correction: "AI correction"
        }
    }

    public var subtitle: String {
        switch self {
        case .speechRecognition: "Turns what you say into text, live as you speak."
        case .correction: "Tidies the transcript before it is inserted."
        }
    }
}

/// Whether a model is ready to use.
public enum ModelInstallState: Sendable, Equatable {
    /// Ships with macOS. Nothing to download and nothing to delete.
    case builtIn
    case installed
    case notInstalled
    case downloading(Double)
    /// Cannot be used on this machine, with the reason why.
    case unavailable(String)

    public var isUsable: Bool {
        switch self {
        case .builtIn, .installed: true
        default: false
        }
    }
}

/// How a model would actually be executed, which decides what Murmur needs in
/// order to offer it.
public enum ModelRuntime: String, Sendable, Equatable {
    /// Ships inside macOS. Nothing to fetch, nothing to build.
    case appleBuiltIn
    /// Core ML weights fetched at runtime, driven by the FluidAudio package.
    case coreML
    /// ONNX weights, which need an ONNX runtime linked in.
    case onnx
    /// Moonshine's own C++ core, which embeds ONNX Runtime.
    case moonshine
    /// MLX, which compiles Metal kernels at build time.
    case mlx

    /// What is still missing before this runtime can be offered, or `nil` when
    /// it is ready.
    public var blocker: String? {
        switch self {
        case .appleBuiltIn:
            return nil
        case .coreML:
            return ModelCatalog.coreMLEngineWired
                ? nil : "Engine not wired into this build yet."
        case .onnx:
            return ModelCatalog.onnxEngineWired
                ? nil : "Needs an ONNX runtime linked into Murmur."
        case .moonshine:
            return ModelCatalog.moonshineEngineWired
                ? nil : "Engine not wired into this build yet."
        case .mlx:
            return ModelCatalog.mlxSupported
                ? nil : "Requires the full Xcode toolchain (no Metal compiler in Command Line Tools)."
        }
    }
}

/// One selectable model.
public struct AIModelDescriptor: Identifiable, Sendable, Equatable {
    public let id: String
    public let layer: ModelLayer
    public let name: String
    public let vendor: String
    /// Approximate download size in megabytes. Zero means it is part of macOS.
    public let sizeMB: Int
    public let license: String
    /// Whether it produces text live while you speak. Only meaningful for the
    /// speech layer, where anything that does not stream is disqualified.
    public let streams: Bool
    public let runtime: ModelRuntime
    /// Whether the model punctuates and capitalizes on its own. Models that do
    /// not need the AI correction layer to be readable.
    public let punctuates: Bool
    public let summary: String

    public var sizeDescription: String {
        guard sizeMB > 0 else { return "Built in" }
        return sizeMB >= 1000
            ? String(format: "~%.1f GB", Double(sizeMB) / 1000) : "~\(sizeMB) MB"
    }
}

/// The models Murmur knows about, and whether each can run here.
public enum ModelCatalog {

    public static let appleSpeechID = "apple.speechanalyzer"
    public static let appleCorrectionID = "apple.foundationmodels"

    /// Flipped on once the corresponding engine is compiled into Murmur.
    public nonisolated(unsafe) static var mlxSupported = false
    public nonisolated(unsafe) static var coreMLEngineWired = false
    public nonisolated(unsafe) static var onnxEngineWired = false
    public nonisolated(unsafe) static var moonshineEngineWired = false

    public static let all: [AIModelDescriptor] = [
        // MARK: Speech to text
        AIModelDescriptor(
            id: "nvidia.nemotron-streaming-en-0.6b",
            layer: .speechRecognition,
            name: "NVIDIA Nemotron Streaming 0.6B (English)",
            vendor: "NVIDIA via FluidAudio",
            sizeMB: 1200,
            license: "NVIDIA Community Model License",
            streams: true,
            runtime: .coreML,
            punctuates: true,
            summary:
                "Cache-aware streaming FastConformer with an RNN-T decoder. The largest "
                + "and most accurate downloadable option here, at three latency tiers."
        ),
        AIModelDescriptor(
            id: "moonshine.streaming-medium",
            layer: .speechRecognition,
            name: "Moonshine Medium Streaming",
            vendor: "Useful Sensors",
            sizeMB: 1100,
            license: "MIT",
            streams: true,
            runtime: .moonshine,
            punctuates: true,
            summary:
                "Most accurate Moonshine tier. About 258 ms latency, roughly 44x faster "
                + "than Whisper Large v3."
        ),
        AIModelDescriptor(
            id: appleSpeechID,
            layer: .speechRecognition,
            name: "Apple SpeechAnalyzer",
            vendor: "Apple",
            sizeMB: 0,
            license: "Part of macOS",
            streams: true,
            runtime: .appleBuiltIn,
            punctuates: true,
            summary:
                "Streams partial text while you speak. Lowest latency here, and the only "
                + "option that needs no download."
        ),
        AIModelDescriptor(
            id: "moonshine.streaming-small",
            layer: .speechRecognition,
            name: "Moonshine Small Streaming",
            vendor: "Useful Sensors",
            sizeMB: 400,
            license: "MIT",
            streams: true,
            runtime: .moonshine,
            punctuates: true,
            summary:
                "About 148 ms latency, roughly 13x faster than Whisper Small. A lighter "
                + "trade against Moonshine Medium."
        ),
        AIModelDescriptor(
            id: "nvidia.parakeet-realtime-eou-120m",
            layer: .speechRecognition,
            name: "NVIDIA Parakeet Realtime EOU 120M",
            vendor: "NVIDIA via FluidAudio",
            sizeMB: 250,
            license: "Apache 2.0",
            streams: true,
            runtime: .coreML,
            punctuates: false,
            summary:
                "Smallest and fastest to download. English only. Produces lowercase "
                + "text with no punctuation, so it needs AI correction to be readable."
        ),

        AIModelDescriptor(
            id: ParakeetBatchEngine.modelID,
            layer: .speechRecognition,
            name: "NVIDIA Parakeet TDT 0.6B v2",
            vendor: "NVIDIA via FluidAudio",
            // 452 MB measured on disk. The HF repo totals ~2.6 GB because it
            // carries several precisions; FluidAudio fetches only one set.
            sizeMB: 452,
            license: "CC BY 4.0",
            streams: false,
            runtime: .coreML,
            punctuates: true,
            summary:
                "Decodes the whole utterance when you release the key, so no text "
                + "appears while you speak. The most accurate English model here "
                + "in exchange for that wait."
        ),

        // MARK: Text cleanup
        AIModelDescriptor(
            id: appleCorrectionID,
            layer: .correction,
            name: "Apple Foundation Model",
            vendor: "Apple",
            sizeMB: 0,
            license: "Part of macOS",
            streams: false,
            runtime: .appleBuiltIn,
            punctuates: true,
            summary: "On-device language model built into macOS 26. Nothing to download."
        ),
        AIModelDescriptor(
            id: "mlx.qwen3-4b",
            layer: .correction,
            name: "Qwen3 4B",
            vendor: "Alibaba via MLX",
            sizeMB: 2300,
            license: "Apache 2.0",
            streams: false,
            runtime: .mlx,
            punctuates: true,
            summary: "Strongest cleanup quality of these, at the cost of speed and memory."
        ),
        AIModelDescriptor(
            id: "mlx.gemma3-4b",
            layer: .correction,
            name: "Gemma 3 4B",
            vendor: "Google via MLX",
            sizeMB: 2500,
            license: "Gemma Terms of Use",
            streams: false,
            runtime: .mlx,
            punctuates: true,
            summary: "Comparable quality to Qwen3 4B, and well tuned for Apple Silicon."
        ),
        AIModelDescriptor(
            id: "mlx.qwen3-1.7b",
            layer: .correction,
            name: "Qwen3 1.7B",
            vendor: "Alibaba via MLX",
            sizeMB: 1000,
            license: "Apache 2.0",
            streams: false,
            runtime: .mlx,
            punctuates: true,
            summary: "Good balance of speed and quality for punctuation and filler removal."
        ),
        AIModelDescriptor(
            id: "mlx.gemma3-1b",
            layer: .correction,
            name: "Gemma 3 1B",
            vendor: "Google via MLX",
            sizeMB: 700,
            license: "Gemma Terms of Use",
            streams: false,
            runtime: .mlx,
            punctuates: true,
            summary: "Lightest download here. Fastest, with the least headroom for High."
        ),
    ]

    /// Which downloadable models are already on disk.
    public static func installedModelIDs() -> Set<String> {
        var ids: Set<String> = []
        for variant in FluidAudioEngine.Variant.allCases
        where FluidAudioEngine.isInstalled(variant) {
            ids.insert(variant.modelID)
        }
        for variant in MLXCleaner.Variant.allCases where MLXCleaner.isInstalled(variant) {
            ids.insert(variant.modelID)
        }
        for variant in MoonshineEngine.Variant.allCases
        where MoonshineEngine.isInstalled(variant) {
            ids.insert(variant.modelID)
        }
        if ParakeetBatchEngine.isInstalled { ids.insert(ParakeetBatchEngine.modelID) }
        return ids
    }

    /// Downloads the weights for a model, or throws if it is not downloadable.
    public static func install(
        _ descriptor: AIModelDescriptor,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if let variant = FluidAudioEngine.Variant.from(modelID: descriptor.id) {
            try await FluidAudioEngine(variant: variant).install()
            return
        }
        if let variant = MLXCleaner.Variant.from(modelID: descriptor.id) {
            try await MLXCleaner(variant: variant).install(progress: progress)
            return
        }
        if let variant = MoonshineEngine.Variant.from(modelID: descriptor.id) {
            try await MoonshineEngine(variant: variant).install(progress: progress)
            return
        }
        if descriptor.id == ParakeetBatchEngine.modelID {
            try await ParakeetBatchEngine().install()
            return
        }
        throw SpeechEngineError.unavailable("\(descriptor.name) cannot be downloaded yet.")
    }

    /// Removes the weights for a model.
    public static func delete(_ descriptor: AIModelDescriptor) throws {
        if let variant = FluidAudioEngine.Variant.from(modelID: descriptor.id) {
            try FluidAudioEngine.delete(variant)
            return
        }
        if let variant = MLXCleaner.Variant.from(modelID: descriptor.id) {
            try MLXCleaner.delete(variant)
            return
        }
        if let variant = MoonshineEngine.Variant.from(modelID: descriptor.id) {
            try MoonshineEngine.delete(variant)
            return
        }
        if descriptor.id == ParakeetBatchEngine.modelID {
            try ParakeetBatchEngine.delete()
        }
    }

    public static func models(in layer: ModelLayer) -> [AIModelDescriptor] {
        all.filter { $0.layer == layer }
    }

    public static func model(id: String) -> AIModelDescriptor? {
        all.first { $0.id == id }
    }

    /// Current state of one model on this machine.
    public static func state(
        for descriptor: AIModelDescriptor,
        appleSpeechAvailable: Bool,
        appleCorrectionUnavailableReason: String?,
        installedIDs: Set<String>
    ) -> ModelInstallState {
        switch descriptor.id {
        case appleSpeechID:
            return appleSpeechAvailable
                ? .builtIn : .unavailable("Not supported on this Mac.")
        case appleCorrectionID:
            if let reason = appleCorrectionUnavailableReason { return .unavailable(reason) }
            return .builtIn
        default:
            if let blocker = descriptor.runtime.blocker { return .unavailable(blocker) }
            return installedIDs.contains(descriptor.id) ? .installed : .notInstalled
        }
    }
}
