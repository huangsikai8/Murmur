import AVFoundation
import FluidAudio
import Foundation

/// `SpeechRecognitionEngine` backed by FluidAudio's Core ML streaming models.
///
/// Covers the downloadable NVIDIA engines: Parakeet Realtime EOU 120M and
/// Nemotron 0.6B. Weights are fetched from Hugging Face on first use and cached
/// on disk; after that the engine runs entirely offline like the Apple one.
public actor FluidAudioEngine: SpeechRecognitionEngine {

    public static let engineName = "FluidAudio (Core ML)"

    /// Which downloadable model this instance drives.
    public enum Variant: String, Sendable, CaseIterable {
        case parakeetEou
        case nemotron
        /// Nemotron at NVIDIA's trained 1.12 s chunk. Same weights family as
        /// `.nemotron`, half the wait between partials, and a separate
        /// download — the tiers are distinct repositories.
        case nemotronFast
        /// The lowest-latency tier. Furthest from the 1.12 s chunk the model
        /// was trained on, so accuracy is the thing to watch here.
        case nemotronFastest

        public var modelID: String {
            switch self {
            case .parakeetEou: "nvidia.parakeet-realtime-eou-120m"
            case .nemotron: "nvidia.nemotron-streaming-en-0.6b"
            case .nemotronFast: "nvidia.nemotron-streaming-en-0.6b-1120ms"
            case .nemotronFastest: "nvidia.nemotron-streaming-en-0.6b-560ms"
            }
        }

        /// How much speech accumulates before the recognizer emits new text.
        var nemotronChunk: NemotronChunkSize? {
            switch self {
            case .nemotron: .ms2240
            case .nemotronFast: .ms1120
            case .nemotronFastest: .ms560
            case .parakeetEou: nil
            }
        }

        public static func from(modelID: String) -> Variant? {
            allCases.first { $0.modelID == modelID }
        }

        /// The exact folder FluidAudio caches this variant under. Matching
        /// loosely on "parakeet" would wrongly count unrelated Parakeet models
        /// that another app may already have downloaded.
        public var cacheFolderName: String { cacheFolder }

        /// Includes the latency tier, because FluidAudio stores every tier in
        /// a sibling folder under one parent. Checking the parent would report
        /// a tier as installed whenever any other tier had been downloaded.
        var cacheFolder: String {
            switch self {
            case .parakeetEou: "parakeet-eou-streaming"
            case .nemotron: "nemotron-streaming/2240ms"
            case .nemotronFast: "nemotron-streaming/1120ms"
            case .nemotronFastest: "nemotron-streaming/560ms"
            }
        }
    }

    private let variant: Variant
    private var manager: (any StreamingAsrManager)?

    /// Drives partial results while audio is still arriving.
    private var pumpTask: Task<Void, Never>?
    private var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var lastPartial = ""

    /// Ordered path from the audio thread into the manager, plus the task that
    /// drains it. Both must complete before the transcript is finalized.
    private let audioPipe = StreamPipe<AVAudioPCMBuffer>()
    private var feedTask: Task<Void, Never>?

    public init(variant: Variant) {
        self.variant = variant
    }

    // MARK: - Installation

    /// Where FluidAudio caches its Core ML bundles.
    public static var modelsDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Whether this variant's weights are already on disk.
    public static func isInstalled(_ variant: Variant) -> Bool {
        let folder = modelsDirectory.appendingPathComponent(variant.cacheFolder, isDirectory: true)
        // For variants whose folder already names a tier this looks only at
        // that tier. Parakeet EOU still points at its parent, where any
        // populated tier means the model is usable.
        //
        // Enumerated lazily and abandoned at the first hit: listing the whole
        // tree first means walking hundreds of megabytes of weights to answer a
        // question the first few entries usually settle.
        guard let entries = FileManager.default.enumerator(atPath: folder.path) else {
            return false
        }
        for case let path as String in entries
        where path.hasSuffix(".mlmodelc") || path.hasSuffix(".json") {
            return true
        }
        return false
    }

    /// Bytes currently occupied by this variant's cache.
    public static func installedSizeBytes(_ variant: Variant) -> Int64 {
        let folder = modelsDirectory.appendingPathComponent(variant.cacheFolder, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Downloads and loads the model. Requires an internet connection the first
    /// time only.
    public func install() async throws {
        try await prepare()
    }

    /// Deletes the cached weights for this variant, and nothing else.
    public static func delete(_ variant: Variant) throws {
        let folder = modelsDirectory.appendingPathComponent(variant.cacheFolder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: - SpeechRecognitionEngine

    /// FluidAudio resamples internally, so the hardware format is fine.
    public func preferredInputFormat() async -> AVAudioFormat? { nil }

    public func prepare() async throws {
        guard manager == nil else { return }
        let created: any StreamingAsrManager =
            switch variant {
            case .parakeetEou: StreamingEouAsrManager()
            case .nemotron, .nemotronFast, .nemotronFastest:
                StreamingNemotronAsrManager(requestedChunkSize: variant.nemotronChunk)
            }
        try await created.loadModels()
        manager = created
        FluidAudioEngine.debugLog("models loaded for \(variant)")
    }

    public func beginSession() async throws -> AsyncStream<TranscriptUpdate> {
        try await prepare()
        guard let manager else { throw SpeechEngineError.noSession }

        try await manager.reset()
        lastPartial = ""
        fedBuffers = 0

        let (updates, continuation) = AsyncStream<TranscriptUpdate>.makeStream()
        updateContinuation = continuation

        let (audioStream, audioContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        audioPipe.attach(audioContinuation)
        feedTask = Task { [weak self] in
            for await buffer in audioStream {
                await self?.feed(buffer)
            }
        }

        await manager.setPartialTranscriptCallback { [weak self] text in
            Task { await self?.emitPartial(text) }
        }

        // Chunk-based engines only decode when asked, so drive them steadily
        // while the key is held.
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                await self?.pump()
            }
        }

        return updates
    }

    private func pump() async {
        guard let manager else { return }
        try? await manager.processBufferedAudio()
        let partial = await manager.getPartialTranscript()
        emitPartial(partial)
    }

    private func emitPartial(_ text: String) {
        guard !text.isEmpty, text != lastPartial else { return }
        lastPartial = text
        updateContinuation?.yield(TranscriptUpdate(text: text, isFinal: false))
    }

    public nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        audioPipe.yield(buffer)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) async {
        guard let manager else {
            FluidAudioEngine.debugLog("feed: manager is nil")
            return
        }
        do {
            if fedBuffers == 0 {
                let format = buffer.format
                FluidAudioEngine.debugLog(
                    "first buffer: \(Int(format.sampleRate)) Hz, "
                        + "\(format.channelCount) ch, "
                        + "common=\(format.commonFormat.rawValue), "
                        + "interleaved=\(format.isInterleaved), "
                        + "frames=\(buffer.frameLength)"
                )
            }
            try await manager.appendAudio(buffer)
            fedBuffers += 1
        } catch {
            FluidAudioEngine.debugLog("appendAudio threw: \(error)")
        }
    }

    /// Diagnostics for the command-line self-test.
    public nonisolated(unsafe) static var debugEnabled = false
    private var fedBuffers = 0

    static func debugLog(_ message: String) {
        guard debugEnabled else { return }
        print("[fluidaudio] \(message)")
    }

    public func diagnostics() -> String {
        "buffers fed: \(fedBuffers), partial: \"\(lastPartial)\""
    }

    public func finishSession() async throws -> String {
        pumpTask?.cancel()
        pumpTask = nil

        // Every buffer must reach the manager before it is asked to finalize,
        // or the tail of the recording is silently dropped.
        audioPipe.finish()
        await feedTask?.value
        feedTask = nil

        guard let manager else { throw SpeechEngineError.noSession }

        FluidAudioEngine.debugLog("finishing after \(fedBuffers) buffers")
        // Chunk-based engines only decode when asked; make sure everything
        // buffered has been through the encoder before finalizing.
        try? await manager.processBufferedAudio()
        let staged = await manager.getPartialTranscript()
        FluidAudioEngine.debugLog("partial before finish: \"\(staged)\"")
        let transcript = try await manager.finish()
        FluidAudioEngine.debugLog("finish() returned \"\(transcript)\"")
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
        updateContinuation?.finish()
        updateContinuation = nil
        lastPartial = ""
        try? await manager?.reset()
    }

    public func releaseModels() async {
        await cancelSession()
        await manager?.cleanup()
        manager = nil
    }
}
