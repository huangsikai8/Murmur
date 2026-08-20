import AVFoundation
import Foundation
import MurmurCore

/// `Murmur --testvad` — measures where the detector thinks speech starts and
/// stops, against synthesized sentences separated by known gaps of silence.
///
/// Hands-free dictation is only as good as this boundary: an early end clips a
/// sentence, a late one merges two, and neither is visible from reading code.
enum VadTest {

    private static let sentences = [
        "Hello, I'm testing this feature.",
        "Can you move the meeting to Thursday afternoon?",
        "Yes, I think you've got the issue right.",
        // Deliberately longer than Nemotron's 2240 ms chunk. With shorter
        // sentences the whole utterance arrives as a single chunk, and an
        // overlay that replaces rather than accumulates looks identical to one
        // that works.
        "I would like to schedule a follow up meeting with the whole team early "
            + "next week so that we can review the quarterly numbers together.",
    ]

    /// Silence inserted between sentences, comfortably above the 0.75 s the
    /// detector needs to call an utterance finished.
    private static let gapSeconds = 1.2

    static func run(silenceDuration: TimeInterval) async -> Int32 {
        print("Murmur voice-activity self-test")
        print("Chunk \(VoiceActivityDetector.chunkSize) samples ", terminator: "")
        print("(\(Int(Double(VoiceActivityDetector.chunkSize) / 16000 * 1000)) ms) at 16 kHz\n")

        let detector = VoiceActivityDetector(
            tuning: VoiceActivityDetector.Tuning(silenceDuration: silenceDuration))
        print("Silence threshold: \(Int(silenceDuration * 1000)) ms")
        let prepareStart = ContinuousClock.now
        do {
            try await detector.prepare()
        } catch {
            print("  FAILED to load VAD: \(error.localizedDescription)")
            return 1
        }
        print("Model ready in \(SpeechFixture.milliseconds(since: prepareStart)) ms\n")

        let samples: [Float]
        let speechRanges: [(Double, Double)]
        do {
            (samples, speechRanges) = try buildTrack()
        } catch {
            print("  FAILED to synthesize: \(error.localizedDescription)")
            return 1
        }

        print("Track: \(String(format: "%.1f", seconds(samples.count))) s, ")
        for (index, range) in speechRanges.enumerated() {
            print(
                "  sentence \(index + 1) speaks "
                    + "\(String(format: "%.2f", range.0))–\(String(format: "%.2f", range.1)) s")
        }
        print("")

        // Feed in 100 ms slices, the granularity the microphone tap delivers.
        let sliceSize = 1600
        var detected: [(VoiceActivityDetector.Event, Double)] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + sliceSize, samples.count)
            let slice = Array(samples[offset..<end])
            do {
                for event in try await detector.process(slice) {
                    detected.append((event, seconds(end)))
                }
            } catch {
                print("  FAILED during processing: \(error.localizedDescription)")
                return 1
            }
            offset = end
        }

        for (event, at) in detected {
            let name = event == .speechStarted ? "speech started" : "speech ended  "
            print("  \(name) at \(String(format: "%.2f", at)) s")
        }
        print("")

        let starts = detected.filter { $0.0 == .speechStarted }.count
        let ends = detected.filter { $0.0 == .speechEnded }.count
        print("Detected \(starts) start(s) and \(ends) end(s) ", terminator: "")
        print("for \(sentences.count) sentences.")

        guard starts == sentences.count, ends == sentences.count else {
            print("\nFAILED: expected one start and one end per sentence.")
            print("Merged utterances mean the silence threshold is too long;")
            print("extra ones mean it is too short or the threshold too twitchy.\n")
            return 1
        }

        // The detector confirms speech a chunk or so after it truly begins.
        // That lag is what the pre-roll buffer has to cover, so report it.
        var worstLateStart = 0.0
        for (index, range) in speechRanges.enumerated() {
            let startAt = detected.filter { $0.0 == .speechStarted }[index].1
            worstLateStart = max(worstLateStart, startAt - range.0)
        }
        // The gap between speech truly stopping and the detector saying so is
        // the wait before text appears in hands-free mode. It is the single
        // number that decides whether the mode feels responsive.
        var worstEndLag = 0.0
        var totalEndLag = 0.0
        let endEvents = detected.filter { $0.0 == .speechEnded }
        for (index, range) in speechRanges.enumerated() {
            let lag = endEvents[index].1 - range.1
            worstEndLag = max(worstEndLag, lag)
            totalEndLag += lag
        }
        let averageEndLag = totalEndLag / Double(speechRanges.count)

        print(
            "Start lag: \(Int(worstLateStart * 1000)) ms worst "
                + "— pre-roll must cover at least this.")
        print(
            "End lag:   \(Int(averageEndLag * 1000)) ms average, "
                + "\(Int(worstEndLag * 1000)) ms worst "
                + "— the wait before text appears.\n")
        return 0
    }

    // MARK: - Whole-pipeline test

    /// `Murmur --testhandsfree [modelID]` — drives the real `HandsFreeSession`
    /// with synthesized speech, so continuous dictation is verified end to end
    /// without a microphone, exactly as `--selftest` does for push-to-talk.
    static func runPipeline(
        modelID: String,
        silenceDuration: TimeInterval = VoiceActivityDetector.Tuning().silenceDuration
    ) async -> Int32 {
        ModelCatalog.coreMLEngineWired = true
        ModelCatalog.moonshineEngineWired = true

        print("Murmur hands-free self-test")
        print("Engine: \(ModelCatalog.model(id: modelID)?.name ?? modelID)")
        print("Silence threshold: \(Int(silenceDuration * 1000)) ms\n")

        guard let engine = SpeechEngineFactory.engine(for: modelID) else {
            print("  FAILED: no engine implements \(modelID)")
            return 1
        }

        let session = HandsFreeSession(
            engine: engine,
            tuning: VoiceActivityDetector.Tuning(silenceDuration: silenceDuration))
        do {
            try await session.prepare()
        } catch {
            print("  FAILED to prepare: \(error.localizedDescription)")
            return 1
        }

        let samples: [Float]
        do {
            (samples, _) = try buildTrack()
        } catch {
            print("  FAILED to synthesize: \(error.localizedDescription)")
            return 1
        }

        guard let format = session.inputFormat else {
            print("  FAILED: no input format")
            return 1
        }

        // The longest partial seen for the utterance in progress. If the
        // overlay were being handed each chunk instead of the accumulated
        // text, this would stay a few words long however much was said.
        let partials = PartialTracker()
        await session.setPartialHandler { text in partials.record(text) }

        var transcripts: [String] = []
        var longestPartials: [Int] = []
        var cadences: [(average: Int, worst: Int, count: Int)] = []
        var finalizeMs: [Int] = []
        var offset = 0
        let sliceSize = 1600
        while offset < samples.count {
            let end = min(offset + sliceSize, samples.count)
            guard let buffer = makeBuffer(Array(samples[offset..<end]), format: format) else {
                break
            }
            // The ingest call that closes an utterance is the one that runs
            // the engine's finalize step, so timing it isolates the wait
            // between the detector saying "stopped" and text existing.
            let ingestStart = ContinuousClock.now
            let events = await session.ingest(buffer)
            let ingestMs = (ContinuousClock.now - ingestStart) / .milliseconds(1)
            for event in events {
                switch event {
                case .utteranceBegan: partials.reset()
                // This path runs without a turn detector, so a held
                // turn cannot occur here.
                case .turnHeld: break
                case .transcript(let text):
                    transcripts.append(text)
                    longestPartials.append(partials.longestWordCount)
                    cadences.append(partials.cadence)
                    finalizeMs.append(Int(ingestMs))
                case .utteranceDiscarded: partials.reset()
                }
            }
            offset = end
        }

        var failures = 0
        for (index, expected) in sentences.enumerated() {
            guard index < transcripts.count else {
                print("  ✗ \"\(expected)\" — never produced")
                failures += 1
                continue
            }
            let got = transcripts[index]
            let matched = normalize(got) == normalize(expected)
            print("  \(matched ? "✓" : "✗") \"\(expected)\"")
            if !matched {
                print("      got: \"\(got)\"")
                // A clipped first word is the pre-roll failing, and is the
                // reason this test exists at all.
                failures += 1
            }
        }
        if transcripts.count > sentences.count {
            print("  ✗ produced \(transcripts.count) utterances for \(sentences.count) sentences")
            for extra in transcripts[sentences.count...] { print("      extra: \"\(extra)\"") }
            failures += 1
        }

        if !finalizeMs.isEmpty {
            let worst = finalizeMs.max() ?? 0
            let average = finalizeMs.reduce(0, +) / finalizeMs.count
            print("")
            print(
                "  Finalize after speech ends: \(average) ms average, \(worst) ms worst")
            print(
                "  Detector endpoint adds ~"
                    + "\(Int(silenceDuration * 1000 + 480)) ms before this even starts.")
        }

        // Only streaming engines emit partials; a batch engine legitimately
        // emits none, so this only holds where live text is claimed.
        if SpeechEngineFactory.streamsLiveText(for: modelID) == true {
            for (index, longest) in longestPartials.enumerated() where index < transcripts.count {
                let spoken = transcripts[index].split(separator: " ").count
                let cadence:
                    (average: Int, worst: Int, count: Int) =
                        index < cadences.count ? cadences[index] : (0, 0, 0)
                let updates = cadence.count
                let average = cadence.average
                let worst = cadence.worst
                print(
                    "      partial grew to \(longest)/\(spoken) words over \(updates) update(s)"
                )
                // Wall-clock gaps are meaningless here: this test feeds audio
                // far faster than realtime. The number of updates across one
                // utterance is what says whether live text feels live.
                _ = (average, worst)
                // Half is generous: the last chunk alone would be far below it.
                if longest * 2 < spoken {
                    print("      ✗ live text never accumulated — chunks are replacing it")
                    failures += 1
                }
            }
        }

        print("")
        if failures > 0 {
            print("FAILED: \(failures) problem(s) in continuous dictation.\n")
            return 1
        }
        print("All \(sentences.count) utterances segmented and transcribed exactly.\n")
        return 0
    }

    /// Records partials from the session's callback, which is `@Sendable` and
    /// fires off the main actor.
    private final class PartialTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var longest = 0
        private var previousAt: ContinuousClock.Instant?
        private var gaps: [Double] = []

        func record(_ text: String) {
            let words = text.split(separator: " ").count
            let now = ContinuousClock.now
            lock.lock()
            longest = max(longest, words)
            // How long the overlay sat unchanged. This, not the word count, is
            // what "it does not feel like it is streaming" actually measures.
            if let previousAt { gaps.append((now - previousAt) / .milliseconds(1)) }
            previousAt = now
            lock.unlock()
        }

        func reset() {
            lock.lock()
            longest = 0
            previousAt = nil
            gaps.removeAll()
            lock.unlock()
        }

        var longestWordCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return longest
        }

        /// Average and worst gap between overlay updates, in milliseconds.
        var cadence: (average: Int, worst: Int, count: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard !gaps.isEmpty else { return (0, 0, 0) }
            return (Int(gaps.reduce(0, +) / Double(gaps.count)), Int(gaps.max() ?? 0), gaps.count + 1)
        }
    }

    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        return buffer
    }

    /// Compares on words alone: punctuation differences between engines are not
    /// what this test is about, missing or merged words are.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Track construction

    /// Renders every sentence with `say` and concatenates them with silence,
    /// returning the samples and where speech actually sits in the timeline.
    private static func buildTrack() throws -> ([Float], [(Double, Double)]) {
        var samples: [Float] = []
        var ranges: [(Double, Double)] = []

        // Lead-in silence, so the first sentence does not start at sample zero.
        samples.append(contentsOf: [Float](repeating: 0, count: 16000 / 2))

        for sentence in sentences {
            let url = try SpeechFixture.synthesize(sentence, float: true)
            defer { try? FileManager.default.removeItem(at: url) }
            let spoken = try read(url)

            let start = seconds(samples.count)
            samples.append(contentsOf: spoken)
            ranges.append((start, seconds(samples.count)))

            samples.append(
                contentsOf: [Float](repeating: 0, count: Int(gapSeconds * 16000)))
        }
        return (samples, ranges)
    }

    private static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }


    private static func seconds(_ sampleCount: Int) -> Double {
        Double(sampleCount) / 16000
    }

}
