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
        /// Hugging Face's Distil-Whisper: Large v3's encoder, unchanged, with the
        /// decoder distilled to two layers on English.
        case distilLargeV3

        public var modelID: String {
            switch self {
            case .tiny: "openai.whisper-tiny-en"
            case .base: "openai.whisper-base-en"
            case .small: "openai.whisper-small-en"
            case .medium: "openai.whisper-medium-en"
            case .largeV3Turbo: "openai.whisper-large-v3-turbo"
            case .distilLargeV3: "huggingface.distil-whisper-large-v3"
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
            case .distilLargeV3: "distil-whisper_distil-large-v3"
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
            // WhisperKit identifies a checkpoint by its dimensions, and
            // Distil-Whisper's are Large v3's, so it asks for Large v3's tokenizer.
            case .largeV3Turbo, .distilLargeV3: "openai/whisper-large-v3"
            }
        }

        /// Whether the vocabulary is sent to this variant's decoder as a prompt.
        ///
        /// Turbo only, because Turbo is what it was measured safe on. On 24 `say`
        /// clips it took Turbo from 8 to 16 vocabulary hits in 16 and word error
        /// from 1.1% to 0.2%, and six forced-stop runs of `--testlong` read the
        /// same with it as without. Small gained too — 10 to 14 hits, 1.0% to
        /// 0.6% — but its forced-stop arm broke in 3 runs of 3 with the prompt
        /// and 0 of 3 without, repeating or inventing words where a recovery
        /// joins the first pass, even with the prompt kept off the recoveries.
        /// Tiny, Base and Medium are unmeasured.
        public var promptsVocabulary: Bool { self == .largeV3Turbo }

        public static func from(modelID: String) -> Variant? {
            allCases.first { $0.modelID == modelID }
        }
    }

    private let variant: Variant
    /// Folder inside `argmaxinc/whisperkit-coreml` the weights come from.
    /// `variant.repositoryFolder` everywhere in the app — see `init`.
    private let repositoryFolder: String
    private var whisperKit: WhisperKit?

    /// Samples for the current utterance, at 16 kHz mono.
    private var samples: [Float] = []

    /// The vocabulary, as `setContextualPhrases` last gave it. Sent to the
    /// decoder as a prompt on the first pass only — see `decodeWholeHold`.
    private var contextualPhrases: [String] = []
    private var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?

    /// Ordered path from the audio thread into the sample buffer. Yielding is
    /// synchronous; a `Task` per buffer would not preserve order.
    private let audioPipe = StreamPipe<AVAudioPCMBuffer>()
    private var feedTask: Task<Void, Never>?

    /// - Parameter repositoryFolder: a sibling build of the same checkpoint — a
    ///   quantized one — to load in place of the variant's own folder, so
    ///   `--testwhispertuning` can benchmark it without the catalog offering
    ///   it. `nil` everywhere in the app.
    public init(variant: Variant, repositoryFolder: String? = nil) {
        self.variant = variant
        self.repositoryFolder = repositoryFolder ?? variant.repositoryFolder
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
        modelsDirectory(folder: variant.repositoryFolder)
    }

    private static func modelsDirectory(folder: String) -> URL {
        downloadBase
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: repository, directoryHint: .isDirectory)
            .appending(path: folder, directoryHint: .isDirectory)
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
        isInstalled(variant, folder: variant.repositoryFolder)
    }

    private static func isInstalled(_ variant: Variant, folder: String) -> Bool {
        let models = modelsDirectory(folder: folder)
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
        if whisperKit == nil, !Self.isInstalled(variant, folder: repositoryFolder) {
            _ = try await WhisperKit.download(
                variant: repositoryFolder,
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

    /// Whisper has no contextual-phrase API, but it reads a prompt as text said
    /// just before the audio, which biases it towards those spellings — "VS
    /// Code" otherwise arrives as "versus code". Only where
    /// `Variant.promptsVocabulary` says the prompt is safe, so a variant sent
    /// none still reports, truthfully, that the vocabulary does nothing.
    public nonisolated var biasesTowardPhrases: Bool { variant.promptsVocabulary }

    /// `async` on purpose, though nothing here awaits. The protocol extension
    /// has an empty `async` default with the same signature, and from async code
    /// Swift prefers an `async` overload — so a synchronous version here lost to
    /// the no-op whenever it was called on the concrete type, and the vocabulary
    /// silently never arrived.
    public func setContextualPhrases(_ phrases: [String]) async {
        contextualPhrases = phrases
    }

    /// The vocabulary as a decoder prompt: the terms as one comma-separated
    /// list, or `nil` when there are none.
    public static func prompt(for phrases: [String]) -> String? {
        let terms = phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: ", ") + "."
    }

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
            model: repositoryFolder,
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
        let seconds = Double(collected.count) / 16000
        Self.lastHoldCost = nil

        // Shorter than this is a key tap or a cough.
        guard collected.count >= 3200 else {
            report(seconds: seconds, peak: nil, outcome: "shorter than 0.2 s, not decoded")
            finishUpdates(with: "")
            return ""
        }

        // Nothing this quiet is speech, and handing it to Whisper is how a
        // sentence nobody spoke gets inserted — see `silenceCeiling`.
        let peak = Self.peakDecibels(collected)
        guard peak > Self.silenceCeiling else {
            report(
                seconds: seconds, peak: peak,
                outcome: "below the \(Self.silenceCeiling) dBFS silence ceiling, not decoded")
            finishUpdates(with: "")
            return ""
        }

        let decodeStart = ContinuousClock.now
        let prompt =
            Self.tuning.vocabularyPrompt.applies(to: variant)
            ? Self.prompt(for: contextualPhrases) : nil
        let (pieces, recoveries, cost) = try await Self.decodeWholeHold(
            collected, with: whisperKit, prompt: prompt)
        let decodeMs = Int((ContinuousClock.now - decodeStart) / .milliseconds(1))
        Self.lastHoldCost = cost

        // Piece by piece rather than result by result, so a piece decoded out of
        // silence can be dropped on the evidence of its own audio. Joined with a
        // space rather than concatenated, since each is its own sentence fragment
        // and Whisper leaves no separator between them.
        var spoken: [String] = []
        var previous: Piece?
        var invented = 0
        for piece in pieces {
            guard Self.spansAudibleAudio(collected, from: piece.start, to: piece.end) else {
                invented += 1
                continue
            }
            // A seam is where two separate decodes meet, and only there can the
            // same words arrive twice.
            let seam = previous.map { $0.isRecovered != piece.isRecovered } ?? false
            var text =
                seam
                ? Self.trimmingOverlap(piece.text, following: spoken.last ?? "") : piece.text
            // Every join, not only a recovery seam: the model capitalizes the
            // first word of each segment it emits, and it cuts a segment at
            // every pause for thought.
            if let preceding = spoken.last {
                text = Self.loweringSegmentInitial(text, following: preceding)
            }
            previous = piece
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            spoken.append(text)
        }
        let joined = spoken.joined(separator: " ")
        let text = TextNormalizer.finalize(Self.stripNonSpeechAnnotations(joined))

        guard Self.carriesWords(text), !Self.isInventedSilence(text, peak: peak) else {
            report(
                seconds: seconds, peak: peak, decodeMs: decodeMs, cost: cost,
                outcome: "no words in the result, nothing inserted"
                    + (invented > 0 ? " (\(invented) segment(s) decoded out of silence)" : "")
                    + (cost.retries > 0
                        ? " (the decoder rejected its own output \(cost.retries) time(s))" : ""))
            finishUpdates(with: "")
            return ""
        }

        var outcome: [String] = []
        if recoveries > 0 {
            outcome.append(
                "decoder stopped short of the audio, \(recoveries) pass(es) recovered it")
        }
        if invented > 0 { outcome.append("\(invented) segment(s) decoded out of silence, dropped") }
        if cost.retries > 0 {
            outcome.append("the decoder rejected its own output \(cost.retries) time(s)")
        }
        report(
            seconds: seconds, peak: peak, decodeMs: decodeMs, cost: cost, text: text,
            outcome: outcome.isEmpty ? nil : outcome.joined(separator: "; "))
        finishUpdates(with: text)
        return text
    }

    // MARK: - Decoding the whole hold

    /// One stretch of decoded text, in seconds from the start of the hold.
    private struct Piece {
        let start: Double
        let end: Double
        let text: String
        /// Whether this came from a re-decode of audio the first pass skipped.
        /// The joins on either side of one are the only places two decodes meet,
        /// and so the only places the same words can be transcribed twice.
        var isRecovered = false
    }

    /// Decodes `samples` and returns what came back, in seconds from the start
    /// of `samples`.
    private static func decode(
        _ samples: [Float], with whisperKit: WhisperKit, prompt: String? = nil
    ) async throws -> (pieces: [Piece], cost: DecodeCost) {
        let options = decodeOptions(for: whisperKit, prompt: prompt)
        let results = try await whisperKit.transcribe(
            audioArray: samples, decodeOptions: options)
        let seconds = Double(samples.count) / sampleRate
        let cost = DecodeCost(results, options: options)

        var pieces: [Piece] = []
        for result in results {
            // A result with no segments carries no timestamps to judge it by, so
            // it is credited with the whole slice it was decoded from.
            guard !result.segments.isEmpty else {
                if !result.text.isEmpty {
                    pieces.append(Piece(start: 0, end: seconds, text: result.text))
                }
                continue
            }
            for segment in result.segments where !segment.text.isEmpty {
                pieces.append(
                    Piece(
                        start: Double(segment.start), end: Double(segment.end),
                        text: segment.text))
            }
        }
        return (pieces, cost)
    }

    /// Decodes the hold, re-decoding whatever audible audio the transcript does
    /// not account for.
    ///
    /// **Whisper stops when it decides the utterance is over, not when the audio
    /// runs out, and WhisperKit has no second chance to offer it.** Its seek
    /// loop advances to the last timestamp the decoder emitted; where the
    /// decoder emitted no usable timestamp it does `seek += segmentSize` — a
    /// whole window. For a hold shorter than 30 s that window *is* the whole
    /// recording, so one early stop ends the transcription there and everything
    /// after it is thrown away, with no error and no gap in the text that reads.
    /// Measured on a real 20.4-second latched hold: 39 words, cut mid-clause, at
    /// 1.91 words/s against the 2-3 ordinary dictation runs at. The same failure
    /// at a window boundary returned 26 words for 34.2 s of speech.
    ///
    /// So the audio, not the decoder, says how far the transcript should reach.
    /// Any stretch of the hold that no audible piece accounts for is decoded
    /// again on its own and the result slotted into place. The slices are
    /// disjoint by construction, so nothing can be transcribed twice, and the
    /// gap may be in the middle as easily as at the end — a capped decode
    /// crossing a window boundary skips one and carries on past it, which the
    /// tail alone would never recover.
    ///
    /// Every pass has to pay for itself: a gap is only decoded if it is long
    /// enough to hold a word and loud enough to be speech, and `floor` moves
    /// past whatever was just attempted, so a decoder that stops for its own
    /// reasons cannot be asked the same question twice.
    ///
    /// **The vocabulary prompt goes to the first pass only.** A recovery decodes
    /// a short slice, and a prompt steers a short slice far harder than a whole
    /// window: measured on Small's forced-stop arm of `--testlong`, prompting the
    /// recoveries too broke them in 3 runs of 3 — twice a six-word duplicate at
    /// the seam, once "Thanks for watching." — where unprompted recoveries gave
    /// neither. Kept off the recoveries, it still broke Small's, which is why
    /// `Variant.promptsVocabulary` decides whether there is a prompt at all.
    private static func decodeWholeHold(
        _ samples: [Float], with whisperKit: WhisperKit, prompt: String?
    ) async throws -> (pieces: [Piece], recoveries: Int, cost: DecodeCost) {
        var (pieces, cost) = try await decode(samples, with: whisperKit, prompt: prompt)
        var floor: Double = 0
        var recoveries = 0
        let budget = maxRecoveryPasses(forSeconds: Double(samples.count) / sampleRate)

        while recoveries < budget {
            guard let gap = firstAudibleGap(in: pieces, of: samples, notBefore: floor) else {
                break
            }
            recoveries += 1
            let slice = span(samples, from: gap.start, to: gap.end)
            let pass = try await decodeGap(
                samples, from: gap.start, to: gap.end, with: whisperKit)
            cost.add(pass.cost)
            let recovered = pass.pieces
            let text = TextNormalizer.finalize(
                stripNonSpeechAnnotations(recovered.map(\.text).joined(separator: " ")))

            // Nothing usable came back, from the gap whole or from any of its
            // pieces. Only now is it abandoned.
            guard carriesWords(text), !isInventedSilence(text, peak: peakDecibels(slice)) else {
                diagnosticLog?(
                    String(format: "  %.1f-%.1f s was skipped by the decoder and holds no words",
                           gap.start, gap.end))
                floor = gap.end
                continue
            }

            diagnosticLog?(
                String(
                    format: "  %.1f-%.1f s was skipped by the decoder, recovered %d word(s)",
                    gap.start, gap.end, text.split(whereSeparator: \.isWhitespace).count))
            pieces += recovered
            floor = max(
                gap.start + recoveryMinimumProgress,
                min(coveredThrough(recovered, of: samples), gap.end))
        }

        // Recovered pieces are appended as they are found, and a gap in the
        // middle is found after the text that follows it. The transcript is read
        // in the order it was spoken.
        pieces.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        return (pieces, recoveries, cost)
    }

    /// Decodes one gap, and if that produces nothing, decodes it in pieces.
    ///
    /// **A gap re-decoded whole is the same question the decoder already
    /// refused.** The recovery was built for a decoder that stops part-way
    /// through a window: there the gap is a fraction of the window, so the slice
    /// handed back is short, different, and genuinely easier. A gap that *is* a
    /// whole window is none of those things — the slice is the same 30 seconds
    /// padded the same way, and the answer is the same nothing.
    ///
    /// Measured on a real 55.2 s hold. Whisper Small returned nothing at all for
    /// 0.2-30.0 s, the recovery handed those same 29.8 seconds straight back,
    /// got nothing again, and abandoned the span for good:
    ///
    ///     0.2-30.0 s was skipped by the decoder and holds no words
    ///     -> 183 chars, 36 words (0.65 words/s)
    ///
    /// Ordinary dictation runs at 2-3 words/s. Half the transcript was thrown
    /// away by a retry that could not have succeeded. Cut into pieces the
    /// decoder has not already refused, each one is a different problem, and the
    /// cost is paid only on a gap that failed whole — which on a healthy decode
    /// never happens.
    private static func decodeGap(
        _ samples: [Float], from start: Double, to end: Double, with whisperKit: WhisperKit
    ) async throws -> (pieces: [Piece], cost: DecodeCost) {
        let whole = span(samples, from: start, to: end)
        let first = try await decode(whole, with: whisperKit)
        var cost = first.cost
        if carriesUsableWords(first.pieces, decodedFrom: whole) {
            return (recovered(first.pieces, offsetBy: start), cost)
        }

        // Short gaps are left alone. Below this the slice was never the problem,
        // and cutting it further only feeds the decoder more silence, which is
        // what it answers with words nobody said.
        guard end - start > subdivisionThreshold else { return ([], cost) }

        var collected: [Piece] = []
        var emittedThrough = start
        for chunk in subdivisionPlan(from: start, to: end) {
            let audio = span(samples, from: chunk.from, to: chunk.to)
            let pass = try await decode(audio, with: whisperKit)
            cost.add(pass.cost)
            guard carriesUsableWords(pass.pieces, decodedFrom: audio) else {
                emittedThrough = chunk.to
                continue
            }
            // Kept by where a piece's middle falls, which drops the duplicate
            // the overlap produces without having to edit anybody's text.
            for piece in recovered(pass.pieces, offsetBy: chunk.from)
            where (piece.start + piece.end) / 2 >= emittedThrough {
                collected.append(piece)
            }
            emittedThrough = chunk.to
        }
        return (collected, cost)
    }

    /// How a failed gap is cut up, as spans in seconds from the start of the
    /// hold.
    ///
    /// Pure, and public, because this is where the arithmetic can be quietly
    /// wrong: a plan that leaves a hole re-creates the very defect the
    /// subdivision exists to fix, and a transcript reads perfectly well across
    /// one. Each span opens `subdivisionOverlap` before the previous closed, so
    /// a word spoken across a cut survives whole in one of them.
    public static func subdivisionPlan(
        from start: Double, to end: Double
    ) -> [(from: Double, to: Double)] {
        var plan: [(from: Double, to: Double)] = []
        var cursor = start
        while cursor < end {
            let from = max(start, cursor - subdivisionOverlap)
            let to = min(end, cursor + subdivisionSeconds)
            // A remainder too short to hold a word is not worth a decode, and
            // handing the model a sliver of silence is how invented words get
            // in.
            guard to - from >= recoveryMinimumSeconds else { break }
            plan.append((from, to))
            cursor = to
        }
        return plan
    }

    /// Whether a decode of `slice` produced anything a person could have said.
    /// The same two questions the caller asks of a whole hold, so a piece is
    /// held to the standard the transcript is.
    private static func carriesUsableWords(_ pieces: [Piece], decodedFrom slice: [Float]) -> Bool {
        let text = TextNormalizer.finalize(
            stripNonSpeechAnnotations(pieces.map(\.text).joined(separator: " ")))
        return carriesWords(text) && !isInventedSilence(text, peak: peakDecibels(slice))
    }

    /// Moves pieces from slice-relative seconds into hold-relative ones.
    private static func recovered(_ pieces: [Piece], offsetBy offset: Double) -> [Piece] {
        pieces.map {
            Piece(start: $0.start + offset, end: $0.end + offset, text: $0.text, isRecovered: true)
        }
    }

    /// The earliest stretch of the hold that no audible piece accounts for,
    /// which is itself loud enough to have been speech.
    ///
    /// `notBefore` is what makes the loop above finite: it moves past every gap
    /// already attempted, so each pass looks strictly further into the hold.
    private static func firstAudibleGap(
        in pieces: [Piece], of samples: [Float], notBefore floor: Double
    ) -> (start: Double, end: Double)? {
        let seconds = Double(samples.count) / sampleRate

        // Only audible pieces count as coverage: Whisper stretches a trailing
        // `[BLANK_AUDIO]` over the silence after the last word — often past the
        // end of the recording — and that must not vouch for speech.
        let covered = pieces
            .filter { spansAudibleAudio(samples, from: $0.start, to: $0.end) }
            .map { (start: max(0, min($0.start, seconds)), end: max(0, min($0.end, seconds))) }
            .sorted { $0.start < $1.start }

        var gaps: [(start: Double, end: Double)] = []
        var cursor: Double = 0
        for piece in covered {
            if piece.start > cursor { gaps.append((cursor, piece.start)) }
            cursor = max(cursor, piece.end)
        }
        if seconds > cursor { gaps.append((cursor, seconds)) }

        for gap in gaps {
            let start = max(gap.start, floor)
            guard gap.end - start >= recoveryMinimumSeconds else { continue }
            // Judged on how much of the gap is speech, not on how loud its
            // loudest instant was — see `audibleExtent`. Decoded with a little
            // margin either side, so a word is not clipped at the seam, and with
            // as little silence as possible, since silence is what Whisper
            // answers with words nobody said.
            guard let audible = audibleExtent(samples, from: start, to: gap.end),
                audible.end - audible.start >= recoveryMinimumSeconds
            else { continue }
            return (
                max(start, audible.start - recoveryMargin),
                min(gap.end, audible.end + recoveryMargin)
            )
        }
        return nil
    }

    /// The stretch of a span that is loud enough to be speech, from the first
    /// such moment to the last.
    ///
    /// A gap judged by its peak alone is judged by its loudest 25 ms, and the
    /// gap between two sentences opens on the tail of the word before it: loud,
    /// and a tenth of a second long. Measured on `--testlong` with Large v3
    /// Turbo, that was enough to send five ordinary pauses to the decoder, which
    /// answered them with "- Right.", "you", and "Thank you." three times over —
    /// exactly the invented speech `silenceCeiling` exists to keep out, let back
    /// in by the recovery. What decides a gap is how much of it is speech.
    private static func audibleExtent(
        _ samples: [Float], from start: Double, to end: Double
    ) -> (start: Double, end: Double)? {
        let first = max(0, min(samples.count, Int(start * sampleRate)))
        let last = max(first, min(samples.count, Int((end * sampleRate).rounded(.up))))
        guard first < last else { return nil }

        let sliceLength = max(1, Int(sampleRate * 0.025))
        var audibleFirst: Int?
        var audibleLast: Int?
        var index = first
        while index < last {
            let count = min(sliceLength, last - index)
            if peakDecibels(samples, in: index..<(index + count)) > silenceCeiling {
                if audibleFirst == nil { audibleFirst = index }
                audibleLast = index + count
            }
            index += count
        }
        guard let audibleFirst, let audibleLast else { return nil }
        return (Double(audibleFirst) / sampleRate, Double(audibleLast) / sampleRate)
    }

    /// How far into the hold a set of pieces reaches, counting only the ones
    /// whose own audio is audible and clamping to the recording — those
    /// timestamps are the model's guess, and nothing downstream can use one that
    /// points past the audio.
    private static func coveredThrough(_ pieces: [Piece], of samples: [Float]) -> Double {
        let seconds = Double(samples.count) / sampleRate
        return pieces.reduce(0.0) { furthest, piece in
            guard spansAudibleAudio(samples, from: piece.start, to: piece.end) else {
                return furthest
            }
            return max(furthest, min(piece.end, seconds))
        }
    }

    /// The samples a span of the hold points at.
    private static func span(_ samples: [Float], from start: Double, to end: Double) -> [Float] {
        let first = max(0, min(samples.count, Int(start * sampleRate)))
        let last = max(first, min(samples.count, Int((end * sampleRate).rounded(.up))))
        return Array(samples[first..<last])
    }

    /// Removes a leading run of words that only repeats the end of what comes
    /// before it.
    ///
    /// A gap is re-decoded from the last timestamp the decoder emitted, and that
    /// timestamp says where the model stopped, not where the phrase did — so the
    /// second decode can begin part-way through something already transcribed.
    /// Measured on the forced-stop arm of `--testlong`: "… The barometer in the"
    /// followed by "The barometer in the hallway has been reading …".
    ///
    /// Deliberately timid. It runs only at a seam the recovery itself created,
    /// matches whole words, and needs **at least two** of them: one repeated
    /// word is something people say, and losing a word somebody spoke is worse
    /// than keeping one they did not.
    public static func trimmingOverlap(_ text: String, following previous: String) -> String {
        let head = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let tail = previous.split(whereSeparator: \.isWhitespace).map(String.init)
        guard head.count >= 2, tail.count >= 2 else { return text }

        let comparable = { (word: String) in
            word.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let headKeys = head.map(comparable)
        let tailKeys = tail.map(comparable)

        let longest = min(maximumOverlapWords, min(headKeys.count, tailKeys.count))
        guard longest >= 2 else { return text }
        for length in stride(from: longest, through: 2, by: -1) {
            guard Array(tailKeys.suffix(length)) == Array(headKeys.prefix(length)) else { continue }
            return head.dropFirst(length).joined(separator: " ")
        }
        return text
    }

    /// Lowercases a segment-initial word that only got its capital from being
    /// segment-initial.
    ///
    /// Whisper is trained on captioned audio, where every caption line opens
    /// with a capital, so it capitalizes the first word of **every segment it
    /// emits** — and it cuts a segment at each pause for thought.
    /// `finishSession` joins those segments verbatim, and `capitalizeSentences`
    /// only ever *adds* capitals, so a pause mid-sentence arrives as a capital
    /// mid-sentence:
    ///
    ///     … it's just basically like whatever There's more than one standard
    ///     deviation from the usual Of that day Isn't it?
    ///
    /// Reported on large-v3-turbo, the multilingual checkpoint, which segments
    /// far more eagerly than the `.en` models.
    ///
    /// **Only function words.** The capital is genuine at the start of a real
    /// sentence and on a proper noun, and neither can be told from a stray one
    /// by position alone — a segment opening "Sarah said that" looks exactly
    /// like one opening "Of that day". So this moves only words that can never
    /// be a name: one word the list does not know keeps its capital, the same
    /// bargain `isNonSpeechAnnotation` makes. Wrongly lowercasing somebody's
    /// name is worse than leaving a stray capital, which is only untidy.
    /// Whisper capitalizes the first word of every segment, and cuts a segment
    /// at every pause, so a pause for thought arrives as a capital mid-sentence.
    ///
    /// The rule is `CaretContinuation`'s, which is the same question asked of
    /// the text before an insertion point rather than the text before a
    /// segment. One implementation and one word list: two would drift, and the
    /// failure they share — lowercasing somebody's name — is silent.
    public static func loweringSegmentInitial(
        _ text: String, following previous: String
    ) -> String {
        CaretContinuation.lowercasingOpeningWord(text, following: previous)
    }



    /// Ceiling on what an overlap may be. Long enough for the phrase a decoder
    /// stops in the middle of, short enough that it cannot swallow a sentence.
    private static let maximumOverlapWords = 12

    private static let sampleRate: Double = 16000

    /// Shortest uncovered tail worth another decode. Below this there is no room
    /// for a word, and the pass would cost more than it could recover.
    private static let recoveryMinimumSeconds: Double = 1.0

    /// How far a pass must move the coverage to count as progress. A decoder
    /// that has stopped for its own reasons will stop again in the same place,
    /// and repeating that is how a hold turns into an unbounded loop.
    private static let recoveryMinimumProgress: Double = 0.25

    /// Kept either side of the speech in a gap, so a re-decode does not open on
    /// a half-spoken word.
    private static let recoveryMargin: Double = 0.2

    /// Above this, a gap that came back empty is decoded again in pieces rather
    /// than abandoned. Below it, the length was never what the decoder objected
    /// to, and cutting further only hands it more silence.
    private static let subdivisionThreshold: Double = 15

    /// How much of a failed gap one piece covers. Well under the 30-second
    /// window, so a piece is a question the decoder has not already refused.
    private static let subdivisionSeconds: Double = 12

    /// Each piece opens this far before the previous one closed, so a word
    /// spoken across a cut survives whole in one of them.
    private static let subdivisionOverlap: Double = 0.3

    /// Ceiling on the passes, so a pathological decode costs a bounded number of
    /// them. One or two is what a real early stop needs; the cap is only ever
    /// reached by a model that has stopped being useful.
    ///
    /// Scaled by length rather than fixed, because every 30-second window is its
    /// own chance to come back blank: a constant sized for a one-minute hold
    /// runs out part-way through a five-minute one and abandons the rest of the
    /// recording silently. A short hold keeps the 8 it always had.
    private static func maxRecoveryPasses(forSeconds seconds: Double) -> Int {
        max(8, Int(seconds / 30) + 4)
    }

    /// `maxRecoveryPasses` for the test that holds the scaling to account. The
    /// failure it guards is a long hold quietly running out of budget, which is
    /// invisible in a transcript that still reads perfectly well.
    public static func recoveryPassBudget(forSeconds seconds: Double) -> Int {
        maxRecoveryPasses(forSeconds: seconds)
    }

    // MARK: - What the decode was handed, and what it gave back

    /// Where a decode reports what it was given and what it produced.
    ///
    /// A batch engine is opaque from the outside: `LatencyTracker` times the
    /// press and the paste, so a hold that returns almost nothing looks exactly
    /// like a hold in which almost nothing was said. Nothing recorded how much
    /// audio actually reached the decoder, which is the one number that
    /// separates "the microphone lost it" from "the model gave up" — the
    /// question a real 41.7-second hold that came back as six words could not
    /// be made to answer. The app points this at its own log file.
    public nonisolated(unsafe) static var diagnosticLog: (@Sendable (String) -> Void)?

    /// Words per second is the figure that makes a bad decode obvious: ordinary
    /// dictation runs at 2-3, and the failure being watched for here reads as
    /// 0.1-0.6 against a hold long enough to be a paragraph.
    private func report(
        seconds: Double, peak: Float?, decodeMs: Int? = nil, cost: DecodeCost? = nil,
        text: String? = nil, outcome: String? = nil
    ) {
        guard let log = Self.diagnosticLog else { return }
        // A benchmarked sibling build is named by its folder, or its line would
        // read exactly like the variant it is being compared against.
        let name =
            repositoryFolder == variant.repositoryFolder ? variant.rawValue : repositoryFolder
        var line = String(format: "whisper %@: %.1f s audio", name, seconds)
        if let peak { line += String(format: ", peak %.1f dBFS", peak) }
        if let decodeMs { line += ", decoded in \(decodeMs) ms" }
        if let cost { line += " (\(cost.summary))" }
        if let text {
            let words = text.split(whereSeparator: \.isWhitespace).count
            line += String(
                format: " -> %d chars, %d words (%.2f words/s)", text.count, words,
                seconds > 0 ? Double(words) / seconds : 0)
        }
        if let outcome { line += " -> " + outcome }
        log(line)
    }

    /// Whether the decoder is asked for timestamps.
    ///
    /// Public only so a test can hold the line. Nothing in the app reads a
    /// timestamp, so turning them off looks free and costs a clause at every
    /// 30-second boundary — with no error, no warning, and a transcript that
    /// reads perfectly well right across the gap.
    public static var decodesWithTimestamps: Bool { !baseDecodeOptions.withoutTimestamps }

    /// Where one hold's decode time went, summed over every WhisperKit call the
    /// hold needed — the first pass and each recovery.
    ///
    /// "Decoded in N ms" cannot say whether a slow hold was the model's size or
    /// the decoder distrusting itself, and those have different fixes. Whisper
    /// encodes a fixed 30-second window whatever the recording's length, so the
    /// encoder is a floor paid per window; a retry is a whole extra decode, paid
    /// only when an attempt is rejected.
    public struct DecodeCost: Sendable, Equatable {
        /// 30-second windows encoded, across every call.
        public var windows = 0
        public var melSeconds: Double = 0
        public var encoderSeconds: Double = 0
        /// The rest of the decode loop: token prediction, sampling, the KV cache
        /// and windowing. Includes `retrySeconds`.
        public var decoderSeconds: Double = 0
        /// The part of `decoderSeconds` spent on attempts that were thrown away.
        public var retrySeconds: Double = 0
        /// Attempts thrown away and decoded again at a higher temperature.
        public var retries = 0
        /// Tokens of vocabulary prompt the decoder was handed, which is the only
        /// evidence the prompt arrived: a missing one transcribes perfectly well.
        public var promptTokens = 0

        public init() {}

        /// **WhisperKit's own fallback counter cannot be summed.**
        /// `totalDecodingFallbacks` is *assigned* the index of the attempt that
        /// failed, not incremented, so a window whose first attempt was rejected
        /// and whose second was kept reports 0 — and each window overwrites the
        /// one before. Every retry raises the temperature by a fixed step, so the
        /// temperature the kept segment was decoded at is the exact count. The
        /// counter is kept only as a floor, for a window that kept no segment to
        /// read a temperature from.
        init(_ results: [TranscriptionResult], options: DecodingOptions) {
            let step = Double(options.temperatureIncrementOnFallback)
            promptTokens = options.promptTokens?.count ?? 0
            for result in results {
                let timings = result.timings
                windows += Int(timings.totalEncodingRuns)
                melSeconds += timings.logmels
                encoderSeconds += timings.encoding
                decoderSeconds += max(0, timings.decodingLoop - timings.logmels - timings.encoding)
                retrySeconds += timings.decodingFallback

                var temperatureByWindow: [Int: Float] = [:]
                for segment in result.segments {
                    temperatureByWindow[segment.seek] = max(
                        temperatureByWindow[segment.seek] ?? 0, segment.temperature)
                }
                let counted =
                    step > 0
                    ? temperatureByWindow.values.reduce(0) {
                        $0 + Int(((Double($1) - Double(options.temperature)) / step).rounded())
                    } : 0
                retries += max(counted, Int(timings.totalDecodingFallbacks))
            }
        }

        public mutating func add(_ other: DecodeCost) {
            windows += other.windows
            melSeconds += other.melSeconds
            encoderSeconds += other.encoderSeconds
            decoderSeconds += other.decoderSeconds
            retrySeconds += other.retrySeconds
            retries += other.retries
            promptTokens += other.promptTokens
        }

        /// The breakdown as `Murmur.log` prints it.
        public var summary: String {
            let ms = { (seconds: Double) in Int((seconds * 1000).rounded()) }
            var text =
                "\(windows) window(s): mel \(ms(melSeconds)) ms, encoder \(ms(encoderSeconds)) ms, "
                + "decoder \(ms(decoderSeconds)) ms"
            if retries > 0 || retrySeconds > 0 {
                text += " of which \(retries) retry(s) \(ms(retrySeconds)) ms"
            }
            if promptTokens > 0 { text += ", prompted with \(promptTokens) tokens" }
            return text
        }
    }

    /// The most recent hold's cost, for a test to read without parsing the log
    /// line. `nil` for a hold that was never decoded.
    public nonisolated(unsafe) static var lastHoldCost: DecodeCost?

    /// How far the decoder may distrust itself, and what it is told to expect.
    ///
    /// **Test-only: `.shipped` in the app.** It exists so `--testwhispertuning`
    /// can measure each change against the same recordings before any of them
    /// becomes the default.
    public struct DecodeTuning: Sendable, Equatable {
        /// WhisperKit's `firstTokenLogProbThreshold` of -1.5, which OpenAI's
        /// reference decoder does not have. An attempt whose first token falls
        /// below it ends with no tokens at all and is retried.
        public var firstTokenCutoff: Bool
        /// `temperatureFallbackCount`. When every attempt is rejected WhisperKit
        /// keeps the *last* one, which is the most random of them.
        public var retries: Int
        /// Whether the vocabulary from `setContextualPhrases` is sent to the
        /// first pass as a prompt.
        public var vocabularyPrompt: VocabularyPrompt

        public enum VocabularyPrompt: Sendable, Equatable {
            /// Never, to measure what the prompt buys.
            case off
            /// Where `Variant.promptsVocabulary` says it is safe.
            case perVariant
            /// On every variant, to measure one that has not been cleared.
            case always

            func applies(to variant: Variant) -> Bool {
                switch self {
                case .off: false
                case .perVariant: variant.promptsVocabulary
                case .always: true
                }
            }
        }

        public init(firstTokenCutoff: Bool, retries: Int, vocabularyPrompt: VocabularyPrompt) {
            self.firstTokenCutoff = firstTokenCutoff
            self.retries = retries
            self.vocabularyPrompt = vocabularyPrompt
        }

        /// What the app runs: WhisperKit's fallback defaults, and the prompt
        /// where it has been measured safe.
        public static let shipped = DecodeTuning(
            firstTokenCutoff: true, retries: 5, vocabularyPrompt: .perVariant)

        /// The fallback changes still under test. Neither can be judged on
        /// `say`, which never makes the decoder retry.
        public static let candidate = DecodeTuning(
            firstTokenCutoff: false, retries: 2, vocabularyPrompt: .perVariant)
    }

    public nonisolated(unsafe) static var tuning = DecodeTuning.shipped

    // MARK: - Non-speech annotations

    /// Removes Whisper's non-speech annotations: `[BLANK_AUDIO]`, `[ Silence ]`,
    /// `(applause)`, `[MUSIC PLAYING]`.
    ///
    /// These are ordinary text tokens, not special tokens, so `skipSpecialTokens`
    /// does not touch them and they are inserted into the speaker's document
    /// like anything else. They appear once timestamps are on — which they must
    /// be, see `baseDecodeOptions` — most often as a trailing marker on a hold that
    /// ended in silence.
    ///
    /// Matched on the *whole* bracketed span against a fixed list, never on the
    /// brackets alone: `SpokenFormatter` has no rule that produces a bracket, so
    /// one in a transcript is either the model's annotation or something the
    /// speaker dictated deliberately, and guessing from the punctuation would
    /// eat the second along with the first.
    public static func stripNonSpeechAnnotations(_ text: String) -> String {
        var output = ""
        var pending = ""
        var closer: Character?

        for character in text {
            if let expected = closer {
                pending.append(character)
                guard character == expected else { continue }
                if !isNonSpeechAnnotation(pending) { output += pending }
                pending = ""
                closer = nil
                continue
            }
            switch character {
            case "[": closer = "]"
            case "(": closer = ")"
            default:
                output.append(character)
                continue
            }
            pending = String(character)
        }
        // An unclosed bracket is ordinary text; nothing has said it is an
        // annotation, so it is kept exactly as it arrived.
        return output + pending
    }

    /// Whether a bracketed span is one of Whisper's annotations.
    ///
    /// Two tests, and the second exists because the first does not scale. An
    /// exact list of phrases catches `[BLANK_AUDIO]` and `[ Silence ]`, which
    /// the model spells the same way every time, and misses everything it
    /// composes on the spot — `(Audience chattering)`, `(people chattering)`,
    /// `(crowd murmuring)`, `(indistinct chatter)`. Those reached a real
    /// transcript three times in one sentence. There is no finite list of them,
    /// so the second test asks about the *words* instead: a short bracketed span
    /// in which every word is non-speech vocabulary is an annotation, however
    /// the model chose to phrase it.
    public static func isNonSpeechAnnotation(_ span: String) -> Bool {
        if nonSpeechAnnotations.contains(span.lowercased().filter { $0.isLetter }) { return true }
        return isNonSpeechPhrase(span)
    }

    /// Whether every word of a bracketed span belongs to the vocabulary of
    /// things that are not speech.
    ///
    /// Deliberately unanimous. One non-speech word is not enough — "(the music
    /// of Tuesday)" is something a person could dictate — so a single word the
    /// vocabulary does not know keeps the whole span. Connectives are allowed
    /// through but cannot carry a span on their own, or "(and)" would be read as
    /// an annotation. The length cap is the same idea from the other end: a
    /// caption is a label, and a bracketed clause long enough to be a sentence
    /// is the speaker talking.
    private static func isNonSpeechPhrase(_ span: String) -> Bool {
        let words = span.lowercased().split { !$0.isLetter }.map(String.init)
        guard (1...maximumAnnotationWords).contains(words.count) else { return false }
        guard words.contains(where: nonSpeechWords.contains) else { return false }
        return words.allSatisfy { nonSpeechWords.contains($0) || annotationConnectives.contains($0) }
    }

    /// Longest bracketed span that can still be a caption rather than speech.
    private static let maximumAnnotationWords = 4

    /// Words a caption is built from: what made the sound, what the sound was,
    /// and how it was described. Kept to things that cannot carry meaning in
    /// dictated prose, since a word listed here is a word this app will silently
    /// delete whenever it appears inside brackets.
    private static let nonSpeechWords: Set<String> = [
        // Who or what is making it.
        "audience", "crowd", "people", "person", "man", "woman", "speaker",
        "background", "phone", "door", "engine", "dog", "bird", "baby",
        // What it is.
        "audio", "sound", "sounds", "effect", "effects", "noise", "noises",
        "static", "silence", "silent", "blank", "pause", "music", "musical",
        "instrumental", "applause", "clapping", "cheering", "laughter",
        "laughs", "laughing", "chuckles", "chuckling", "giggles", "giggling",
        "chatter", "chattering", "chatters", "murmur", "murmurs", "murmuring",
        "mumbling", "whispering", "talking", "coughs", "coughing", "cough",
        "sighs", "sighing", "sigh", "breathing", "breathes", "breath",
        "sniffs", "sniffing", "throat", "clears", "clearing", "typing",
        "clicking", "footsteps", "rustling", "shuffling", "beep", "beeping",
        "buzzing", "ringing", "rings", "wind", "rain", "traffic", "bell",
        "alarm", "knocking", "banging", "tapping", "humming",
        // How it is described.
        "indistinct", "inaudible", "unintelligible", "faint", "faintly",
        "distant", "soft", "softly", "loud", "loudly", "quiet", "quietly",
        "continues", "continuing", "playing", "plays", "stops", "intro",
        "outro", "upbeat",
    ]

    /// Allowed inside a caption but never enough to make one.
    private static let annotationConnectives: Set<String> = [
        "a", "an", "the", "and", "of", "in", "on", "over", "with", "no",
    ]

    private static let nonSpeechAnnotations: Set<String> = [
        "blankaudio", "blank", "silence", "silent", "nosound", "noaudio",
        "music", "musicplaying", "playingmusic", "musicplays", "instrumental",
        "intromusic", "outromusic", "softmusic", "upbeatmusic",
        "applause", "laughter", "laughs", "laughing", "chuckles",
        "inaudible", "unintelligible", "noise", "backgroundnoise", "static",
        "beep", "coughs", "coughing", "sighs", "breathing", "clearsthroat",
        "sniffs", "typing", "footsteps", "wind", "soundeffects", "pause",
    ]

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
        SilenceGuard.peakDecibels(samples, sampleRate: sampleRate)
    }

    /// Below this, the hold is not decoded at all.
    ///
    /// -45 dBFS is quieter than a quiet room and far below any voice: real
    /// speech peaks between -25 and -15 dBFS even from across a desk, because
    /// this is the loudest 25 ms of the whole hold, not its average. Chosen to
    /// sit well under speech rather than close to it — a wrong "that was
    /// silence" throws away a sentence, which is the worse failure of the two.
    private static let silenceCeiling = SilenceGuard.silenceCeiling

    /// Whether the audio a segment was decoded from contains anything loud
    /// enough to have been spoken.
    ///
    /// This is the guard that only becomes possible with timestamps on, and it
    /// is a better one than matching phrases: a stretch of trailing silence is
    /// where Whisper's captioned-audio training puts "Thank you." and "you",
    /// and it puts them there whatever the words happen to be. Judged on the
    /// segment's own span rather than the whole hold, so a real sentence
    /// elsewhere in the recording cannot vouch for a segment decoded from
    /// nothing — which is exactly what `isInventedSilence` cannot do, and why
    /// it may only ever drop a transcript entire.
    ///
    /// Peak, for the reason `peakDecibels` gives: a segment is mostly gaps, and
    /// the question is whether any of it was ever loud enough to be a voice.
    /// A span that cannot be measured is kept — an out-of-range timestamp is a
    /// reason to distrust the timestamp, not to throw away words.
    public static func spansAudibleAudio(
        _ samples: [Float], from start: Double, to end: Double, sampleRate: Double = 16000
    ) -> Bool {
        let first = max(0, Int(start * sampleRate))
        let last = min(samples.count, Int((end * sampleRate).rounded(.up)))
        guard first < last, last <= samples.count else { return true }
        // Measured in place rather than over a copy: this is asked once per
        // piece, and once more per piece for every gap the recovery considers,
        // and a slice of `[Float]` copies the samples every time.
        return peakDecibels(samples, in: first..<last, sampleRate: sampleRate) > silenceCeiling
    }

    /// `peakDecibels` over part of an array, without copying it.
    private static func peakDecibels(
        _ samples: [Float], in range: Range<Int>, sampleRate: Double = 16000
    ) -> Float {
        SilenceGuard.peakDecibels(samples, in: range, sampleRate: sampleRate)
    }

    /// Whether the text contains anything a person could have said. Whisper's
    /// most common answer to near-silence is a bare "." or "...", which carries
    /// no words at all and is safe to drop whatever the audio held.
    public static func carriesWords(_ text: String) -> Bool {
        SilenceGuard.carriesWords(text)
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
        SilenceGuard.isInventedSilence(text, peak: peak)
    }

    /// English, timestamps on, no special tokens.
    ///
    /// `language` is ignored by the `.en` checkpoints, which have no language
    /// tokens at all, and pins large-v3-turbo — the one multilingual variant
    /// offered — to English rather than letting it detect a language from a
    /// two-second utterance and answer in it.
    ///
    /// **`withoutTimestamps` must stay false**, however little the timestamps
    /// are wanted here — nothing reads them. They are what lets WhisperKit
    /// find the next seek point in a hold longer than one 30-second window.
    /// Without them `SegmentSeeker` has nothing to seek by and falls into
    /// `seek += segmentSize`, jumping a whole window, so everything the
    /// decoder stopped short of inside that window is silently dropped.
    /// Measured on Large v3 Turbo over 57 s, 92 s and 171 s of speech, a
    /// clause went missing at every boundary and came back the moment
    /// timestamps were on:
    ///
    ///     … nothing unusual in it at all. in the middle of the audio. I am …
    ///                                    ^ one clause gone, no error anywhere
    ///
    /// The price is `[BLANK_AUDIO]` and friends, which the model emits only in
    /// this mode — see `stripNonSpeechAnnotations`. Losing words the speaker
    /// said is the worse failure of the two, and the annotations are
    /// recognizable enough to remove exactly.
    private static var baseDecodeOptions: DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: "en",
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false
        )
    }

    /// `baseDecodeOptions` with the current `tuning`, a prompt, and any test cap
    /// applied. Built per decode rather than once, because all three can change
    /// between holds and the prompt has to be tokenized by the model that will
    /// read it.
    private static func decodeOptions(
        for whisperKit: WhisperKit, prompt: String?
    ) -> DecodingOptions {
        var options = baseDecodeOptions
        let tuning = tuning
        if !tuning.firstTokenCutoff { options.firstTokenLogProbThreshold = nil }
        options.temperatureFallbackCount = tuning.retries
        if let prompt, let tokenizer = whisperKit.tokenizer {
            // Leading space: BPE gives a word a different token with and without
            // the space before it, and the terms arrive mid-sentence.
            options.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        if let forcedSampleLength { options.sampleLength = forcedSampleLength }
        return options
    }

    /// Caps how many tokens one decode may sample. **Test-only, and `nil` in the
    /// app.**
    ///
    /// A decoder that stops before the audio runs out is what `decodeWholeHold`
    /// exists to answer, and real speech only does it by accident — no fixture
    /// here has ever reproduced it on `say`-synthesized audio, which is exactly
    /// why the defect reached a real dictation. Capping the sample length
    /// produces the same condition on demand, so the recovery can be tested by
    /// something that fails without it.
    public nonisolated(unsafe) static var forcedSampleLength: Int?

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
