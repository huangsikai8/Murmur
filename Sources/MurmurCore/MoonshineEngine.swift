import AVFoundation
import Foundation
import MoonshineVoice

/// `SpeechRecognitionEngine` backed by Moonshine's streaming models.
///
/// Moonshine ships a portable C++ core with ONNX Runtime embedded, so no
/// separate inference runtime is linked. Weights are fetched on first use and
/// cached; afterwards it runs offline.
public actor MoonshineEngine: SpeechRecognitionEngine {

    public static let engineName = "Moonshine Streaming"

    public enum Variant: String, Sendable, CaseIterable {
        case small
        case medium

        public var modelID: String {
            switch self {
            case .small: "moonshine.streaming-small"
            case .medium: "moonshine.streaming-medium"
            }
        }

        var architecture: ModelArch {
            switch self {
            case .small: .smallStreaming
            case .medium: .mediumStreaming
            }
        }

        public static func from(modelID: String) -> Variant? {
            allCases.first { $0.modelID == modelID }
        }
    }

    /// English only. The other languages carry a non-commercial licence, so
    /// Murmur does not offer them.
    private static let language = "en"

    private let variant: Variant
    private var transcriber: Transcriber?
    private var stream: MoonshineVoice.Stream?

    private var pumpTask: Task<Void, Never>?
    private var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var lastPartial = ""

    /// Ordered path from the audio thread into the stream.
    private let audioPipe = StreamPipe<AVAudioPCMBuffer>()
    private var feedTask: Task<Void, Never>?

    private var keyterms: [String] = []

    public init(variant: Variant) {
        self.variant = variant
    }

    // MARK: - Installation

    private static func spec(for variant: Variant) -> ModelSpec {
        .stt(language: language, modelArch: variant.architecture)
    }

    public static func isInstalled(_ variant: Variant) -> Bool {
        let specification = spec(for: variant)
        guard let directory = try? ModelCache.directory(for: specification) else { return false }
        return AssetDownloader().isModelPresent(root: directory, spec: specification)
    }

    public static func delete(_ variant: Variant) throws {
        let specification = spec(for: variant)
        let directory = try ModelCache.directory(for: specification)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Downloads and loads the model. Needs a network connection the first time.
    public func install(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard transcriber == nil else { return }
        transcriber = try await Transcriber.load(
            language: Self.language,
            modelArch: variant.architecture,
            onProgress: { reported in
                // Progress is reported per file; weight by bytes within the
                // current file so the bar advances smoothly across all of them.
                let completedFiles = Double(reported.fileIndex)
                let withinFile =
                    reported.bytesTotal > 0
                    ? Double(reported.bytesDownloaded) / Double(reported.bytesTotal) : 0
                let total = Double(max(reported.totalFiles, 1))
                progress?(min(1.0, (completedFiles + withinFile) / total))
            }
        )
    }

    // MARK: - SpeechRecognitionEngine

    /// Moonshine wants 16 kHz mono float samples.
    public func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    }

    public func prepare() async throws {
        try await install()
    }

    public nonisolated var biasesTowardPhrases: Bool { true }

    public func setContextualPhrases(_ phrases: [String]) async {
        keyterms = phrases
        // Applied on the next session; the transcriber takes them globally.
        try? transcriber?.setKeyterms(phrases)
    }

    public func beginSession() async throws -> AsyncStream<TranscriptUpdate> {
        try await prepare()
        guard let transcriber else { throw SpeechEngineError.noSession }

        // Bias recognition toward the user's own terms.
        if !keyterms.isEmpty { try? transcriber.setKeyterms(keyterms) }

        let created = try transcriber.createStream(updateInterval: 0.25)
        try created.start()
        stream = created
        lastPartial = ""

        let (updates, continuation) = AsyncStream<TranscriptUpdate>.makeStream()
        updateContinuation = continuation

        let (audioStream, audioContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        audioPipe.attach(audioContinuation)
        feedTask = Task { [weak self] in
            for await buffer in audioStream {
                await self?.feed(buffer)
            }
        }

        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                await self?.pump()
            }
        }

        return updates
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let stream, let samples = Self.samples(from: buffer) else { return }
        try? stream.addAudio(samples, sampleRate: Int32(buffer.format.sampleRate))
    }

    /// Extracts mono float samples from a buffer.
    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func pump() {
        guard let stream, let transcript = try? stream.updateTranscription() else { return }
        emit(Self.text(from: transcript))
    }

    private static func text(from transcript: Transcript) -> String {
        transcript.lines.map(\.text).joined(separator: " ")
    }

    private func emit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastPartial else { return }
        lastPartial = trimmed
        updateContinuation?.yield(TranscriptUpdate(text: trimmed, isFinal: false))
    }

    public nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        audioPipe.yield(buffer)
    }

    public func finishSession() async throws -> String {
        pumpTask?.cancel()
        pumpTask = nil

        // Drain every buffer before finalizing, or the tail is lost.
        audioPipe.finish()
        await feedTask?.value
        feedTask = nil

        guard let stream else { throw SpeechEngineError.noSession }

        // A streaming decoder needs trailing audio to close its final window.
        // Speech that stops abruptly — which is exactly what releasing the key
        // produces — otherwise loses its last word ("afternoon" as "after").
        let silence = [Float](repeating: 0, count: 16000 / 2)
        try? stream.addAudio(silence, sampleRate: 16000)
        try? await Task.sleep(for: .milliseconds(120))

        try? stream.stop()

        // Decoding the tail continues briefly after stop(), so read until the
        // text settles. Without this the final word is routinely truncated
        // ("afternoon" arriving as "after").
        var transcript = (try? stream.updateTranscription()).map(Self.text(from:)) ?? lastPartial
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(40))
            guard let latest = (try? stream.updateTranscription()).map(Self.text(from:))
            else { break }
            if latest == transcript { break }
            transcript = latest
        }

        stream.close()
        self.stream = nil

        updateContinuation?.yield(TranscriptUpdate(text: transcript, isFinal: true))
        updateContinuation?.finish()
        updateContinuation = nil
        lastPartial = ""

        return TextNormalizer.finalize(transcript)
    }

    public func cancelSession() async {
        pumpTask?.cancel()
        pumpTask = nil
        audioPipe.finish()
        feedTask?.cancel()
        feedTask = nil
        try? stream?.stop()
        stream?.close()
        stream = nil
        updateContinuation?.finish()
        updateContinuation = nil
        lastPartial = ""
    }

    public func releaseModels() async {
        await cancelSession()
        transcriber?.close()
        transcriber = nil
    }
}
