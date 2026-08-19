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
}

extension SpeechRecognitionEngine {
    /// Engines without contextual biasing simply ignore the word list.
    public func setContextualPhrases(_ phrases: [String]) async {}
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
        return nil
    }

    /// Whether `modelID`'s engine produces text while you speak, rather than
    /// only when the key is released. Derived from the engine that would
    /// actually run, so a catalog entry cannot claim live text it never emits.
    public static func streamsLiveText(for modelID: String) -> Bool? {
        guard let engine = engine(for: modelID) else { return nil }
        return !(engine is ParakeetBatchEngine)
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
