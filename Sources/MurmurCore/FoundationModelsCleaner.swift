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

    /// A session built and prewarmed *before* the utterance that will use it.
    ///
    /// Every session is still used for exactly one transcript — history bleed
    /// between dictations is a correctness rule, not a performance choice. What
    /// changes is when the session is built. Its instructions are roughly a
    /// kilobyte of rules plus three worked examples, and prefilling that was
    /// happening after the speaker stopped talking, inside the wait. Building
    /// the replacement straight after each use moves the prefill into the gap
    /// between utterances, where nobody is waiting on it.
    private var spare: (key: SessionKey, session: LanguageModelSession)?

    /// What a prepared session was built for. One prepared for a different
    /// level, or for a word list that has since been edited, carries the wrong
    /// instructions and must be discarded rather than reused.
    private struct SessionKey: Equatable {
        let level: CleanupLevel
        let clause: String
    }

    private let model: SystemLanguageModel

    /// Terms the model must not "correct" into something else, along with the
    /// words the recognizer tends to hear instead.
    private var protectedTerms: [VocabularyTerm] = []

    /// Updates the terms protected from rewriting.
    public func setProtectedTerms(_ terms: [String]) {
        protectedTerms = terms.map { VocabularyTerm($0) }
        spare = nil
    }

    /// Updates the terms, including the homophones each is misheard as.
    public func setProtectedVocabulary(_ terms: [VocabularyTerm]) {
        protectedTerms = terms
        spare = nil
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

    /// Prepares a session for the level that is about to be used, so the first
    /// utterance after a level change does not pay the prefill the rest avoid.
    ///
    /// Without this, switching to Medium leaves a spare built for Light, which
    /// cannot be reused — and the level is chosen long before anyone speaks.
    public func prepareLevel(_ level: CleanupLevel) {
        guard level != .off, model.isAvailable else { return }
        let key = SessionKey(level: level, clause: protectedTermsClause)
        guard spare?.key != key else { return }
        replenish(for: key)
    }

    public func clean(_ text: String, level: CleanupLevel) async throws -> String {
        guard level != .off else { return text }
        guard model.isAvailable else {
            throw CleanupError.unavailable(Self.unavailableReason ?? "Unavailable.")
        }

        // A fresh session per transcript: sessions accumulate history, and one
        // dictation must never influence the next. Prepared ahead of time when
        // the level and word list have not changed since the last one.
        let key = SessionKey(level: level, clause: protectedTermsClause)
        let session = takeSession(for: key)
        // Replenished afterwards rather than before: prewarming the next
        // session while this one is generating would have the two contending
        // for the same model, which is the opposite of the point.
        defer { replenish(for: key) }

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

    /// The prepared session when it was built for exactly this level and word
    /// list, or a new one built on the spot. Either way it is consumed here and
    /// never handed to a second transcript.
    private func takeSession(for key: SessionKey) -> LanguageModelSession {
        defer { spare = nil }
        if let spare, spare.key == key { return spare.session }
        return makeSession(for: key)
    }

    private func replenish(for key: SessionKey) {
        let session = makeSession(for: key)
        session.prewarm()
        spare = (key, session)
    }

    private func makeSession(for key: SessionKey) -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: key.level.instructions + key.clause)
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
                    + "\"Claude\", but \"I stored the file in the cloud\" does not. "
                    + "This correction is required at every strength, and overrides any "
                    + "instruction above to keep every word exactly as spoken — a misheard "
                    + "term is a recognition error, not a wording choice."
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
        // The same prepared-session path as `clean`, or this would measure a
        // pipeline the app never runs.
        let key = SessionKey(level: level, clause: protectedTermsClause)
        let session = takeSession(for: key)
        defer { replenish(for: key) }
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
        spare = nil
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
