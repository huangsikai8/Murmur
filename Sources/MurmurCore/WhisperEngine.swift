import AVFoundation
import Accelerate
import Foundation
import WhisperKit

/// `SpeechRecognitionEngine` backed by OpenAI's Whisper, running on Core ML
/// through WhisperKit.
///
/// Whisper is a batch model by construction: it reads a 30-second window of
/// log-mel features and decodes it in one pass, so there is nothing to show
/// while you speak. Samples are collected during the hold and decoded in
/// `finishSession()`, exactly as `ParakeetBatchEngine` does — the streaming
/// protocol is satisfied by a stream that carries a single final result, so
/// capture, overlay and insertion need no special case.
///
/// Every variant here is English. The four small ones are OpenAI's `.en`
/// checkpoints, which are trained on English alone and are more accurate than
/// the multilingual builds of the same size; large has no `.en` release, so the
/// decoder is pinned to English instead.
public actor WhisperEngine: SpeechRecognitionEngine {

    public static let engineName = "Whisper (Core ML)"

    public enum Variant: String, Sendable, CaseIterable {
        case tiny
        case base
        case small
        case medium
        case largeV3Turbo

        public var modelID: String {
            switch self {
            case .tiny: "openai.whisper-tiny-en"
            case .base: "openai.whisper-base-en"
            case .small: "openai.whisper-small-en"
            case .medium: "openai.whisper-medium-en"
            case .largeV3Turbo: "openai.whisper-large-v3-turbo"
            }
        }

        /// Folder inside `argmaxinc/whisperkit-coreml`. Named in full rather
        /// than assembled from the case, because the names are not a pattern:
        /// large-v3-turbo is published as a date, and a guessed folder would
        /// resolve to a different checkpoint rather than fail.
        var repositoryFolder: String {
            switch self {
            case .tiny: "openai_whisper-tiny.en"
            case .base: "openai_whisper-base.en"
            case .small: "openai_whisper-small.en"
            case .medium: "openai_whisper-medium.en"
            // OpenAI's large-v3-turbo, published under its release date.
            case .largeV3Turbo: "openai_whisper-large-v3-v20240930"
            }
        }

        /// The tokenizer repository WhisperKit pulls alongside the weights.
        /// Small, but the model cannot decode a single token without it, so it
        /// counts towards being installed.
        var tokenizerRepository: String {
            switch self {
            case .tiny: "openai/whisper-tiny.en"
            case .base: "openai/whisper-base.en"
            case .small: "openai/whisper-small.en"
            case .medium: "openai/whisper-medium.en"
            case .largeV3Turbo: "openai/whisper-large-v3"
            }
        }

        public static func from(modelID: String) -> Variant? {
            allCases.first { $0.modelID == modelID }
        }
    }

    private let variant: Variant
    private var whisperKit: WhisperKit?

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

    /// Where WhisperKit is told to put everything it downloads.
    ///
    /// Given explicitly rather than left to the default, which is
    /// `~/Documents/huggingface` — a folder the speaker did not ask for, in the
    /// one place they will notice it. It also makes install detection and
    /// deletion exact, which matching loosely on a name has already got wrong
    /// here once.
    public static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Murmur", directoryHint: .isDirectory)
            .appending(path: "Whisper", directoryHint: .isDirectory)
    }

    private static let repository = "argmaxinc/whisperkit-coreml"

    /// The folder holding one variant's compiled Core ML models. This is the
    /// layout `HubApi` writes: `<base>/models/<repo>/<folder>`.
    public static func modelsDirectory(_ variant: Variant) -> URL {
        downloadBase
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: repository, directoryHint: .isDirectory)
            .appending(path: variant.repositoryFolder, directoryHint: .isDirectory)
    }

    private static func tokenizerDirectory(_ variant: Variant) -> URL {
        downloadBase
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: variant.tokenizerRepository, directoryHint: .isDirectory)
    }

    /// The three compiled models a Whisper variant needs. Checked by name
    /// rather than by the folder merely existing: a download interrupted
    /// halfway leaves the folder behind, and "installed" would then mean a
    /// model that throws on first use.
    private static let requiredModels = [
        "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
    ]

    public static func isInstalled(_ variant: Variant) -> Bool {
        let models = modelsDirectory(variant)
        let complete = requiredModels.allSatisfy { name in
            FileManager.default.fileExists(atPath: models.appending(path: name).path)
        }
        let tokenizer = tokenizerDirectory(variant).appending(path: "tokenizer.json")
        return complete && FileManager.default.fileExists(atPath: tokenizer.path)
    }

    public static func delete(_ variant: Variant) throws {
        for folder in [modelsDirectory(variant), tokenizerDirectory(variant)] {
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Downloads the weights, then loads them so the tokenizer is fetched too.
    ///
    /// The two are separate downloads from separate repositories, and only the
    /// first reports progress — so the bar stops just short of the end while
    /// the tokenizer arrives. That is a few hundred kilobytes, not the 1.6 GB
    /// the bar just crossed.
    public func install(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if whisperKit == nil, !Self.isInstalled(variant) {
            _ = try await WhisperKit.download(
                variant: variant.repositoryFolder,
                downloadBase: Self.downloadBase,
                from: Self.repository,
                progressCallback: { reported in
                    progress?(min(0.99, reported.fractionCompleted))
                }
            )
        }
        try await prepare()
        progress?(1.0)
    }

    // MARK: - SpeechRecognitionEngine

    /// Decodes on release, so the overlay stays empty during the hold.
    public nonisolated var streamsLiveText: Bool { false }

    /// Whisper's feature extractor expects 16 kHz mono, and collecting samples
    /// in that form avoids a conversion pass over the whole utterance at
    /// release.
    public func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    }

    public func prepare() async throws {
        guard whisperKit == nil else { return }
        let configuration = WhisperKitConfig(
            model: variant.repositoryFolder,
            downloadBase: Self.downloadBase,
            modelRepo: Self.repository,
            tokenizerFolder: Self.downloadBase,
            // WhisperKit narrates the whole decode at `.info`, into the same
            // log the app writes its own timings to.
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(configuration)
    }

    public func beginSession() async throws -> AsyncStream<TranscriptUpdate> {
        try await prepare()
        guard whisperKit != nil else { throw SpeechEngineError.noSession }

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

        guard let whisperKit else { throw SpeechEngineError.noSession }

        let collected = samples
        samples.removeAll(keepingCapacity: true)

        // Shorter than this is a key tap or a cough.
        guard collected.count >= 3200 else {
            finishUpdates(with: "")
            return ""
        }

        // Nothing this quiet is speech, and handing it to Whisper is how a
        // sentence nobody spoke gets inserted — see `silenceCeiling`.
        let peak = Self.peakDecibels(collected)
        guard peak > Self.silenceCeiling else {
            finishUpdates(with: "")
            return ""
        }

        let results = try await whisperKit.transcribe(
            audioArray: collected, decodeOptions: Self.decodeOptions)

        // One result per 30-second window. Joined with a space rather than
        // concatenated, since each window's text is its own sentence fragment
        // and Whisper does not leave a separator between them.
        let joined = results.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        let text = TextNormalizer.finalize(joined)

        guard Self.carriesWords(text), !Self.isInventedSilence(text, peak: peak) else {
            finishUpdates(with: "")
            return ""
        }

        finishUpdates(with: text)
        return text
    }

    // MARK: - Not saying anything

    /// Whisper answers silence with words, and WhisperKit cannot stop it.
    ///
    /// The model was trained on captioned audio, where silence is followed by
    /// whatever the caption track said next — so it fills an empty window with
    /// "Thank you.", "you", "Thanks for watching", or a bare full stop.
    /// Measured with `--testsilence` on Large v3 Turbo: digital silence returns
    /// "you", and room tone at -55, -45 and -50 dBFS all return ".", while
    /// Apple's recognizer returns nothing for all four.
    ///
    /// Whisper's own guard for this is `noSpeechThreshold`, and in WhisperKit
    /// it can never fire: `TextDecoder.swift` reads
    /// `let noSpeechProb: Float = 0 // TODO: implement no speech prob`, and the
    /// gate is `noSpeechProb > threshold`, so it compares 0 against 0.6 forever.
    /// Setting the option does nothing. This is Murmur's replacement for it.

    /// Loudest 25 ms of an utterance, in dBFS.
    ///
    /// Peak rather than average, because a sentence is mostly gaps: averaging
    /// pulls a real utterance down towards the room it was spoken in, and the
    /// question here is whether anything in the hold was ever loud enough to be
    /// a voice.
    public static func peakDecibels(_ samples: [Float], sampleRate: Double = 16000) -> Float {
        guard !samples.isEmpty else { return -.infinity }
        let sliceLength = max(1, Int(sampleRate * 0.025))
        var peak: Float = 0
        var start = 0
        while start < samples.count {
            let count = min(sliceLength, samples.count - start)
            var meanSquare: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                vDSP_measqv(buffer.baseAddress! + start, 1, &meanSquare, vDSP_Length(count))
            }
            peak = max(peak, meanSquare.squareRoot())
            start += count
        }
        return 20 * log10(max(peak, 1e-7))
    }

    /// Below this, the hold is not decoded at all.
    ///
    /// -45 dBFS is quieter than a quiet room and far below any voice: real
    /// speech peaks between -25 and -15 dBFS even from across a desk, because
    /// this is the loudest 25 ms of the whole hold, not its average. Chosen to
    /// sit well under speech rather than close to it — a wrong "that was
    /// silence" throws away a sentence, which is the worse failure of the two.
    private static let silenceCeiling: Float = -45

    /// Whether the text contains anything a person could have said. Whisper's
    /// most common answer to near-silence is a bare "." or "...", which carries
    /// no words at all and is safe to drop whatever the audio held.
    public static func carriesWords(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Whether a transcript is one of Whisper's stock silence fillers arriving
    /// on audio too quiet to have contained it.
    ///
    /// Both halves are required. The phrases are real things people say, so
    /// they are only distrusted below `inventionFloor` — quieter than any
    /// utterance that could actually have carried them, and well below the
    /// -25 dBFS a real voice peaks at. Someone who says "thank you" out loud
    /// keeps it.
    public static func isInventedSilence(_ text: String, peak: Float) -> Bool {
        guard peak < inventionFloor else { return false }
        let stripped = text.lowercased().filter { $0.isLetter || $0.isWhitespace }
            .trimmingCharacters(in: .whitespaces)
        return inventedOnSilence.contains(stripped)
    }

    private static let inventionFloor: Float = -38

    /// Whisper's captioned-audio residue. Whole-transcript matches only: these
    /// words inside a longer sentence are somebody actually speaking.
    private static let inventedOnSilence: Set<String> = [
        "you", "thank you", "thanks", "thank you very much", "thanks for watching",
        "thank you for watching", "bye", "bye bye", "blank audio", "silence",
        "music", "applause", "subs by www zeoranger co uk",
    ]

    /// English, no timestamps, no special tokens.
    ///
    /// `language` is ignored by the `.en` checkpoints, which have no language
    /// tokens at all, and pins large-v3-turbo — the one multilingual variant
    /// offered — to English rather than letting it detect a language from a
    /// two-second utterance and answer in it.
    private static let decodeOptions = DecodingOptions(
        task: .transcribe,
        language: "en",
        detectLanguage: false,
        skipSpecialTokens: true,
        withoutTimestamps: true
    )

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
        await whisperKit?.unloadModels()
        whisperKit = nil
    }
}
