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

        /// Qwen3 emits a `<think>` block before answering, which is not part
        /// of the cleaned text. Whether it is allowed to fill that block is a
        /// separate decision — see `Reasoning`, which defaults to suppressing
        /// it. This flag only says the model has the machinery, so it is worth
        /// measuring both ways.
        public var reasons: Bool {
            switch self {
            case .qwen3_4b, .qwen3_1_7b: true
            case .gemma3_4b, .gemma3_1b: false
            }
        }

        /// Token budget when reasoning is allowed to run. A cleanup answer is
        /// 9–27 tokens; the rest of this exists only to hold the `<think>`
        /// block, and measured at 96–100% of the reply it usually does.
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

    /// Whether a reasoning model is allowed to think before answering.
    ///
    /// Qwen3 accepts `/no_think` as an in-prompt switch. It is a measurable
    /// choice rather than a fixed property of the model, so it is settable:
    /// reasoning is where a cleanup pass spends almost all of its time, and
    /// the trade against quality has to be re-measured, not assumed.
    public enum Reasoning: Sendable {
        /// Let the model reason, and strip the `<think>` block from the reply.
        case allowed
        /// Append `/no_think` to the prompt.
        case suppressed
    }

    /// What one generation actually cost, for telling a slow model apart from
    /// a verbose one. The raw reply is kept intact, `<think>` included,
    /// because a budget spent entirely on reasoning is invisible once the
    /// block has been stripped.
    public struct Stats: Sendable {
        public let promptTokens: Int
        public let generatedTokens: Int
        public let promptMs: Int
        public let generateMs: Int
        public let tokensPerSecond: Double
        /// Tokens inside `<think>`, estimated from its share of the reply.
        public let thinkingCharacters: Int
        public let replyCharacters: Int
    }

    private let variant: Variant
    private let reasoning: Reasoning
    private var container: ModelContainer?
    private var protectedTerms: [VocabularyTerm] = []

    /// Reasoning is suppressed by default. Measured on the six cleanup
    /// samples, Qwen3 4B spent 96–100% of every reply inside `<think>` and
    /// took 26–111 s; with `/no_think` it generates 13–27 tokens in 2.8–8.3 s
    /// and produces the same text on five of six. On the sixth the reasoning
    /// arm exhausted its 1024-token budget without ever reaching an answer, so
    /// suppressing it was strictly better there — 111 s and nothing usable,
    /// against 4.8 s and text with fillers and repetitions removed.
    public init(variant: Variant, reasoning: Reasoning = .suppressed) {
        self.variant = variant
        self.reasoning = reasoning
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
        guard let entries = FileManager.default.enumerator(atPath: folder.path) else {
            return false
        }
        // Weights present means the model is usable; config alone is not enough.
        // Consumed lazily rather than through `allObjects`, which bridges every
        // entry in a multi-gigabyte hub cache into a String before testing any.
        for case let path as String in entries where path.hasSuffix(".safetensors") {
            return true
        }
        return false
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

    /// Qwen3's in-prompt switch, placed on the user turn because the last
    /// occurrence in the conversation is the one that takes effect.
    private var promptSuffix: String {
        guard variant.reasons, reasoning == .suppressed else { return "" }
        return " /no_think"
    }

    /// A model that has been told not to think does not need the budget that
    /// thinking required, and leaving it high would hide a regression: a
    /// `/no_think` that silently failed would still fit its reasoning inside
    /// 1024 tokens and only show up as time.
    private var tokenBudget: Int {
        guard variant.reasons, reasoning == .suppressed else { return variant.maximumTokens }
        return 320
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
            generateParameters: .init(maxTokens: tokenBudget)
        )
        let reply = try await session.respond(
            to: FoundationModelsCleaner.wrap(text) + promptSuffix)

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

    /// The model's raw reply, the guarded result, and what the generation
    /// cost. Used by `--testcleanup-mlx` to tell three different failures
    /// apart: a model that is slow, a model that is verbose, and a model that
    /// spent its whole budget reasoning and never reached an answer.
    public func cleanDetailed(
        _ text: String,
        level: CleanupLevel
    ) async throws -> (raw: String, accepted: String, stats: Stats?) {
        guard level != .off else { return (text, text, nil) }
        try await prepare()
        guard let container else {
            throw CleanupError.unavailable("\(variant.repositoryID) is not loaded.")
        }
        let session = ChatSession(
            container,
            instructions: instructions(for: level),
            generateParameters: .init(maxTokens: tokenBudget)
        )

        var reply = ""
        var stats: Stats?
        let stream = session.streamDetails(to: FoundationModelsCleaner.wrap(text) + promptSuffix)
        for try await item in stream {
            switch item {
            case .chunk(let chunk):
                reply += chunk
            case .info(let info):
                stats = Stats(
                    promptTokens: info.promptTokenCount,
                    generatedTokens: info.generationTokenCount,
                    promptMs: Int(info.promptTime * 1000),
                    generateMs: Int(info.generateTime * 1000),
                    tokensPerSecond: info.tokensPerSecond,
                    thinkingCharacters: Self.thinkingCharacters(reply),
                    replyCharacters: reply.count)
            default:
                break
            }
        }

        let stripped = Self.stripReasoning(reply)
        return (
            reply,
            CleanupGuard.accept(
                original: text,
                cleaned: stripped,
                level: level,
                knownTerms: protectedTerms.map(\.text)
            ),
            stats
        )
    }

    /// Characters enclosed in `<think>`, counting an unclosed block to the end
    /// of the reply — that is the case worth seeing, since it means the budget
    /// ran out before the answer began.
    static func thinkingCharacters(_ reply: String) -> Int {
        var total = 0
        var cursor = reply.startIndex
        while let open = reply.range(of: "<think>", range: cursor..<reply.endIndex) {
            let close = reply.range(of: "</think>", range: open.upperBound..<reply.endIndex)
            let stop = close?.upperBound ?? reply.endIndex
            total += reply.distance(from: open.lowerBound, to: stop)
            guard close != nil else { break }
            cursor = stop
        }
        return total
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
