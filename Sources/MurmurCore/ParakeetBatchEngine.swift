import AVFoundation
import FluidAudio
import Foundation

/// `SpeechRecognitionEngine` backed by Parakeet TDT 0.6B v2, which decodes the
/// whole utterance at once rather than streaming.
///
/// Nothing is emitted while you speak: the samples are collected, and the
/// transcript is produced in `finishSession()` when the key is released. The
/// engine still satisfies the streaming protocol — its update stream simply
/// carries a single final result — so the capture, overlay, and insertion
/// layers need no special case.
public actor ParakeetBatchEngine: SpeechRecognitionEngine {

    public static let engineName = "Parakeet TDT (batch)"

    public static let modelID = "nvidia.parakeet-tdt-0.6b-v2"

    /// v2 is the English-only checkpoint. v3 would be the multilingual sibling,
    /// and differs enough in vocabulary that it belongs to its own entry.
    private static let version: AsrModelVersion = .v2

    private var manager: AsrManager?

    /// Samples for the current utterance, at 16 kHz mono.
    private var samples: [Float] = []
    private var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?

    /// Ordered path from the audio thread into the sample buffer. Yielding is
    /// synchronous; a `Task` per buffer would not preserve order.
    private let audioPipe = StreamPipe<AVAudioPCMBuffer>()
    private var feedTask: Task<Void, Never>?

    public init() {}

    // MARK: - Installation

    /// The exact folder FluidAudio caches this checkpoint in. Asking the
    /// package rather than rebuilding the path keeps install detection honest.
    public static var modelsDirectory: URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    public static var isInstalled: Bool {
        AsrModels.modelsExist(at: modelsDirectory, version: version)
    }

    public static func delete() throws {
        let folder = modelsDirectory
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    public func install() async throws {
        try await prepare()
    }

    // MARK: - SpeechRecognitionEngine

    /// Parakeet decodes 16 kHz mono, and collecting samples in that form avoids
    /// a conversion pass over the whole utterance at release.
    public func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    }

    public func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: Self.version)
        manager = AsrManager(models: models)
    }

    public func beginSession() async throws -> AsyncStream<TranscriptUpdate> {
        try await prepare()
        guard manager != nil else { throw SpeechEngineError.noSession }

        samples.removeAll(keepingCapacity: true)

        let (updates, continuation) = AsyncStream<TranscriptUpdate>.makeStream()
        updateContinuation = continuation

        let (audioStream, audioContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        audioPipe.attach(audioContinuation)
        feedTask = Task { [weak self] in
            for await buffer in audioStream {
                await self?.collect(buffer)
            }
        }

        // No partials are ever yielded: there is nothing to show until the
        // decoder runs, and speculative text must never reach the overlay.
        return updates
    }

    private func collect(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        samples.append(
            contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    public nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        audioPipe.yield(buffer)
    }

    public func finishSession() async throws -> String {
        // Drain every buffer before decoding, or the tail of the utterance is
        // simply missing from the input.
        audioPipe.finish()
        await feedTask?.value
        feedTask = nil

        guard let manager else { throw SpeechEngineError.noSession }

        let collected = samples
        samples.removeAll(keepingCapacity: true)

        // Shorter than this is a key tap or a cough; the encoder needs a frame
        // or two to produce anything and would only return noise.
        guard collected.count >= 3200 else {
            finishUpdates(with: "")
            return ""
        }

        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(collected, decoderState: &state)
        let text = TextNormalizer.finalize(result.text)

        finishUpdates(with: text)
        return text
    }

    /// Publishes the one and only result, so callers that watch the stream see
    /// the same text that `finishSession()` returns.
    private func finishUpdates(with text: String) {
        if !text.isEmpty {
            updateContinuation?.yield(TranscriptUpdate(text: text, isFinal: true))
        }
        updateContinuation?.finish()
        updateContinuation = nil
    }

    public func cancelSession() async {
        audioPipe.finish()
        feedTask?.cancel()
        feedTask = nil
        samples.removeAll(keepingCapacity: true)
        updateContinuation?.finish()
        updateContinuation = nil
    }

    public func releaseModels() async {
        await cancelSession()
        await manager?.cleanup()
        manager = nil
    }
}
