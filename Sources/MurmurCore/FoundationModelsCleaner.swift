import Foundation
import FoundationModels

/// Cleanup backed by Apple's on-device language model, built into macOS 26.
///
/// Nothing is downloaded and nothing leaves the machine. Sampling is greedy so
/// the same transcript always cleans to the same text, which matters when the
/// output is pasted straight into your work.
public actor FoundationModelsCleaner: TranscriptCleaner {

    public static let cleanerName = "Apple Foundation Models (on-device)"

    /// Kept only to hold the model in memory between dictations.
    private var warmSession: LanguageModelSession?

    private let model: SystemLanguageModel

    /// Terms the model must not "correct" into something else, along with the
    /// words the recognizer tends to hear instead.
    private var protectedTerms: [VocabularyTerm] = []

    /// Updates the terms protected from rewriting.
    public func setProtectedTerms(_ terms: [String]) {
        protectedTerms = terms.map { VocabularyTerm($0) }
    }

    /// Updates the terms, including the homophones each is misheard as.
    public func setProtectedVocabulary(_ terms: [VocabularyTerm]) {
        protectedTerms = terms
    }

    public init() {
        // Text transformation, not open-ended chat: the permissive guardrail
        // avoids refusals on ordinary dictation that merely sounds sensitive.
        model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
    }

    public nonisolated static var isSupported: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Why the model cannot be used, or `nil` when it can.
    public nonisolated static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This Mac is not eligible."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in System Settings."
            case .modelNotReady: return "The model is still downloading."
            @unknown default: return "Unavailable."
            }
        }
    }

    public func prepare() async throws {
        guard model.isAvailable else {
            throw CleanupError.unavailable(Self.unavailableReason ?? "Unavailable.")
        }
        guard warmSession == nil else { return }
        let session = LanguageModelSession(model: model, instructions: CleanupLevel.light.instructions)
        session.prewarm()
        warmSession = session
    }

    public func clean(_ text: String, level: CleanupLevel) async throws -> String {
        guard level != .off else { return text }
        guard model.isAvailable else {
            throw CleanupError.unavailable(Self.unavailableReason ?? "Unavailable.")
        }

        // A fresh session per transcript: sessions accumulate history, and one
        // dictation must never influence the next.
        let session = LanguageModelSession(
            model: model,
            instructions: level.instructions + protectedTermsClause
        )

        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: max(64, text.count / 2 + 128)
        )

        let response = try await session.respond(to: Self.wrap(text), options: options)
        return CleanupGuard.accept(
            original: text,
            cleaned: response.content,
            level: level,
            knownTerms: protectedTerms.map(\.text)
        )
    }

    /// Tells the model to leave the user's own terminology alone. Spelling is
    /// still enforced deterministically afterwards; this only stops the model
    /// from rewriting an unfamiliar term into a familiar one.
    private var protectedTermsClause: String {
        guard !protectedTerms.isEmpty else { return "" }

        var sections: [String] = []
        let names = protectedTerms.map(\.text).joined(separator: ", ")
        sections.append(
            "These are the speaker's own terms. Keep them exactly as written, and "
                + "never replace them with a similar-sounding word: \(names)."
        )

        // Homophone repair belongs here rather than in a blind find-and-replace,
        // because only the surrounding words reveal which meaning was intended.
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
                    + "it alone. For example, \"I asked cloud to review my code\" means "
                    + "\"Claude\", but \"I stored the file in the cloud\" does not."
            )
        }

        return "\n\n" + sections.joined(separator: "\n\n")
    }

    /// Fences the transcript so the model treats it as data to rewrite rather
    /// than as something addressed to it. Without this, dictating a question
    /// reliably produces an answer or a refusal.
    public static func wrap(_ text: String) -> String {
        """
        Rewrite the transcript between the markers. Output only the rewritten         transcript, with no markers and no commentary.

        <<<TRANSCRIPT
        \(text)
        TRANSCRIPT>>>
        """
    }

    /// Both the model's raw reply and the guarded result, for diagnosing which
    /// of the two changed the text.
    public func cleanDetailed(
        _ text: String,
        level: CleanupLevel
    ) async throws -> (raw: String, accepted: String) {
        guard level != .off else { return (text, text) }
        let session = LanguageModelSession(model: model, instructions: level.instructions)
        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: max(64, text.count / 2 + 128)
        )
        let response = try await session.respond(to: Self.wrap(text), options: options)
        return (
            response.content,
            CleanupGuard.accept(
                original: text,
                cleaned: response.content,
                level: level,
                knownTerms: protectedTerms.map(\.text)
            )
        )
    }

    public func releaseModels() async {
        warmSession = nil
    }
}

public enum CleanupError: LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): "Cleanup model unavailable. \(detail)"
        }
    }
}
