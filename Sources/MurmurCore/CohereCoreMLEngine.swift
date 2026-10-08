import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// `SpeechRecognitionEngine` for Cohere Transcribe 2B through FluidAudio's
/// Core ML build, which is the same checkpoint `MLXAudioEngine` runs and the
/// only route to it that can reach the Neural Engine.
///
/// The difference is the whole point of this engine existing. MLX allocates the
/// weights as GPU buffers inside the process — measured at 3138 MB of footprint
/// for this model, against 177 MB for `ParakeetBatchEngine`, whose Core ML
/// weights are memory-mapped and whose compute lives on the ANE. On a 16 GB
/// machine that difference is not an abstraction: a resident MLX model is
/// evicted under pressure and every decode afterwards re-faults it, which is
/// what turns an ordinary 200 ms hold into the 1.3-2.0 s ones in `Murmur.log`.
///
/// Batch, like every model of this shape here: nothing is emitted while you
/// speak and the transcript is produced on release.
public actor CohereCoreMLEngine: SpeechRecognitionEngine {

    public static let engineName = "Cohere Transcribe (Core ML)"

    public static let modelID = "cohere.transcribe-03-2026-coreml"

    /// FluidAudio's own repository case, which already points at the `q8`
    /// subtree rather than the repository root. The root also carries an
    /// `.mlpackage` copy of every compiled model — 2.5 GB of sources nothing
    /// loads — and `ModelNames.CohereTranscribe.requiredModels` is what keeps
    /// them off the disk: the encoder, the v2 decoder and `vocab.json`, and
    /// nothing else.
    private static let repo: Repo = .cohereTranscribeCoreml

    /// The decoder published in two builds, and only one of them can use the
    /// Neural Engine. FluidAudio's own note: v1 is FP16 with a dynamic
    /// `attention_mask`, and "dynamic shapes block ANE"; v2 fixes the shape and
    /// is "ANE-resident, ~1.6x faster decoder end-to-end". Never select v1 here
    /// — it runs, correctly, on the GPU, and silently gives up the reason this
    /// engine was written.
    private static let decoderVariant: CoherePipeline.DecoderVariant = .v2

    private var models: CoherePipeline.LoadedModels?
    private let pipeline = CoherePipeline()

    /// Samples for the current utterance, at 16 kHz mono.
    private var samples: [Float] = []
    private var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?

    /// Ordered path from the audio thread into the sample buffer. Yielding is
    /// synchronous; a `Task` per buffer would not preserve order.
    private let audioPipe = StreamPipe<AVAudioPCMBuffer>()
    private var feedTask: Task<Void, Never>?

    public init() {}

    // MARK: - Installation

    /// Murmur's own folder, for the same reason `WhisperEngine.downloadBase`
    /// and `GraniteCTCEngine.storage` have one: a download that lands in a
    /// package's default cache is a download this app cannot find, size, or
    /// delete honestly.
    public static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("Cohere", isDirectory: true)
    }

    /// Where `ModelHub.download` puts the files: the base directory plus the
    /// repository's own folder name. Asking `Repo` rather than spelling the
    /// path out keeps install detection pointed at whatever the package moves
    /// to, which is the failure `ParakeetBatchEngine.modelsDirectory` avoids
    /// the same way.
    public static var repositoryDirectory: URL {
        modelsDirectory.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    /// Installed only when every file the pipeline loads is present. A partial
    /// download that reports installed fails later, inside `prepare()`, where
    /// it reads as the model being broken rather than missing.
    public static var isInstalled: Bool {
        let folder = repositoryDirectory
        return ModelNames.CohereTranscribe.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    public static func delete() throws {
        let folder = modelsDirectory
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    public func install(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await download(progress: progress)
        // Load once to prove the download decodes, then let it go: installing
        // must not leave 2 GB resident behind a model nobody selected. Same
        // reasoning as `MLXAudioEngine.install`.
        try await prepare()
        await releaseModels()
        progress?(1.0)
    }

    private func download(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !Self.isInstalled else { return }
        try FileManager.default.createDirectory(
            at: Self.modelsDirectory, withIntermediateDirectories: true)
        try await ModelHub.download(
            Self.repo,
            to: Self.modelsDirectory,
            progressHandler: { snapshot in progress?(snapshot.fractionCompleted) })
    }

    // MARK: - SpeechRecognitionEngine

    /// Decodes on release, so the overlay stays empty during the hold.
    public nonisolated var streamsLiveText: Bool { false }

    /// The pipeline takes no phrase list of any kind, so the vocabulary reaches
    /// this model only through the cleanup pass. Said out loud rather than left
    /// to the protocol default, because that default is silent by design.
    public nonisolated var biasesTowardPhrases: Bool { false }

    /// Cohere's mel front end is built for 16 kHz mono, and collecting samples
    /// in that form avoids a conversion pass over the whole utterance at
    /// release.
    public func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    }

    /// Downloads if needed, then loads the encoder and decoder.
    ///
    /// `computeUnits` is `.all` rather than `.cpuAndNeuralEngine`: Core ML
    /// places each layer itself, and forbidding the GPU does not force anything
    /// onto the ANE — it only removes the fallback for layers the ANE will not
    /// take. Whether the Neural Engine is actually used is not a promise this
    /// call can make; it is something to measure.
    public func prepare() async throws {
        guard models == nil else { return }
        try await download()
        let folder = Self.repositoryDirectory
        let start = ContinuousClock.now
        models = try await CoherePipeline.loadModels(
            encoderDir: folder,
            decoderDir: folder,
            vocabDir: folder,
            decoderVariant: Self.decoderVariant,
            computeUnits: .all)
        let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
        Self.diagnosticLog?("cohere: models loaded in \(ms) ms, decoder \(Self.decoderVariant)")
    }

    public func beginSession() async throws -> AsyncStream<TranscriptUpdate> {
        try await prepare()
        guard models != nil else { throw SpeechEngineError.noSession }

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

        guard let models else { throw SpeechEngineError.noSession }

        let collected = samples
        samples.removeAll(keepingCapacity: true)
        let seconds = Double(collected.count) / 16000

        // Shorter than this is a key tap or a cough; the mel front end needs a
        // frame or two before it can produce anything but noise.
        guard collected.count >= 3200 else {
            report(String(format: "%.1f s audio, shorter than 0.2 s, not decoded", seconds))
            finishUpdates(with: "")
            return ""
        }

        // Measured on `--testsilence` before `SilenceGuard` existed: Cohere
        // answered 3 of 4 silent holds with "Thank you."
        let peak = SilenceGuard.peakDecibels(collected)
        guard peak > SilenceGuard.silenceCeiling else {
            report(
                String(
                    format:
                        "%.1f s audio, peak %.1f dBFS, below the %.0f dBFS silence ceiling, not decoded",
                    seconds, peak, SilenceGuard.silenceCeiling))
            finishUpdates(with: "")
            return ""
        }

        // `transcribeLong` rather than `transcribe`: the window is 35 s, and a
        // latched hold runs well past it. The short path is taken internally
        // when the audio fits, so this costs a comparison and covers the case
        // that would otherwise truncate exactly as Whisper's seek loop did.
        let start = ContinuousClock.now
        let result = try await pipeline.transcribeLong(
            audio: collected, models: models, language: .english)
        let totalMs = Int((ContinuousClock.now - start) / .milliseconds(1))

        let text = TextNormalizer.finalize(result.text)
        guard SilenceGuard.carriesWords(text), !SilenceGuard.isInventedSilence(text, peak: peak)
        else {
            report(
                String(
                    format:
                        "%.1f s audio, peak %.1f dBFS, decoded in %d ms -> \"%@\", taken as invented, nothing inserted",
                    seconds, peak, totalMs, text))
            finishUpdates(with: "")
            return ""
        }

        let words = text.split(whereSeparator: \.isWhitespace).count
        report(
            String(
                format:
                    "%.1f s audio, peak %.1f dBFS, decoded in %d ms (encoder %.0f ms, decoder %.0f ms) -> %d words (%.2f words/s)",
                seconds, peak, totalMs, result.encoderSeconds * 1000, result.decoderSeconds * 1000,
                words, seconds > 0 ? Double(words) / seconds : 0))
        finishUpdates(with: text)
        return text
    }

    /// Where a decode reports what it was handed and what it gave back. The app
    /// points this at its own log file. The encoder and decoder are reported
    /// separately because they run on different hardware and a placement that
    /// silently fell back to the GPU is visible in the split and nowhere else.
    public nonisolated(unsafe) static var diagnosticLog: (@Sendable (String) -> Void)?

    private func report(_ line: String) {
        Self.diagnosticLog?("cohere transcribe: \(line)")
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

    /// Dropping the `MLModel` references is the whole release: Core ML weights
    /// are memory-mapped, so there is no cache to clear here the way MLX needs
    /// one.
    public func releaseModels() async {
        await cancelSession()
        models = nil
    }
}
