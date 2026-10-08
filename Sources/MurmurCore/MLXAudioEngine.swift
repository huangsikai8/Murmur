import AVFoundation
import Foundation
import HuggingFace
import MLX
import MLXAudioSTT

/// `SpeechRecognitionEngine` for the speech models MLX Audio runs on the GPU:
/// Cohere Transcribe, IBM Granite Speech 4.1 and Qwen3-ASR.
///
/// Both are batch models, so this follows `ParakeetBatchEngine`: samples are
/// collected during the hold and decoded once in `finishSession()`, and the
/// update stream carries a single final result.
public actor MLXAudioEngine: SpeechRecognitionEngine {

    public static let engineName = "MLX Audio"

    public enum Variant: String, Sendable, CaseIterable {
        case cohereTranscribe
        case graniteSpeech41
        /// The most accurate downloadable model on the Open ASR leaderboard of
        /// 11 September 2026: 4.31% across its public English test sets.
        case qwen3ASR17B

        public var modelID: String {
            switch self {
            case .cohereTranscribe: "cohere.transcribe-03-2026"
            case .graniteSpeech41: "ibm.granite-speech-4.1-2b"
            case .qwen3ASR17B: "qwen.qwen3-asr-1.7b"
            }
        }

        /// The converted MLX checkpoint. 8-bit throughout, because a 2B model at
        /// full precision needs several gigabytes resident on a 16 GB machine
        /// whose memory is already mostly in use, and loading the full Cohere
        /// build measured 6.7 GB of footprint on Soniqo's own benchmark.
        ///
        /// Spelled out rather than chosen at runtime. A loader that fell back to
        /// another build would still transcribe, and a model nobody chose would
        /// run under this one's name.
        public var repositoryID: String {
            switch self {
            case .cohereTranscribe: "beshkenadze/cohere-transcribe-03-2026-mlx-8bit"
            case .graniteSpeech41: "divydeep/granite-speech-4.1-2b-mlx-8bit"
            // Listed by MLX Audio as a supported conversion, unlike the other two.
            case .qwen3ASR17B: "mlx-community/Qwen3-ASR-1.7B-8bit"
            }
        }

        /// Named rather than read from the checkpoint's config, which would cost
        /// a network request before every load.
        var modelType: String {
            switch self {
            case .cohereTranscribe: "cohere_asr"
            case .graniteSpeech41: "granite_speech"
            case .qwen3ASR17B: "qwen3_asr"
            }
        }

        /// The language hint passed to generation. Cohere reads it as the
        /// language spoken. **Granite reads the same parameter as a translation
        /// target**, so it is given none: an English hint asks it to translate.
        /// Qwen3-ASR identifies the language itself when given none, and a
        /// two-second hold is little to identify it from; MLX Audio's own
        /// example names it in full.
        public var languageHint: String? {
            switch self {
            case .cohereTranscribe: "en"
            case .graniteSpeech41: nil
            case .qwen3ASR17B: "English"
            }
        }

        public static func from(modelID: String) -> Variant? {
            allCases.first { $0.modelID == modelID }
        }
    }

    private let variant: Variant
    private var model: (any STTGenerationModel)?

    /// The vocabulary, as `setContextualPhrases` last gave it. Only Qwen3-ASR
    /// has anywhere to put it.
    private var contextualPhrases: [String] = []

    /// Text on screen where the transcript will land, as `setSurroundingText`
    /// last gave it. This is the half of context that cleanup cannot do: it
    /// reaches the recognizer, so it can change which words come back rather
    /// than only how they are spelled afterwards.
    private var surroundingText: String = ""

    /// Samples for the current utterance, at 16 kHz mono.
    private var samples: [Float] = []
    private var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?

    /// Ordered path from the audio thread into the sample buffer. Yielding is
    /// synchronous; a `Task` per buffer would not preserve order.
    private let audioPipe = StreamPipe<AVAudioPCMBuffer>()
    private var feedTask: Task<Void, Never>?

    public init(variant: Variant) {
        self.variant = variant
    }

    // MARK: - Installation

    /// Where MLX Audio materializes a checkpoint:
    /// `<hub cache>/mlx-audio/<owner>_<name>`.
    ///
    /// The default hub cache for every variant, not only the one that needs it:
    /// Cohere's loader ignores any cache it is handed, so a custom location
    /// would put the download somewhere install detection never looks.
    public static func modelsDirectory(_ variant: Variant) -> URL {
        HubCache.default.cacheDirectory
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(
                variant.repositoryID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    /// Installed means the weights and the config are both there. A folder
    /// alone is what an interrupted download leaves behind.
    public static func isInstalled(_ variant: Variant) -> Bool {
        let folder = modelsDirectory(variant)
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.appendingPathComponent("config.json").path),
            let files = try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else { return false }
        return files.contains { file in
            file.pathExtension == "safetensors"
                && ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        }
    }

    /// The hub's own folder for the repository, which a download fills too.
    static func transferDirectory(_ variant: Variant) -> URL {
        HubCache.default.cacheDirectory.appendingPathComponent(
            "models--" + variant.repositoryID.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true)
    }

    /// Removes the materialized checkpoint, and the hub's own folder for the
    /// repository if the download left one.
    public static func delete(_ variant: Variant) throws {
        for folder in [modelsDirectory(variant), transferDirectory(variant)]
        where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Downloads and loads the weights. MLX Audio reports no download progress,
    /// so the bar jumps to the end when the load finishes.
    public func install(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await prepare()
        // Installing only needs the files. The copy the load leaves behind is
        // released, or a download from Settings keeps a second 2-3 GB model
        // resident next to whichever one is selected.
        await releaseModels()
        // **Every checkpoint is downloaded twice.** The hub keeps the weights in
        // its own blob folder, and MLX Audio copies them — a real copy, not a
        // link — into `modelsDirectory`, which is the only one it loads from or
        // checks. Measured: 2307 MB in each for Cohere, 3149 MB in each for
        // Granite 4.1. The hub's copy goes once the load has succeeded.
        let transfer = Self.transferDirectory(variant)
        if Self.isInstalled(variant), FileManager.default.fileExists(atPath: transfer.path) {
            try? FileManager.default.removeItem(at: transfer)
        }
        progress?(1.0)
    }

    // MARK: - SpeechRecognitionEngine

    /// Decodes on release, so the overlay stays empty during the hold.
    public nonisolated var streamsLiveText: Bool { false }

    /// Qwen3-ASR takes a free-text context, placed in its system prompt, and
    /// the vocabulary goes there. Cohere and Granite have no such input.
    public nonisolated var biasesTowardPhrases: Bool {
        variant == .qwen3ASR17B && Self.sendsVocabularyContext
    }

    /// Whether Qwen3-ASR is handed the vocabulary as context. **Test-only: true
    /// in the app**, switched off by `--no-context` to measure what it buys.
    public nonisolated(unsafe) static var sendsVocabularyContext = true

    /// `async` for the reason `WhisperEngine.setContextualPhrases` gives: the
    /// protocol extension's no-op is `async`, and a synchronous version here
    /// loses to it when called on the concrete type.
    public func setContextualPhrases(_ phrases: [String]) async {
        contextualPhrases = phrases
    }

    /// The terms as one comma-separated list, or empty when there are none.
    static func qwenContext(for phrases: [String]) -> String {
        phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The vocabulary and the screen, as one piece of free text.
    ///
    /// Both go in, because the model has one context field and the two answer
    /// different questions: the vocabulary is what this speaker says often, the
    /// screen is what this conversation is about. Labelled rather than
    /// concatenated, so neither reads as a continuation of the other.
    public static func qwenContext(phrases: [String], surrounding: String) -> String {
        var parts: [String] = []
        let vocabulary = qwenContext(for: phrases)
        if !vocabulary.isEmpty { parts.append("Terms used often: \(vocabulary)") }
        let trimmed = surrounding.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append("On screen: \(trimmed)") }
        return parts.joined(separator: ". ")
    }

    /// Text already on screen where this transcript will land. Empty clears it.
    public func setSurroundingText(_ text: String) async {
        surroundingText = text
    }

    /// All three models read 16 kHz mono.
    public func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    }

    public func prepare() async throws {
        guard model == nil else { return }
        model = try await STT.loadModel(
            modelRepo: variant.repositoryID, modelType: variant.modelType)
    }

    public func beginSession() async throws -> AsyncStream<TranscriptUpdate> {
        try await prepare()
        guard model != nil else { throw SpeechEngineError.noSession }

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

        guard let model else { throw SpeechEngineError.noSession }

        let collected = samples
        samples.removeAll(keepingCapacity: true)
        let seconds = Double(collected.count) / 16000

        // Shorter than this is a key tap or a cough.
        guard collected.count >= 3200 else {
            report(String(format: "%.1f s audio, shorter than 0.2 s, not decoded", seconds))
            finishUpdates(with: "")
            return ""
        }

        // Measured on `--testsilence`: Cohere answered 3 silent holds of 4 with
        // "Thank you." See `SilenceGuard`.
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
        let output =
            if variant == .graniteSpeech41, let granite = model as? GraniteSpeechModel {
                granite.generate(audio: MLXArray(collected), prompt: Self.granitePunctuationPrompt)
            } else if variant == .qwen3ASR17B, let qwen = model as? Qwen3ASRModel {
                qwen.generate(
                    audio: MLXArray(collected),
                    context: Self.sendsVocabularyContext
                        ? Self.qwenContext(
                            phrases: contextualPhrases, surrounding: surroundingText) : "",
                    language: variant.languageHint)
            } else {
                model.generate(
                    audio: MLXArray(collected),
                    generationParameters: STTGenerateParameters(language: variant.languageHint))
            }
        let decodeMs = Int((ContinuousClock.now - start) / .milliseconds(1))

        let text = TextNormalizer.finalize(output.text)
        guard SilenceGuard.carriesWords(text), !SilenceGuard.isInventedSilence(text, peak: peak)
        else {
            report(
                String(
                    format: "%.1f s audio, peak %.1f dBFS, decoded in %d ms -> \"%@\", taken as invented, nothing inserted",
                    seconds, peak, decodeMs, text))
            finishUpdates(with: "")
            return ""
        }
        let words = text.split(whereSeparator: \.isWhitespace).count
        report(
            String(
                format: "%.1f s audio, decoded in %d ms -> %d words (%.2f words/s)",
                seconds, decodeMs, words, seconds > 0 ? Double(words) / seconds : 0))
        finishUpdates(with: text)
        return text
    }

    /// IBM's preferred prompt for a punctuated, capitalized transcript of Granite
    /// Speech 4.1. MLX Audio's default is the one IBM lists for raw transcripts,
    /// and its keyword-biasing prompt is raw too, which is why the vocabulary is
    /// not sent this way.
    static let granitePunctuationPrompt =
        "transcribe the speech with proper punctuation and capitalization."

    /// Where a decode reports what it was handed and what it gave back — the
    /// same reason `WhisperEngine.diagnosticLog` exists. The app points this at
    /// its own log file.
    public nonisolated(unsafe) static var diagnosticLog: (@Sendable (String) -> Void)?

    private func report(_ line: String) {
        Self.diagnosticLog?("\(variant.rawValue): \(line)")
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
        model = nil
        // Dropping the model hands its buffers to MLX's cache, not back to the
        // system, so without this a model switched away from stays resident.
        // Measured: an app running Cohere's 2.3 GB weights held 4.7 GB of GPU
        // memory, which a relaunch took back to 2.3 GB.
        Memory.clearCache()
    }
}
