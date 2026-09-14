import AVFoundation
import Foundation
import GraniteMLX
import MLX

/// `SpeechRecognitionEngine` for IBM Granite Speech 5.0 470M TurboCTC, through
/// Granite-MLX.
///
/// A CTC model emits lowercase words with no punctuation, so every transcript
/// is passed through Granite-MLX's punctuation and truecasing model before it
/// is returned. Batch like `ParakeetBatchEngine`: decoded once, on release.
public actor GraniteCTCEngine: SpeechRecognitionEngine {

    public static let engineName = "Granite-MLX"

    public static let modelID = "ibm.granite-speech-5.0-470m"

    /// The Apache 2.0 Q8 build. Spelled out rather than taken from
    /// `GraniteModelLoader.defaultModelID`, which a package update could move to
    /// a different checkpoint — or to one of the non-commercial builds published
    /// beside it — without anything here changing.
    public static let speechRepository = "iky1e/granite-speech-5.0-470m-turboctc-mlx-q8"
    public static let punctuationRepository = "iky1e/punctuation-fullstop-truecase-english-mlx-q8"

    /// Murmur's own folder, the same reasoning as `WhisperEngine.downloadBase`:
    /// Granite-MLX's platform default is `~/Documents/huggingface`. No transfer
    /// cache and no compiled Core ML cache, because nothing here uses either and
    /// a second copy of every file is what a transfer cache is.
    public static var storage: GraniteModelStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("Granite", isDirectory: true)
        return GraniteModelStorage(
            hubDirectory: base, downloadCacheDirectory: nil, compiledCoreMLDirectory: nil)
    }

    /// Installed only when both models are: the recognizer without the
    /// formatter produces lowercase text with no punctuation.
    public static var isInstalled: Bool {
        let manager = GraniteModelManager(storage: storage)
        return manager.isDownloaded(speechRepository, kind: .speech)
            && manager.isDownloaded(punctuationRepository, kind: .punctuation)
    }

    public static func delete() throws {
        let manager = GraniteModelManager(storage: storage)
        for repository in [speechRepository, punctuationRepository]
        where manager.isDownloaded(repository) {
            try manager.remove(repository)
        }
    }

    private var recognizer: GraniteRecognizer?
    private var formatter: (any GraniteTranscriptFormatter)?

    /// Samples for the current utterance, at 16 kHz mono.
    private var samples: [Float] = []
    private var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?

    /// Ordered path from the audio thread into the sample buffer. Yielding is
    /// synchronous; a `Task` per buffer would not preserve order.
    private let audioPipe = StreamPipe<AVAudioPCMBuffer>()
    private var feedTask: Task<Void, Never>?

    public init() {}

    public func install(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await prepare()
        // Installing only needs the files; see `MLXAudioEngine.install`.
        await releaseModels()
        progress?(1.0)
    }

    // MARK: - SpeechRecognitionEngine

    /// Decodes on release, so the overlay stays empty during the hold.
    public nonisolated var streamsLiveText: Bool { false }

    /// Granite Speech 5.0 reads 16 kHz mono.
    public func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    }

    /// Downloads if needed, then loads both models. Granite-MLX's calls are
    /// synchronous, and this actor is what keeps them off the main thread.
    public func prepare() async throws {
        guard recognizer == nil else { return }
        let storage = Self.storage
        recognizer = try GraniteRecognizer(modelSource: Self.speechRepository, storage: storage)
        formatter = try GraniteTranscriptFormatterFactory.load(
            modelSource: Self.punctuationRepository, storage: storage)
    }

    public func beginSession() async throws -> AsyncStream<TranscriptUpdate> {
        try await prepare()
        guard recognizer != nil else { throw SpeechEngineError.noSession }

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

        guard let recognizer else { throw SpeechEngineError.noSession }

        let collected = samples
        samples.removeAll(keepingCapacity: true)
        let seconds = Double(collected.count) / 16000

        // Shorter than this is a key tap or a cough. Granite-MLX itself refuses
        // anything under 257 samples.
        guard collected.count >= 3200 else {
            report(String(format: "%.1f s audio, shorter than 0.2 s, not decoded", seconds))
            finishUpdates(with: "")
            return ""
        }

        // Measured on `--testsilence`: Granite 5.0 answered all 4 silent holds
        // with "Thank you." or "I." See `SilenceGuard`.
        let peak = SilenceGuard.peakDecibels(collected)
        guard peak > SilenceGuard.silenceCeiling else {
            report(
                String(
                    format: "%.1f s audio, peak %.1f dBFS, below the %.0f dBFS silence ceiling, not decoded",
                    seconds, peak, SilenceGuard.silenceCeiling))
            finishUpdates(with: "")
            return ""
        }

        let start = ContinuousClock.now
        // The source URL only appears in Granite-MLX's error details; the audio
        // never came from a file.
        let audio = GraniteAudio(
            samples: collected, sampleRate: 16000, source: URL(fileURLWithPath: "/dev/null"))
        let raw = try recognizer.transcribe(audio)
        let recognizedMs = Int((ContinuousClock.now - start) / .milliseconds(1))

        var text = raw.rawText
        if let formatter, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let formatting = try formatter.format(
                raw.rawText, cancellationToken: nil, progressHandler: nil)
            text = raw.applyingFormatting(formatting).text
        }
        let totalMs = Int((ContinuousClock.now - start) / .milliseconds(1))

        text = TextNormalizer.finalize(text)
        guard SilenceGuard.carriesWords(text), !SilenceGuard.isInventedSilence(text, peak: peak)
        else {
            report(
                String(
                    format: "%.1f s audio, peak %.1f dBFS, decoded in %d ms -> \"%@\", taken as invented, nothing inserted",
                    seconds, peak, totalMs, text))
            finishUpdates(with: "")
            return ""
        }
        let words = text.split(whereSeparator: \.isWhitespace).count
        report(
            String(
                format: "%.1f s audio, recognized in %d ms, formatted by %d ms -> %d words (%.2f words/s)",
                seconds, recognizedMs, totalMs, words, seconds > 0 ? Double(words) / seconds : 0))
        finishUpdates(with: text)
        return text
    }

    /// Where a decode reports what it was handed and what it gave back. The app
    /// points this at its own log file.
    public nonisolated(unsafe) static var diagnosticLog: (@Sendable (String) -> Void)?

    private func report(_ line: String) {
        Self.diagnosticLog?("granite 5.0: \(line)")
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
        recognizer = nil
        formatter = nil
        // Released buffers go to MLX's cache, not the system; see
        // `MLXAudioEngine.releaseModels`.
        Memory.clearCache()
    }
}
