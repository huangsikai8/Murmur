import AVFoundation
import Foundation

/// One recording, several model combinations, nothing inserted.
///
/// The audio is captured once and replayed into each model in turn, rather than
/// running every model against the live microphone. That ordering is the whole
/// design:
///
/// * Peak memory stays at one model, so combinations that could never be
///   resident together — two 4B cleanup models, say — can still be compared.
/// * Timings are not distorted by several models contending for the ANE.
/// * The same audio can be replayed after a bubble is added or reconfigured,
///   so a comparison can be extended without speaking again.
///
/// Nothing here touches `TextInserting`. A comparison never puts text into
/// another application, which is why it is allowed to show speculative output
/// at all.
public enum ModelComparison {

    // MARK: - Captured audio

    /// Captured audio in the one format every engine can be fed from.
    ///
    /// 16 kHz mono float is the detector's format, which each engine either
    /// asks for directly or resamples from — the same reasoning that makes it
    /// `HandsFreeSession`'s input format. Conversion into whatever a particular
    /// engine wants happens here, per engine, at replay time.
    public struct Recording: Sendable, Equatable {
        public static let sampleRate: Double = 16000

        public let samples: [Float]

        public init(samples: [Float]) {
            self.samples = samples
        }

        public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
        public var isEmpty: Bool { samples.isEmpty }

        /// The format `samples` are in.
        public static var format: AVAudioFormat? {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false)
        }
    }

    /// Accumulates microphone buffers, which arrive on the audio thread.
    public final class RecordingBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []

        public init() {}

        public func append(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let incoming = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            lock.lock()
            samples.append(contentsOf: incoming)
            lock.unlock()
        }

        public var sampleCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return samples.count
        }

        public var duration: TimeInterval { Double(sampleCount) / Recording.sampleRate }

        public func recording() -> Recording {
            lock.lock()
            defer { lock.unlock() }
            return Recording(samples: samples)
        }

        public func reset() {
            lock.lock()
            samples.removeAll()
            lock.unlock()
        }
    }

    // MARK: - Configuration

    /// One bubble: a speech model, and optionally a cleanup model to run its
    /// text through.
    public struct BubbleConfig: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let speechModelID: String
        /// `nil` shows the raw transcript, which is also the only way to see
        /// what a speech model actually produces.
        public let cleanupModelID: String?
        public let cleanupLevel: CleanupLevel

        public init(
            id: UUID = UUID(),
            speechModelID: String,
            cleanupModelID: String? = nil,
            cleanupLevel: CleanupLevel = .off
        ) {
            self.id = id
            self.speechModelID = speechModelID
            self.cleanupModelID = cleanupModelID
            self.cleanupLevel = cleanupLevel
        }

        /// A cleanup model selected at level `off` does nothing, and loading
        /// gigabytes of weights to do nothing is worth avoiding.
        public var wantsCleanup: Bool { cleanupModelID != nil && cleanupLevel != .off }

        /// How this bubble should be labelled in a comparison.
        public var label: String {
            let speech = ModelCatalog.model(id: speechModelID)?.name ?? speechModelID
            guard wantsCleanup, let cleanupModelID else { return speech }
            let cleanup = ModelCatalog.model(id: cleanupModelID)?.name ?? cleanupModelID
            return "\(speech) + \(cleanup) (\(cleanupLevel.displayName))"
        }
    }

    /// Bubbles that share one model, so it is loaded and run once for all of them.
    public struct Group: Sendable, Equatable {
        public let modelID: String
        public let bubbles: [BubbleConfig]
    }

    // MARK: - Progress

    public enum Event: Sendable, Equatable {
        /// A model is being loaded. Emitted before the wait, not after, so a
        /// slow first load reads as progress rather than as a hang.
        case loading(modelID: String)
        case transcribed(bubble: UUID, text: String, firstPartialMs: Int, decodeMs: Int)
        case cleaned(bubble: UUID, text: String, elapsedMs: Int)
        case failed(bubble: UUID, message: String)
    }

    // MARK: - Grouping

    /// Distinct speech models, in the order their first bubble appears.
    ///
    /// Two bubbles differing only in cleanup model share a transcript: the
    /// audio is decoded once and the text fanned out. Without this, comparing
    /// four cleanup models against one recognizer would decode the same audio
    /// four times, and any variation between those decodes would read as a
    /// difference between the cleanup models.
    public static func speechGroups(_ bubbles: [BubbleConfig]) -> [Group] {
        group(bubbles) { $0.speechModelID }
    }

    /// Distinct cleanup models, in first-appearance order, over the bubbles
    /// that actually want cleaning.
    public static func cleanupGroups(_ bubbles: [BubbleConfig]) -> [Group] {
        group(bubbles.filter(\.wantsCleanup)) { $0.cleanupModelID ?? "" }
    }

    private static func group(
        _ bubbles: [BubbleConfig], by key: (BubbleConfig) -> String
    ) -> [Group] {
        var order: [String] = []
        var members: [String: [BubbleConfig]] = [:]
        for bubble in bubbles {
            let identifier = key(bubble)
            if members[identifier] == nil { order.append(identifier) }
            members[identifier, default: []].append(bubble)
        }
        return order.map { Group(modelID: $0, bubbles: members[$0] ?? []) }
    }

    // MARK: - Running

    /// Replays `recording` through every bubble, emitting results as they land.
    ///
    /// Speech models run first, then cleanup models, each loaded and released
    /// before the next. Results therefore arrive out of bubble order, which is
    /// why every event carries the bubble it belongs to.
    public static func run(
        _ recording: Recording,
        bubbles: [BubbleConfig]
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            // Detached on purpose. Called from a SwiftUI model this would
            // otherwise inherit the main actor, and loading a model plus
            // converting a few seconds of audio there would freeze the window
            // it is reporting into.
            let work = Task.detached(priority: .userInitiated) {
                var transcripts: [UUID: String] = [:]

                for group in speechGroups(bubbles) {
                    if Task.isCancelled { break }
                    continuation.yield(.loading(modelID: group.modelID))
                    do {
                        let outcome = try await transcribe(recording, modelID: group.modelID)
                        for bubble in group.bubbles {
                            transcripts[bubble.id] = outcome.text
                            continuation.yield(
                                .transcribed(
                                    bubble: bubble.id,
                                    text: outcome.text,
                                    firstPartialMs: outcome.firstPartialMs,
                                    decodeMs: outcome.decodeMs))
                        }
                    } catch {
                        for bubble in group.bubbles {
                            continuation.yield(
                                .failed(bubble: bubble.id, message: error.localizedDescription))
                        }
                    }
                }

                for group in cleanupGroups(bubbles) {
                    if Task.isCancelled { break }
                    // A bubble whose transcription failed has nothing to clean.
                    let pending = group.bubbles.filter { transcripts[$0.id] != nil }
                    guard !pending.isEmpty else { continue }

                    continuation.yield(.loading(modelID: group.modelID))
                    guard let cleaner = cleaner(for: group.modelID) else {
                        for bubble in pending {
                            continuation.yield(
                                .failed(
                                    bubble: bubble.id,
                                    message: "No cleanup engine implements \(group.modelID)."))
                        }
                        continue
                    }

                    do {
                        try await cleaner.prepare()
                    } catch {
                        for bubble in pending {
                            continuation.yield(
                                .failed(bubble: bubble.id, message: error.localizedDescription))
                        }
                        await cleaner.releaseModels()
                        continue
                    }

                    for bubble in pending {
                        if Task.isCancelled { break }
                        guard let raw = transcripts[bubble.id] else { continue }
                        let start = ContinuousClock.now
                        do {
                            let cleaned = try await cleaner.clean(raw, level: bubble.cleanupLevel)
                            continuation.yield(
                                .cleaned(
                                    bubble: bubble.id,
                                    text: cleaned,
                                    elapsedMs: milliseconds(since: start)))
                        } catch {
                            continuation.yield(
                                .failed(bubble: bubble.id, message: error.localizedDescription))
                        }
                    }
                    await cleaner.releaseModels()
                }

                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: - One model

    private struct Outcome {
        let text: String
        /// Negative for engines that decode on release and emit no partials.
        let firstPartialMs: Int
        let decodeMs: Int
    }

    /// Loads one speech model, replays the whole recording through it, and
    /// releases it again before returning.
    private static func transcribe(
        _ recording: Recording, modelID: String
    ) async throws -> Outcome {
        guard let engine = SpeechEngineFactory.engine(for: modelID) else {
            // Deliberately not falling back to Apple's recognizer: a
            // comparison that silently ran the same engine twice under two
            // names would be worse than one that reported a gap.
            throw SpeechEngineError.unavailable("No engine implements \(modelID).")
        }

        do {
            try await engine.prepare()
            let format = await engine.preferredInputFormat()
            let chunks = try buffers(for: recording, in: format)

            let updates = try await engine.beginSession()
            let start = ContinuousClock.now
            let firstPartial = FirstMark()
            let collector = Task {
                for await update in updates where !update.text.isEmpty {
                    firstPartial.recordIfUnset(ContinuousClock.now)
                }
            }

            // Replayed at the speed it was spoken, not as fast as the CPU can
            // push it. Two reasons, and both are load-bearing: a whole
            // utterance fed in microseconds reports a "first partial" no
            // listener could ever experience, and cache-aware streaming models
            // are built around chunks arriving in real time, so feeding them
            // all at once is not the workload they are designed for.
            for (index, chunk) in chunks.enumerated() {
                try? await Task.sleep(
                    until: start + .milliseconds(index * chunkMilliseconds), clock: .continuous)
                engine.append(chunk)
            }

            let released = ContinuousClock.now
            let text = try await engine.finishSession()
            collector.cancel()
            await engine.releaseModels()

            // A batch engine delivers its one and only result through the same
            // stream, during finalization. Counting that as a partial would
            // report live text for an engine that shows none for the whole
            // hold — so a partial only counts if it arrived before the audio
            // ended. Measured rather than read off the catalog's `streams`
            // flag, so a mislabelled model cannot launder a wrong number.
            let partial = firstPartial.value.flatMap { $0 < released ? $0 : nil }

            return Outcome(
                text: text,
                firstPartialMs: partial.map { Int(($0 - start) / .milliseconds(1)) } ?? -1,
                decodeMs: milliseconds(since: released))
        } catch {
            await engine.releaseModels()
            throw error
        }
    }

    /// Splits the recording into tap-sized buffers in the engine's own format.
    ///
    /// The conversion is not optional: Apple's SpeechAnalyzer traps inside the
    /// Speech framework when handed a format it did not ask for. A nil
    /// preferred format means the engine resamples internally.
    private static func buffers(
        for recording: Recording, in format: AVAudioFormat?
    ) throws -> [AVAudioPCMBuffer] {
        guard let source = Recording.format else {
            throw SpeechEngineError.audioFormatUnavailable
        }

        let chunkFrames = Int(Recording.sampleRate) * chunkMilliseconds / 1000
        var converter: AVAudioConverter?
        if let format, format != source {
            guard let built = AVAudioConverter(from: source, to: format) else {
                throw SpeechEngineError.audioFormatUnavailable
            }
            converter = built
        }

        var output: [AVAudioPCMBuffer] = []
        var position = 0
        while position < recording.samples.count {
            let count = min(chunkFrames, recording.samples.count - position)
            guard
                let chunk = AVAudioPCMBuffer(
                    pcmFormat: source, frameCapacity: AVAudioFrameCount(count))
            else { break }
            chunk.frameLength = AVAudioFrameCount(count)
            recording.samples.withUnsafeBufferPointer { samples in
                chunk.floatChannelData?[0].update(
                    from: samples.baseAddress! + position, count: count)
            }
            position += count

            guard let converter, let format else {
                output.append(chunk)
                continue
            }
            guard let converted = AudioFormatConverter.convert(chunk, using: converter, to: format)
            else { continue }
            output.append(converted)
        }
        return output
    }

    /// The cleanup engine for a model ID, or `nil` when none implements it.
    ///
    /// Unknown IDs return `nil` rather than Apple's cleaner for the same reason
    /// `SpeechEngineFactory` does: a silent substitution here would compare a
    /// model against itself and report the two as equally good.
    public static func cleaner(for modelID: String) -> (any TranscriptCleaner)? {
        if let variant = MLXCleaner.Variant.from(modelID: modelID) {
            return MLXCleaner(variant: variant)
        }
        if modelID == ModelCatalog.appleCorrectionID { return FoundationModelsCleaner() }
        return nil
    }

    /// Chunk size for replay: the same granularity the microphone tap
    /// delivers, so an engine sees the arrival pattern it would see in real use.
    private static let chunkMilliseconds = 100

    private static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - instant) / .milliseconds(1))
    }
}

/// Records only the first value it is given.
private final class FirstMark: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ContinuousClock.Instant?

    func recordIfUnset(_ value: ContinuousClock.Instant) {
        lock.lock()
        defer { lock.unlock() }
        if storage == nil { storage = value }
    }

    var value: ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
