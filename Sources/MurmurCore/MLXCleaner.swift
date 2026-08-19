import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Cleanup backed by a downloadable local model running on MLX.
///
/// An alternative to Apple's built-in model, useful when Apple Intelligence is
/// unavailable or when a larger model gives better results. Weights are pulled
/// from Hugging Face on first use and cached; inference is entirely local.
public actor MLXCleaner: TranscriptCleaner {

    public static let cleanerName = "MLX (downloadable)"

    /// The models Murmur offers on this runtime.
    public enum Variant: String, Sendable, CaseIterable {
        case qwen3_4b
        case qwen3_1_7b
        case gemma3_4b
        case gemma3_1b

        public var modelID: String {
            switch self {
            case .qwen3_4b: "mlx.qwen3-4b"
            case .qwen3_1_7b: "mlx.qwen3-1.7b"
            case .gemma3_4b: "mlx.gemma3-4b"
            case .gemma3_1b: "mlx.gemma3-1b"
            }
        }

        /// Hugging Face repository holding the 4-bit MLX weights.
        public var repositoryID: String {
            switch self {
            case .qwen3_4b: "mlx-community/Qwen3-4B-4bit"
            case .qwen3_1_7b: "mlx-community/Qwen3-1.7B-4bit"
            case .gemma3_4b: "mlx-community/gemma-3-4b-it-4bit"
            case .gemma3_1b: "mlx-community/gemma-3-1b-it-qat-4bit"
            }
        }

        public static func from(modelID: String) -> Variant? {
            allCases.first { $0.modelID == modelID }
        }

        /// Qwen3 reasons before answering, emitting a `<think>` block that is
        /// not part of the cleaned text. Suppressing it with `/no_think` makes
        /// the model lazy — it echoes the input back — so the reasoning is left
        /// on and stripped from the reply instead. That needs a higher token
        /// budget, since the thinking is spent before the answer begins.
        public var reasons: Bool {
            switch self {
            case .qwen3_4b, .qwen3_1_7b: true
            case .gemma3_4b, .gemma3_1b: false
            }
        }

        /// Token budget for one cleanup, including any reasoning.
        public var maximumTokens: Int {
            reasons ? 1024 : 320
        }

        /// Gemma 3 above 1B ships only as a vision-language model, so it loads
        /// through the VLM factory. The text-only loader rejects those weights
        /// outright with a shape mismatch.
        public var isVisionLanguageModel: Bool {
            switch self {
            case .gemma3_4b: true
            default: false
            }
        }
    }

    private let variant: Variant
    private var container: ModelContainer?
    private var protectedTerms: [VocabularyTerm] = []

    public init(variant: Variant) {
        self.variant = variant
    }

    // MARK: - Installation

    /// The Hugging Face hub cache, which uses a `models--org--name` layout.
    public static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// The cache folder for one variant, following the hub's naming scheme.
    static func cacheFolder(for variant: Variant) -> URL {
        let mangled = "models--" + variant.repositoryID.replacingOccurrences(of: "/", with: "--")
        return cacheDirectory.appendingPathComponent(mangled, isDirectory: true)
    }

    public static func isInstalled(_ variant: Variant) -> Bool {
        let folder = cacheFolder(for: variant)
        guard
            let entries = FileManager.default.enumerator(atPath: folder.path)?
                .allObjects as? [String]
        else { return false }
        // Weights present means the model is usable; config alone is not enough.
        return entries.contains { $0.hasSuffix(".safetensors") }
    }

    public static func delete(_ variant: Variant) throws {
        let folder = cacheFolder(for: variant)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Downloads and loads the weights. Needs a network connection the first time.
    public func install(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let configuration = ModelConfiguration(id: variant.repositoryID)

        if variant.isVisionLanguageModel {
            // No macro covers the VLM factory, so the downloader and tokenizer
            // loader are composed by hand from the same macros it would use.
            container = try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration
            ) { reported in
                progress?(reported.fractionCompleted)
            }
            return
        }

        container = try await #huggingFaceLoadModelContainer(configuration: configuration) {
            reported in
            progress?(reported.fractionCompleted)
        }
    }

    // MARK: - TranscriptCleaner

    public func prepare() async throws {
        guard container == nil else { return }
        try await install()
    }

    public func setProtectedTerms(_ terms: [String]) {
        protectedTerms = terms.map { VocabularyTerm($0) }
    }

    public func setProtectedVocabulary(_ terms: [VocabularyTerm]) {
        protectedTerms = terms
    }

    public func clean(_ text: String, level: CleanupLevel) async throws -> String {
        guard level != .off else { return text }
        try await prepare()
        guard let container else {
            throw CleanupError.unavailable("\(variant.repositoryID) is not loaded.")
        }

        // A fresh session per transcript: one dictation must never influence
        // the next.
        let session = ChatSession(
            container,
            instructions: instructions(for: level),
            generateParameters: .init(maxTokens: variant.maximumTokens)
        )
        let reply = try await session.respond(to: FoundationModelsCleaner.wrap(text))

        return CleanupGuard.accept(
            original: text,
            cleaned: Self.stripReasoning(reply),
            level: level,
            knownTerms: protectedTerms.map(\.text)
        )
    }

    /// Removes a reasoning block from a model that emits one anyway.
    ///
    /// Kept separate from the prompt switch because a truncated response can
    /// leave an unclosed `<think>` tag, which must not be pasted as text.
    public static func stripReasoning(_ reply: String) -> String {
        var text = reply
        while let start = text.range(of: "<think>") {
            if let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                // Unclosed: the model ran out of tokens mid-thought.
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Both the model's raw reply and the guarded result, for diagnosing which
    /// of the two changed the text.
    public func cleanDetailed(
        _ text: String,
        level: CleanupLevel
    ) async throws -> (raw: String, accepted: String) {
        guard level != .off else { return (text, text) }
        try await prepare()
        guard let container else {
            throw CleanupError.unavailable("\(variant.repositoryID) is not loaded.")
        }
        let session = ChatSession(
            container,
            instructions: instructions(for: level),
            generateParameters: .init(maxTokens: variant.maximumTokens)
        )
        let reply = try await session.respond(to: FoundationModelsCleaner.wrap(text))
        let stripped = Self.stripReasoning(reply)
        return (
            stripped,
            CleanupGuard.accept(
                original: text,
                cleaned: stripped,
                level: level,
                knownTerms: protectedTerms.map(\.text)
            )
        )
    }

    private func instructions(for level: CleanupLevel) -> String {
        level.instructions + protectedTermsClause
    }

    /// Same protection the built-in cleaner applies, so switching models does
    /// not change how your own terminology is treated.
    private var protectedTermsClause: String {
        guard !protectedTerms.isEmpty else { return "" }
        var sections: [String] = []
        let names = protectedTerms.map(\.text).joined(separator: ", ")
        sections.append(
            "These are the speaker's own terms. Keep them exactly as written, and "
                + "never replace them with a similar-sounding word: \(names)."
        )
        let confusable = protectedTerms.filter { !$0.soundsLike.isEmpty }
        if !confusable.isEmpty {
            let lines = confusable.map { term in
                "\"\(term.text)\" is often misheard as "
                    + term.soundsLike.map { "\"\($0)\"" }.joined(separator: " or ")
            }
            sections.append(
                "Speech recognition confuses these words: \(lines.joined(separator: "; ")). "
                    + "When the surrounding sentence makes clear the speaker meant the term, "
                    + "correct it. When the ordinary everyday word is what they meant, leave "
                    + "it alone."
            )
        }
        return "\n\n" + sections.joined(separator: "\n\n")
    }

    public func releaseModels() async {
        container = nil
    }
}
