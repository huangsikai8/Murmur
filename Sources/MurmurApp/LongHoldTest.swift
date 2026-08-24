import AVFoundation
import Foundation
import MurmurCore

/// `Murmur --testlong [modelID]` — one hold longer than Whisper's window.
///
/// Every other speech test here says a sentence and releases. That never
/// reaches 30 seconds, which is exactly the length at which Whisper stops being
/// one decode and becomes a loop: WhisperKit walks a longer recording by
/// seeking to the last timestamp the decoder emitted, and asked to decode
/// without timestamps it has nothing to seek by and jumps a whole window
/// instead. Everything the decoder stopped short of inside that window is then
/// dropped, with no error and no gap — the transcript reads perfectly well
/// straight across the hole, which is why this survived so long.
///
/// The audio is sentences separated by silence rather than one unbroken
/// paragraph, because that is what dictation is and because a boundary landing
/// inside a pause is the case that fails. Each sentence carries a distinct
/// marker word: a missing marker is a sentence that was thrown away.
enum LongHoldTest {

    /// Roughly seven seconds of speech each at `say`'s default rate, so the
    /// eight of them plus their pauses run past 30 s and land a window boundary
    /// in the middle of the recording rather than at either end.
    private static let sentences: [(marker: String, text: String)] = [
        ("pineapple", "The first thing I want to record is that the pineapple was left on the counter overnight."),
        ("harbour", "Somebody should tell the office that the harbour road is closed again this morning."),
        ("artichoke", "Remind me to buy an artichoke and two lemons on the way home this evening."),
        ("barometer", "The barometer in the hallway has been reading far too low since the weekend."),
        ("telescope", "I promised to return the telescope before the end of the month, and I have not."),
        ("cardigan", "There is a green cardigan hanging by the back door that belongs to my neighbour."),
        ("almanac", "The almanac says the tide is at its highest a little after four in the afternoon."),
        ("elephant", "And the very last thing I have to say is that the elephant has finished speaking."),
    ]

    /// Silence between sentences, the length of an ordinary pause for thought.
    private static let pauseSeconds: Double = 2.5

    static func run(modelID: String?) async -> Int32 {
        ModelCatalog.coreMLEngineWired = true
        ModelCatalog.moonshineEngineWired = true

        let models = modelID.map { [$0] } ?? installedWhisperIDs()
        guard !models.isEmpty else {
            print("Murmur long-hold test\n\n  no Whisper variant is installed; nothing to test.")
            return 0
        }

        // The engine's own report of what it was handed, which is the line a
        // real session writes to Murmur.log. Shown here so the format is
        // exercised by a test rather than only by a dictation nobody can replay.
        WhisperEngine.diagnosticLog = { print("      [log] \($0)") }

        print("Murmur long-hold test")
        print("One hold of \(sentences.count) sentences with \(pauseSeconds) s pauses, past")
        print("Whisper's 30 s window. Every marker word must survive the decode.\n")

        let audio: Samples
        do {
            audio = try synthesizeHold()
        } catch {
            print("  FAILED to synthesize: \(error.localizedDescription)")
            return 1
        }
        let seconds = Double(audio.data.count) / audio.sampleRate
        guard seconds > 30 else {
            print(
                String(
                    format: "  FAILED: the fixture is only %.1f s and never crosses a window.",
                    seconds))
            return 1
        }
        print(String(format: "Fixture: %.1f s, crossing %d window boundary(s)\n", seconds, Int(seconds / 30)))

        var failures = 0
        for model in models {
            failures += await measure(modelID: model, audio: audio, seconds: seconds)
        }

        print("")
        if failures == 0 {
            print("Every sentence survived the hold.")
            return 0
        }
        print("\(failures) model(s) dropped speech across the window boundary.")
        return 1
    }

    private static func installedWhisperIDs() -> [String] {
        WhisperEngine.Variant.allCases
            .filter { WhisperEngine.isInstalled($0) }
            .map(\.modelID)
    }

    private static func measure(modelID: String, audio: Samples, seconds: Double) async -> Int {
        let name = ModelCatalog.model(id: modelID)?.name ?? modelID
        guard let engine = SpeechEngineFactory.engine(for: modelID) else {
            print("  ✗ \(name): no engine implements \(modelID)")
            return 1
        }
        defer { Task { await engine.releaseModels() } }

        let text: String
        let started = ContinuousClock.now
        do {
            try await engine.prepare()
            let format = await engine.preferredInputFormat()
            text = try await transcribe(audio, engine: engine, format: format)
        } catch {
            print("  ✗ \(name): \(error.localizedDescription)")
            return 1
        }
        let elapsed = SpeechFixture.milliseconds(since: started)

        let lower = text.lowercased()
        let missing = sentences.map(\.marker).filter { !lower.contains($0) }
        let words = text.split(whereSeparator: \.isWhitespace).count
        // A bracketed annotation reaching this point is text nobody spoke.
        let annotated = text != WhisperEngine.stripNonSpeechAnnotations(text)

        print("  \(missing.isEmpty && !annotated ? "✓" : "✗") \(name)")
        print(
            String(
                format: "      %d words in %d ms (%.2f words/s over a %.1f s hold)", words, elapsed,
                seconds > 0 ? Double(words) / seconds : 0, seconds))
        if missing.isEmpty {
            print("      all \(sentences.count) markers present")
        } else {
            print("      MISSING \(missing.count) of \(sentences.count): \(missing.joined(separator: ", "))")
        }
        if annotated {
            print("      a non-speech annotation reached the transcript")
        }
        print("      \(text)")
        return missing.isEmpty && !annotated ? 0 : 1
    }

    // MARK: - Fixture

    private struct Samples {
        var data: [Float]
        var sampleRate: Double
        var format: AVAudioFormat
    }

    /// Renders every sentence and joins them with silence, so the result is one
    /// recording of one hold rather than a sequence of separate utterances.
    private static func synthesizeHold() throws -> Samples {
        var joined: [Float] = []
        var format: AVAudioFormat?
        var rate: Double = 16000

        for sentence in sentences {
            let url = try SpeechFixture.synthesize(sentence.text, float: true)
            defer { try? FileManager.default.removeItem(at: url) }
            let samples = try readSamples(url)
            format = samples.format
            rate = samples.sampleRate
            joined.append(contentsOf: samples.data)
            joined.append(contentsOf: [Float](repeating: 0, count: Int(rate * pauseSeconds)))
        }
        guard let format else { throw SpeechEngineError.noSession }
        return Samples(data: joined, sampleRate: rate, format: format)
    }

    private static func readSamples(_ url: URL) throws -> Samples {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw SpeechEngineError.noSession }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw SpeechEngineError.noSession }
        return Samples(
            data: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
            sampleRate: format.sampleRate,
            format: format)
    }

    /// Feeds the hold in 100 ms buffers — the microphone tap's real cadence —
    /// converting into the engine's own format first, since an engine handed a
    /// format it did not ask for is not guaranteed to resample it.
    private static func transcribe(
        _ samples: Samples, engine: any SpeechRecognitionEngine, format: AVAudioFormat?
    ) async throws -> String {
        _ = try await engine.beginSession()

        let converter: AVAudioConverter? =
            if let format, samples.format != format {
                AVAudioConverter(from: samples.format, to: format)
            } else {
                nil
            }

        let chunkFrames = Int(samples.sampleRate / 10)
        var offset = 0
        while offset < samples.data.count {
            let count = min(chunkFrames, samples.data.count - offset)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: samples.format, frameCapacity: AVAudioFrameCount(count))
            else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.data.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
            }

            if let converter, let format {
                if let converted = AudioFormatConverter.convert(buffer, using: converter, to: format) {
                    engine.append(converted)
                }
            } else {
                engine.append(buffer)
            }
            offset += count
        }

        return try await engine.finishSession()
    }
}
