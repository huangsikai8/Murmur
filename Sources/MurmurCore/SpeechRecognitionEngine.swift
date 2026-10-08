import AVFoundation
import Foundation

/// One update from a streaming recognizer.
public struct TranscriptUpdate: Sendable, Equatable {
    /// The text of this result only, not the whole transcript so far.
    public let text: String
    /// `false` means speculative: it may be revised or withdrawn.
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public enum SpeechEngineError: LocalizedError {
    case unavailable(String)
    case modelNotInstalled(String)
    case noSession
    case audioFormatUnavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): "Speech engine unavailable: \(detail)"
        case .modelNotInstalled(let detail): "Speech model not installed: \(detail)"
        case .noSession: "No active recognition session."
        case .audioFormatUnavailable: "Could not determine a compatible audio format."
        }
    }
}

/// Streaming speech-to-text, abstracted so the backing model can be swapped
/// without touching the capture, overlay, or insertion layers.
///
/// Lifecycle: `prepare()` once at launch, then per dictation
/// `beginSession()` -> `append(_:)` many times -> `finishSession()`.
public protocol SpeechRecognitionEngine: AnyObject, Sendable {

    /// Human-readable name, shown in the menu bar.
    static var engineName: String { get }

    /// Audio format the engine wants buffers in. `nil` accepts the hardware format.
    func preferredInputFormat() async -> AVAudioFormat?

    /// Loads and warms models. Safe to call repeatedly; later calls are cheap.
    func prepare() async throws

    /// Starts a session. Updates arrive on the returned stream until
    /// `finishSession()` or `cancelSession()` completes.
    func beginSession() async throws -> AsyncStream<TranscriptUpdate>

    /// Feeds captured audio. Must not block the audio thread.
    func append(_ buffer: AVAudioPCMBuffer)

    /// Ends audio input, flushes the recognizer, returns the final transcript.
    func finishSession() async throws -> String

    /// Abandons the session without producing a transcript.
    func cancelSession() async

    /// Drops models from memory to reclaim RAM.
    func releaseModels() async

    /// Terms to bias recognition toward, so unusual words are actually heard.
    func setContextualPhrases(_ phrases: [String]) async

    /// Text already on screen where this transcript will land, for engines that
    /// take free-text context. Unlike a phrase list this can change *which*
    /// words come back, so it reaches recognition rather than only the cleanup
    /// pass that follows it. A requirement rather than an extension member
    /// only, for the reason `biasesTowardPhrases` carries: the app asks through
    /// `any SpeechRecognitionEngine`, where an extension-only member is
    /// dispatched statically and every engine would answer with the no-op.
    func setSurroundingText(_ text: String) async

    /// Whether text appears while you speak, rather than only on release.
    ///
    /// Asked of the engine rather than read off the catalog, because the
    /// catalog is a claim and this is the behaviour. A model wrongly marked
    /// live shows an empty overlay for the whole hold and reads as broken.
    nonisolated var streamsLiveText: Bool { get }

    /// Whether `setContextualPhrases` does anything at all — see the default.
    ///
    /// A requirement, not only an extension member: the app asks through
    /// `any SpeechRecognitionEngine`, and an extension-only property is
    /// dispatched statically there, so every engine answered `false` and the
    /// log said Apple's recognizer ignored a vocabulary it was applying.
    nonisolated var biasesTowardPhrases: Bool { get }
}

extension SpeechRecognitionEngine {
    /// Engines with nowhere to put free text ignore it, which is all of them
    /// but Qwen3-ASR.
    public func setSurroundingText(_ text: String) async {}

    /// Engines without contextual biasing simply ignore the word list.
    public func setContextualPhrases(_ phrases: [String]) async {}

    /// Most engines emit partials as they go; the batch ones say otherwise.
    public nonisolated var streamsLiveText: Bool { true }

    /// Whether `setContextualPhrases` does anything at all.
    ///
    /// The default above is an empty implementation, which is convenient and
    /// silent: an engine that ignores biasing looks identical to one that
    /// applies it, so a word list can sit in Settings doing nothing while the
    /// speaker keeps wondering why their own terms are misheard. Engines that
    /// really bias say so, and the app logs when the selected one does not.
    public nonisolated var biasesTowardPhrases: Bool { false }
}

/// Builds the engine for a catalog model ID.
///
/// This lives in one place on purpose. The app and `--selftest` each used to
/// carry their own copy of this branch, they drifted apart, and Moonshine ran
/// only under the self-test while the app silently fell back to Apple's
/// recognizer — passing measurements on a path the app never took.
public enum SpeechEngineFactory {

    /// The engine backing `modelID`, or `nil` when no engine implements it.
    /// Callers that must produce something should fall back explicitly, so the
    /// substitution is a visible decision rather than a silent default.
    public static func engine(for modelID: String) -> (any SpeechRecognitionEngine)? {
        if modelID == ModelCatalog.appleSpeechID { return AppleSpeechEngine() }
        if let variant = FluidAudioEngine.Variant.from(modelID: modelID) {
            return FluidAudioEngine(variant: variant)
        }
        if let variant = MoonshineEngine.Variant.from(modelID: modelID) {
            return MoonshineEngine(variant: variant)
        }
        if modelID == ParakeetBatchEngine.modelID { return ParakeetBatchEngine() }
        if modelID == CohereCoreMLEngine.modelID { return CohereCoreMLEngine() }
        if let variant = WhisperEngine.Variant.from(modelID: modelID) {
            return WhisperEngine(variant: variant)
        }
        if let variant = MLXAudioEngine.Variant.from(modelID: modelID) {
            return MLXAudioEngine(variant: variant)
        }
        if let variant = GraniteCTCEngine.Variant.from(modelID: modelID) {
            return GraniteCTCEngine(variant: variant)
        }
        return nil
    }

    /// Whether `modelID`'s engine produces text while you speak, rather than
    /// only when the key is released. Derived from the engine that would
    /// actually run, so a catalog entry cannot claim live text it never emits.
    public static func streamsLiveText(for modelID: String) -> Bool? {
        engine(for: modelID)?.streamsLiveText
    }

    /// Speech models whose catalog `streams` flag disagrees with the engine
    /// behind them. A model wrongly marked live shows an empty overlay for the
    /// whole hold and reads as broken.
    public static var mislabeledSpeechModelIDs: [String] {
        ModelCatalog.models(in: .speechRecognition).filter { descriptor in
            guard let streams = streamsLiveText(for: descriptor.id) else { return false }
            return streams != descriptor.streams
        }.map(\.id)
    }

    /// Whether every speech model in the catalog can actually be instantiated.
    /// A model offered in Settings that lands here unbuilt would run as Apple's
    /// recognizer under another name.
    public static var unimplementedSpeechModelIDs: [String] {
        ModelCatalog.models(in: .speechRecognition)
            .map(\.id)
            .filter { engine(for: $0) == nil }
    }
}
