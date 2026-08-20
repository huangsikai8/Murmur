import AVFoundation
import Foundation
import Speech

/// `SpeechRecognitionEngine` backed by macOS 26's on-device `SpeechAnalyzer`.
///
/// Fully local, no network, no API key. The OS owns the model, and
/// `modelRetention: .processLifetime` keeps it resident between dictations so
/// only the first session pays load cost.
public actor AppleSpeechEngine: SpeechRecognitionEngine {

    public static let engineName = "Apple SpeechAnalyzer"

    private let locale: Locale

    /// Terms biased toward during recognition, so unusual words are actually
    /// heard. Updated whenever the word list changes.
    private var contextualPhrases: [String] = []

    /// Session state, rebuilt per dictation. The analyzer object is cheap to
    /// recreate; the underlying model stays warm across sessions.
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    /// Ordered, thread-safe path from the audio thread into the analyzer.
    private let inputPipe = StreamPipe<AnalyzerInput>()
    private var resultsTask: Task<Void, Never>?
    private var buffer = TranscriptBuffer()

    /// Format the analyzer wants, resolved once and cached.
    private var cachedFormat: AVAudioFormat?
    private var didPrepare = false

    public init(locale: Locale = Locale.current, contextualPhrases: [String] = []) {
        self.locale = locale
        self.contextualPhrases = contextualPhrases
    }

    /// Replaces the recognition bias list. Takes effect on the next dictation.
    public nonisolated var biasesTowardPhrases: Bool { true }

    public func setContextualPhrases(_ phrases: [String]) {
        contextualPhrases = phrases
    }

    // MARK: - Availability and model installation

    /// Whether the transcriber exists at all on this machine.
    public nonisolated static var isSupported: Bool {
        SpeechTranscriber.isAvailable
    }

    /// Downloads the locale's model if the OS does not already have it.
    /// Progress is reported as a fraction in `0...1`.
    public func installModelIfNeeded(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let module = try resolvedTranscriber()

        let status = await AssetInventory.status(forModules: [module])
        guard status != .installed else { return }
        guard status != .unsupported else {
            throw SpeechEngineError.unavailable("locale \(locale.identifier) is not supported")
        }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        else { return }  // Nothing to fetch; already satisfied.

        let reporter = request.progress
        let observation = Task {
            while !Task.isCancelled && !reporter.isFinished {
                progress?(reporter.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { observation.cancel() }

        try await request.downloadAndInstall()
        progress?(1.0)
    }

    /// Builds a transcriber configured for live dictation.
    ///
    /// `.progressiveTranscription` turns on volatile plus fast results, which
    /// is what produces partial words while the key is still held.
    private func resolvedTranscriber() throws -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    // MARK: - SpeechRecognitionEngine

    public func preferredInputFormat() async -> AVAudioFormat? {
        if let cachedFormat { return cachedFormat }
        guard let module = try? resolvedTranscriber() else { return nil }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        cachedFormat = format
        return format
    }

    public func prepare() async throws {
        guard Self.isSupported else {
            throw SpeechEngineError.unavailable("SpeechTranscriber is not available on this Mac")
        }
        try await installModelIfNeeded()
        _ = await preferredInputFormat()

        // Warm the model now so the first dictation is not the one that pays.
        if !didPrepare {
            let module = try resolvedTranscriber()
            let warm = SpeechAnalyzer(
                modules: [module],
                options: .init(priority: .high, modelRetention: .processLifetime)
            )
            try? await warm.prepareToAnalyze(in: cachedFormat)
            await warm.cancelAndFinishNow()
            didPrepare = true
        }
    }

    public func beginSession() async throws -> AsyncStream<TranscriptUpdate> {
        await teardown()
        buffer.reset()

        let module = try resolvedTranscriber()
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Bias recognition toward the user's own terms.
        let context = AnalysisContext()
        if !contextualPhrases.isEmpty {
            context.contextualStrings = [.general: contextualPhrases]
        }

        let analyzer = SpeechAnalyzer(
            inputSequence: inputStream,
            modules: [module],
            options: .init(priority: .high, modelRetention: .processLifetime),
            analysisContext: context
        )

        self.transcriber = module
        self.analyzer = analyzer
        inputPipe.attach(inputContinuation)

        let (updates, updateContinuation) = AsyncStream<TranscriptUpdate>.makeStream()

        resultsTask = Task { [weak self] in
            do {
                for try await result in module.results {
                    let text = String(result.text.characters)
                    updateContinuation.yield(TranscriptUpdate(text: text, isFinal: result.isFinal))
                    await self?.record(text: text, isFinal: result.isFinal)
                }
            } catch {
                // A cancelled session surfaces here; the transcript so far stands.
            }
            updateContinuation.finish()
        }

        try await analyzer.prepareToAnalyze(in: cachedFormat)
        return updates
    }

    public nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        // Yielded synchronously so buffers stay in order and none is dropped by
        // a session ending before a queued task got to run.
        inputPipe.yield(AnalyzerInput(buffer: buffer))
    }

    private func record(text: String, isFinal: Bool) {
        buffer.apply(text: text, isFinal: isFinal)
    }

    public func finishSession() async throws -> String {
        guard let analyzer else { throw SpeechEngineError.noSession }

        inputPipe.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value  // Drain trailing finalized results.

        let text = buffer.finalText
        self.analyzer = nil
        self.transcriber = nil
        self.resultsTask = nil
        return text
    }

    public func cancelSession() async {
        await teardown()
        buffer.reset()
    }

    public func releaseModels() async {
        await teardown()
        await SpeechModels.endRetention()
        didPrepare = false
    }

    private func teardown() async {
        inputPipe.finish()
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
        transcriber = nil
        resultsTask?.cancel()
        resultsTask = nil
    }
}
