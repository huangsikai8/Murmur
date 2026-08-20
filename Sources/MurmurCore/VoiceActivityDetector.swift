import AVFoundation
import FluidAudio
import Foundation

/// Detects when speech starts and stops, so dictation can be bounded by
/// silence instead of by a key.
///
/// Wraps FluidAudio's Silero VAD. The model consumes fixed 4096-sample chunks
/// at 16 kHz — 256 ms — which is the resolution of every decision here; audio
/// is buffered up to that size rather than passed straight through.
public actor VoiceActivityDetector {

    public enum Event: Sendable, Equatable {
        case speechStarted
        case speechEnded
    }

    /// How the detector decides an utterance is over.
    public struct Tuning: Sendable {
        /// Silence needed before speech is considered finished.
        public var silenceDuration: TimeInterval
        /// Sound shorter than this is a cough or a keystroke, not dictation.
        public var minSpeechDuration: TimeInterval
        /// A monologue with no real pause is split at this length.
        public var maxUtteranceDuration: TimeInterval

        /// `silenceDuration` is rounded up to whole 256 ms chunks by the
        /// model, so 300 ms and 500 ms behave identically. Measured waits
        /// before text appears: 250 ms → 0.68 s, 500 ms → 0.98 s,
        /// 750 ms → 1.22 s.
        public init(
            silenceDuration: TimeInterval = 0.5,
            minSpeechDuration: TimeInterval = 0.4,
            maxUtteranceDuration: TimeInterval = 14.0
        ) {
            self.silenceDuration = silenceDuration
            self.minSpeechDuration = minSpeechDuration
            self.maxUtteranceDuration = maxUtteranceDuration
        }
    }

    public static let sampleRate = VadManager.sampleRate
    public static let chunkSize = VadManager.chunkSize

    private var tuning: Tuning
    private var manager: VadManager?
    private var state: VadStreamState?
    /// Samples not yet forming a whole chunk.
    private var pending: [Float] = []

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    public func setTuning(_ tuning: Tuning) {
        self.tuning = tuning
    }

    private var segmentation: VadSegmentationConfig {
        VadSegmentationConfig(
            minSpeechDuration: tuning.minSpeechDuration,
            minSilenceDuration: tuning.silenceDuration,
            maxSpeechDuration: tuning.maxUtteranceDuration
        )
    }

    // MARK: - Lifecycle

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: modelsDirectory.path)
    }

    /// Where FluidAudio caches the Silero weights.
    public static var modelsDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("silero-vad-coreml", isDirectory: true)
    }

    public func prepare() async throws {
        guard manager == nil else { return }
        let created = try await VadManager()
        manager = created
        state = await created.makeStreamState()
        pending.removeAll(keepingCapacity: true)
    }

    /// Clears the utterance state without unloading the model. Call between
    /// sessions so silence from a previous one cannot end the next.
    public func reset() async {
        guard let manager else { return }
        state = await manager.makeStreamState()
        pending.removeAll(keepingCapacity: true)
    }

    public func releaseModels() {
        manager = nil
        state = nil
        pending.removeAll(keepingCapacity: false)
    }

    // MARK: - Detection

    /// Feeds 16 kHz mono samples and returns the boundaries crossed, in order.
    ///
    /// A batch can produce more than one event — a short utterance inside a
    /// single call yields both a start and an end — so callers must handle the
    /// whole array rather than only the first.
    public func process(_ samples: [Float]) async throws -> [Event] {
        guard let manager, var current = state else { throw VadError.notInitialized }

        pending.append(contentsOf: samples)
        var events: [Event] = []

        // Consumed with an index and compacted once at the end: removing from
        // the front per chunk shifts the whole remainder each time.
        var consumed = 0
        while pending.count - consumed >= Self.chunkSize {
            let chunk = Array(pending[consumed..<(consumed + Self.chunkSize)])
            consumed += Self.chunkSize

            let result = try await manager.processStreamingChunk(
                chunk, state: current, config: segmentation)
            current = result.state
            if let event = result.event {
                events.append(event.isStart ? .speechStarted : .speechEnded)
            }
        }

        if consumed > 0 { pending.removeFirst(consumed) }
        state = current
        return events
    }
}
