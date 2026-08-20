import AVFoundation
import Foundation
import MurmurCore

/// `Murmur --testtail` — does the last word survive when the audio stops dead?
///
/// Every other speech test here feeds a file `say` produced, and `say` leaves
/// trailing silence after the final word. A latch does not: you stop talking
/// and tap, so the recording ends on the last sample of speech and the decoder
/// is asked to finalize a chunk it never finished filling. That is the one
/// condition none of the existing measurements cover, and it is precisely
/// where a streaming decoder truncates — Moonshine turned "afternoon" into
/// "after" for exactly this reason.
///
/// Each sentence is run twice through the same engine: once as synthesized,
/// once with the trailing silence cut off. Only the ending differs, so a word
/// lost in the second arm and kept in the first is truncation, not
/// misrecognition.
enum TailTest {

    /// Endings chosen to be worth truncating: long final words, and final
    /// words whose prefix is itself a word.
    static let sentences = [
        "Can you move the meeting to Thursday afternoon",
        "I will send you the document tomorrow morning",
        "The quarterly report is finished and uploaded",
        "Let me know whether that works for everyone",
    ]

    /// Cuts `extraClipMs` of real speech off the end as well, which is how
    /// this test is checked: a passing run means nothing unless the same run
    /// fails when audio really is missing. 500 ms loses the final word on every
    /// sentence here, on every engine.
    static func run(modelID: String?, extraClipMs: Int = 0) async -> Int32 {
        ModelCatalog.coreMLEngineWired = true
        ModelCatalog.moonshineEngineWired = true

        let ids = modelID.map { [$0] } ?? speechModelIDs()
        print("Murmur tail-truncation test")
        print("Audio is cut at the last sample of speech, then finalized with no")
        print("settle time — the latch case: stop talking, tap immediately.")
        if extraClipMs > 0 {
            print("Plus \(extraClipMs) ms of real speech removed, which must FAIL.")
        }
        print("")

        var failures = 0
        for id in ids {
            guard let engine = SpeechEngineFactory.engine(for: id) else {
                print("  FAILED: no engine implements \(id)")
                failures += 1
                continue
            }
            let name = ModelCatalog.model(id: id)?.name ?? id
            print("── \(name)")
            do {
                try await engine.prepare()
            } catch {
                print("   FAILED to prepare: \(error.localizedDescription)\n")
                failures += 1
                continue
            }
            failures += await measure(engine: engine, extraClipMs: extraClipMs)
            await engine.releaseModels()
            print("")
        }

        if failures > 0 {
            print("FAILED: \(failures) truncation(s) at the end of the audio.\n")
            return 1
        }
        print("No truncation: every clipped ending kept its final word.\n")
        return 0
    }

    /// Apple's recognizer plus every installed speech model, which is what the
    /// app can actually be set to.
    private static func speechModelIDs() -> [String] {
        var ids = [ModelCatalog.appleSpeechID]
        ids += ModelCatalog.installedModelIDs()
            .filter { SpeechEngineFactory.engine(for: $0) != nil }
            .sorted()
        return ids
    }

    private static func measure(
        engine: any SpeechRecognitionEngine, extraClipMs: Int
    ) async -> Int {
        let format = await engine.preferredInputFormat()
        var failures = 0

        for sentence in sentences {
            do {
                let audio = try SpeechFixture.synthesize(sentence, float: true)
                defer { try? FileManager.default.removeItem(at: audio) }

                let samples = try readSamples(audio)
                let extraFrames = Int(Double(extraClipMs) / 1000 * samples.sampleRate)
                let speechEnd = max(0, lastSpeechIndex(samples.data) - extraFrames)
                let clippedMs =
                    Int(Double(samples.data.count - speechEnd) / samples.sampleRate * 1000)

                let padded = try await transcribe(
                    samples, upTo: samples.data.count, engine: engine, format: format)
                let clipped = try await transcribe(
                    samples, upTo: speechEnd, engine: engine, format: format)

                let expected = lastWord(sentence)
                let paddedKept = lastWord(padded) == expected
                let clippedKept = lastWord(clipped) == expected

                let mark = clippedKept ? "✓" : (paddedKept ? "✗" : "–")
                print("   \(mark) …\(expected)   (\(clippedMs) ms of silence removed)")
                if !clippedKept {
                    print("       padded:  \"\(padded)\"")
                    print("       clipped: \"\(clipped)\"")
                    // Only a word the padded arm heard and the clipped arm lost
                    // is this test's business. A word neither arm ever heard is
                    // synthesized speech being harsh, which --selftest covers.
                    if paddedKept {
                        print("       TRUNCATED: the final word survives only with trailing silence")
                        failures += 1
                    } else {
                        print("       (misrecognized in both arms, not truncation)")
                    }
                }
            } catch {
                print("   ✗ \(sentence) — \(error.localizedDescription)")
                failures += 1
            }
        }
        return failures
    }

    // MARK: - Audio

    private struct Samples {
        let data: [Float]
        let sampleRate: Double
        let format: AVAudioFormat
    }

    private static func readSamples(_ url: URL) throws -> Samples {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)
            )
        else { throw SpeechEngineError.audioFormatUnavailable }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw SpeechEngineError.audioFormatUnavailable
        }
        let data = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return Samples(data: data, sampleRate: format.sampleRate, format: format)
    }

    /// One past the last sample that is plainly speech rather than the noise
    /// floor. Relative to the peak, because `say` renders at whatever level it
    /// likes.
    private static func lastSpeechIndex(_ samples: [Float]) -> Int {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let threshold = max(peak * 0.02, 0.002)
        for index in stride(from: samples.count - 1, through: 0, by: -1)
        where abs(samples[index]) > threshold {
            return index + 1
        }
        return samples.count
    }

    /// Feeds `samples[0..<end]` in 100 ms buffers — the microphone tap's
    /// granularity — then finalizes immediately, with nothing appended after
    /// the last word and no pause before asking for the transcript.
    private static func transcribe(
        _ samples: Samples,
        upTo end: Int,
        engine: any SpeechRecognitionEngine,
        format: AVAudioFormat?
    ) async throws -> String {
        _ = try await engine.beginSession()

        let chunkFrames = Int(samples.sampleRate / 10)
        let converter: AVAudioConverter? =
            if let format, samples.format != format {
                AVAudioConverter(from: samples.format, to: format)
            } else {
                nil
            }

        var offset = 0
        while offset < end {
            let count = min(chunkFrames, end - offset)
            guard
                let chunk = AVAudioPCMBuffer(
                    pcmFormat: samples.format, frameCapacity: AVAudioFrameCount(count)
                ), let destination = chunk.floatChannelData?[0]
            else { break }
            samples.data.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress! + offset, count: count)
            }
            chunk.frameLength = AVAudioFrameCount(count)
            offset += count

            if let converter, let format {
                guard
                    let converted = AudioFormatConverter.convert(
                        chunk, using: converter, to: format)
                else { continue }
                engine.append(converted)
            } else {
                engine.append(chunk)
            }
        }

        return try await engine.finishSession()
    }

    // MARK: - Comparison

    private static func lastWord(_ text: String) -> String {
        let words = text.lowercased()
            .filter { !$0.isPunctuation }
            .split(separator: " ")
        return words.last.map(String.init) ?? ""
    }
}
