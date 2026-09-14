import AVFoundation
import Foundation
import MurmurCore

/// `Murmur --recordclips [dir]` records read passages at the microphone's own
/// sample rate; `Murmur --testwhispertuning [dir] [modelID …]` replays them
/// through Whisper under each decoder setting in turn and scores every
/// transcript against the words that were read.
///
/// Two questions here no other test can answer. `say` never makes Whisper
/// distrust itself, so the retry settings change nothing on a synthesized
/// fixture. And every other recording path resamples to 16 kHz as it
/// captures, so the resampler's quality is already decided before a comparison
/// starts. Recording at the device's rate and resampling at replay lets both be
/// measured on one voice, as many times as needed.
enum WhisperTuningTest {

    /// Where recordings go unless told otherwise. Outside the repository on
    /// purpose: they are somebody's voice.
    static var defaultDirectory: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Murmur", directoryHint: .isDirectory)
            .appending(path: "TuningClips", directoryHint: .isDirectory)
            .path
    }

    /// Ordinary dictation, carrying the vocabulary terms. The last passage runs
    /// past 30 seconds, because an early stop at a window boundary is the
    /// failure the retry settings most plausibly touch. No figures: how a number
    /// is written is a formatting question, not a recognition one.
    static let passages: [String] = [
        "I just pushed the fix to the branch, so could you pull it down and check whether the build still passes on your machine before we merge it this afternoon?",
        "Open the project in VS Code, search for the function that handles the clipboard, and add a comment explaining why it waits for the paste to land before restoring anything.",
        "I asked Claude to review the pull request, and it pointed out that the error handling in the download code silently swallows a failure when the network drops halfway through.",
        "Thanks for sending the draft over. I read through the whole thing last night, and I think the second section needs a clearer summary, but otherwise it is in really good shape.",
        "Can we move the meeting to Thursday morning instead? I have a conflict on Wednesday, and I would rather not rush the discussion about priorities for the next quarter.",
        "Here is a longer note, so that this recording runs past half a minute. When I dictate into VS Code, the text usually lands correctly, but every so often a whole phrase goes missing near the end. I would like to understand whether that comes from the microphone, from the recognizer, or from the way the clipboard is restored afterwards. If Claude can help narrow it down, I will write up what we find and share it with the rest of the team, so that nobody has to rediscover the same problem later.",
    ]

    /// The smaller sibling build of Large v3 Turbo, benchmarked against the full
    /// one with `--quantized-turbo`. Not in the catalog.
    static let quantizedTurboFolder = "openai_whisper-large-v3-v20240930_626MB"

    // MARK: - Recording

    static func record(into directory: String) async -> Int32 {
        print("Murmur clip recorder\n")
        guard await AudioCapture.requestPermission() else {
            print("  FAILED: microphone access was denied.")
            return 1
        }
        let folder = URL(
            fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("  FAILED to create \(folder.path): \(error.localizedDescription)")
            return 1
        }

        print("Read each passage aloud at your normal pace and volume, from where you")
        print("usually sit. Press Return to start, and Return again when you finish.")
        print("Saving to \(folder.path)")

        let capture = AudioCapture()
        // No target format, so the tap delivers the device's own rate. The
        // resampling is one of the things being measured, so it happens at
        // replay rather than here.
        capture.prearm(targetFormat: nil)
        defer { capture.stop() }

        for (index, passage) in passages.enumerated() {
            let name = String(format: "clip-%02d", index + 1)
            print("\n[\(index + 1)/\(passages.count)]\n\n  \(passage)\n")
            print("  Press Return to start recording.")
            guard readLine() != nil else {
                print("  FAILED: this command needs an interactive terminal.")
                return 1
            }

            let sink = NativeSink()
            do {
                try capture.start { sink.append($0) }
            } catch {
                print("  FAILED to open the microphone: \(error.localizedDescription)")
                return 1
            }
            print("  RECORDING — press Return when you have finished.")
            _ = readLine()
            // The tap hands audio over in ~100 ms buffers, and the one holding
            // the last word has not filled yet when Return is pressed.
            try? await Task.sleep(for: .milliseconds(300))
            capture.idle()

            let take = sink.take()
            guard !take.samples.isEmpty else {
                print("  FAILED: no audio arrived from the microphone.")
                return 1
            }
            do {
                try write(
                    take.samples, sampleRate: take.sampleRate,
                    to: folder.appending(path: "\(name).wav"))
                try passage.write(
                    to: folder.appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
            } catch {
                print("  FAILED to save \(name): \(error.localizedDescription)")
                return 1
            }
            print(
                String(
                    format: "  saved %@.wav, %.1f s at %.0f Hz", name,
                    Double(take.samples.count) / take.sampleRate, take.sampleRate))
        }

        print("\nAll \(passages.count) passages recorded.")
        return 0
    }

    private static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw SpeechEngineError.audioFormatUnavailable }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        try file.write(from: buffer)
    }

    // MARK: - Audio

    /// The first channel of an audio file, at the file's own rate.
    static func readMono(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw SpeechEngineError.audioFormatUnavailable }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw SpeechEngineError.audioFormatUnavailable
        }
        return (
            Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
            format.sampleRate
        )
    }

    /// Converts to 16 kHz in 100 ms pieces through one converter, which is the
    /// shape of the microphone tap: it converts each buffer as it arrives.
    /// A `nil` quality leaves the converter at its default, which is what the
    /// app runs.
    static func resample(
        _ samples: [Float], from sampleRate: Double, quality: AVAudioQuality?
    ) -> [Float] {
        guard sampleRate != 16000 else { return samples }
        guard
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                interleaved: false),
            let target = ModelComparison.Recording.format,
            let converter = AVAudioConverter(from: source, to: target)
        else { return [] }
        if let quality { converter.sampleRateConverterQuality = quality.rawValue }

        let chunk = Int(sampleRate / 10)
        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) * 16000 / sampleRate) + chunk)
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: source, frameCapacity: AVAudioFrameCount(count))
            else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { all in
                buffer.floatChannelData![0].update(from: all.baseAddress! + offset, count: count)
            }
            if let converted = AudioFormatConverter.convert(buffer, using: converter, to: target),
                let channel = converted.floatChannelData?[0]
            {
                output.append(
                    contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            }
            offset += count
        }
        return output
    }

    // MARK: - Comparison

    private struct Clip {
        let name: String
        let reference: String
        let samples: [Float]
        let sampleRate: Double
        var seconds: Double { Double(samples.count) / sampleRate }
    }

    private struct Arm {
        let name: String
        let quality: AVAudioQuality
        let tuning: WhisperEngine.DecodeTuning
    }

    private struct Contender {
        let label: String
        let make: () -> WhisperEngine
    }

    private struct Tally {
        var referenceWords = 0
        var errors = 0
        var vocabularyExpected = 0
        var vocabularyFound = 0
        /// Holds whose decoder was actually handed the prompt.
        var prompted = 0
        var decodeMs: [Int] = []
        var cost = WhisperEngine.DecodeCost()
        var failures = 0
    }

    /// One change at a time against the app's current settings, then all of
    /// them together, so an effect can be attributed to what caused it.
    private static func arms(hasVocabulary: Bool) -> [Arm] {
        let shipped = WhisperEngine.DecodeTuning.shipped
        let candidate = WhisperEngine.DecodeTuning.candidate
        var noCutoff = shipped
        noCutoff.firstTokenCutoff = false
        var fewerRetries = shipped
        fewerRetries.retries = candidate.retries

        var arms = [Arm(name: "current settings", quality: .medium, tuning: shipped)]
        if hasVocabulary {
            var unprompted = shipped
            unprompted.vocabularyPrompt = .off
            arms.append(Arm(name: "no vocabulary prompt", quality: .medium, tuning: unprompted))
            var everywhere = shipped
            everywhere.vocabularyPrompt = .always
            arms.append(Arm(name: "prompt on every model", quality: .medium, tuning: everywhere))
        }
        arms += [
            Arm(name: "resampler at max quality", quality: .max, tuning: shipped),
            Arm(name: "first-token cut-off off", quality: .medium, tuning: noCutoff),
            Arm(
                name: "\(candidate.retries) retries, not \(shipped.retries)", quality: .medium,
                tuning: fewerRetries),
            Arm(name: "all of the above", quality: .max, tuning: candidate),
        ]
        return arms
    }

    static func run(
        directory: String, modelIDs: [String], quantizedTurbo: Bool, repeats: Int
    ) async -> Int32 {
        ModelCatalog.coreMLEngineWired = true
        print("Murmur Whisper tuning comparison\n")

        let folder = URL(
            fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        let clips: [Clip]
        do {
            clips = try loadClips(in: folder)
        } catch {
            print("  FAILED to read \(folder.path): \(error.localizedDescription)")
            return 1
        }
        guard !clips.isEmpty else {
            print("  No recordings in \(folder.path).")
            print("  Record them first with: Murmur --recordclips \"\(folder.path)\"")
            return 1
        }

        let phrases = VocabularyStore.shared.phrases
        let totalSeconds = clips.reduce(0) { $0 + $1.seconds }
        print(
            String(
                format: "%d clip(s), %.1f s of speech, recorded at %.0f Hz, %d run(s) each",
                clips.count, totalSeconds, clips[0].sampleRate, repeats))
        print("Vocabulary: \(phrases.isEmpty ? "none" : phrases.joined(separator: ", "))")
        print("Word error rate ignores case and punctuation. A retry is an attempt the")
        print("decoder rejected and decoded again at a higher temperature.\n")

        // What the resampler itself costs, since the app pays it on every buffer
        // the microphone delivers while armed, not only during dictation.
        print("Resampler cost, every clip to 16 kHz in 100 ms buffers (best of 3):")
        var resampled: [Int: [[Float]]] = [:]
        for (quality, label) in [(AVAudioQuality.medium, "medium"), (.max, "max")] {
            var best = Int.max
            for _ in 0..<3 {
                let start = ContinuousClock.now
                resampled[quality.rawValue] = clips.map {
                    resample($0.samples, from: $0.sampleRate, quality: quality)
                }
                best = min(best, Int((ContinuousClock.now - start) / .microseconds(1)))
            }
            print(
                String(
                    format: "  %@ (%d): %.1f ms for %.1f s of audio, %.3f%% of real time",
                    label, quality.rawValue, Double(best) / 1000, totalSeconds,
                    Double(best) / 1_000_000 / totalSeconds * 100))
        }

        let requested =
            modelIDs.isEmpty
            ? WhisperEngine.Variant.allCases.filter(WhisperEngine.isInstalled).map(\.modelID)
            : modelIDs
        var contenders: [Contender] = []
        for modelID in requested {
            guard let variant = WhisperEngine.Variant.from(modelID: modelID) else {
                print("  skipping \(modelID): not a Whisper model")
                continue
            }
            guard WhisperEngine.isInstalled(variant) else {
                print("  skipping \(modelID): not downloaded")
                continue
            }
            contenders.append(
                Contender(
                    label: ModelCatalog.model(id: modelID)?.name ?? modelID,
                    make: { WhisperEngine(variant: variant) }))
        }
        if quantizedTurbo {
            contenders.append(
                Contender(
                    label: "OpenAI Whisper Large v3 Turbo, 626 MB build",
                    make: {
                        WhisperEngine(variant: .largeV3Turbo, repositoryFolder: quantizedTurboFolder)
                    }))
        }
        guard !contenders.isEmpty else {
            print("  FAILED: no Whisper model to run.")
            return 1
        }

        let arms = arms(hasVocabulary: WhisperEngine.prompt(for: phrases) != nil)
        var details: [String] = []
        defer { WhisperEngine.tuning = .shipped }

        for contender in contenders {
            print("\n\(contender.label)")
            let engine = contender.make()
            let loadStart = ContinuousClock.now
            do {
                try await engine.prepare()
            } catch {
                print("  FAILED to load: \(error.localizedDescription)")
                continue
            }
            print("  loaded in \(SpeechFixture.milliseconds(since: loadStart)) ms")
            // As `DictationController` does for every engine.
            await engine.setContextualPhrases(phrases)

            // Not counted: the first decode after a load can include Core ML
            // specializing the model, which would be charged to whichever arm
            // happened to run first.
            WhisperEngine.tuning = .shipped
            _ = try? await transcribe(resampled[AVAudioQuality.medium.rawValue]![0], engine: engine)

            let header: [String] = [
                "  ", pad("setting", 28), pad("WER", 17), pad("vocab", 8), pad("prompted", 10),
                pad("retries", 9), pad("median", 10), pad("total", 10), pad("encoder", 11),
                pad("decoder", 11), "retrying",
            ]
            print(header.joined())
            for arm in arms {
                WhisperEngine.tuning = arm.tuning
                var tally = Tally()
                for run in 0..<repeats {
                    for (index, clip) in clips.enumerated() {
                        let audio = resampled[arm.quality.rawValue]![index]
                        let where_ =
                            "\(contender.label) · \(arm.name) · \(clip.name)"
                            + (repeats > 1 ? " · run \(run + 1)" : "")
                        do {
                            let started = ContinuousClock.now
                            let text = try await transcribe(audio, engine: engine)
                            tally.decodeMs.append(SpeechFixture.milliseconds(since: started))
                            if let cost = WhisperEngine.lastHoldCost {
                                tally.cost.add(cost)
                                if cost.promptTokens > 0 { tally.prompted += 1 }
                            }

                            let score = WordErrorRate.measure(reference: clip.reference, hypothesis: text)
                            tally.referenceWords += score.referenceWords
                            tally.errors += score.errors
                            for phrase in phrases {
                                let expected = WordErrorRate.occurrences(of: phrase, in: clip.reference)
                                tally.vocabularyExpected += expected
                                tally.vocabularyFound += min(
                                    expected, WordErrorRate.occurrences(of: phrase, in: text))
                            }
                            if score.errors > 0 {
                                details.append(
                                    "  \(where_) — \(score.errors) error(s)\n      \(score.marked)")
                            }
                        } catch {
                            tally.failures += 1
                            details.append("  \(where_) — FAILED: \(error.localizedDescription)")
                        }
                    }
                }
                print(row(arm.name, tally))
            }
            WhisperEngine.tuning = .shipped
            await engine.releaseModels()
        }

        if !details.isEmpty {
            print("\nEvery transcript with an error, marked ⟨expected→heard⟩, ⟨+extra⟩, ⟨−missing⟩:")
            for line in details { print(line) }
        }
        return 0
    }

    private static func loadClips(in folder: URL) throws -> [Clip] {
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".wav") }
            .sorted()
        return try files.compactMap { file in
            let stem = String(file.dropLast(4))
            // A recording with no reference cannot be scored, so it is not a clip.
            guard
                let reference = try? String(
                    contentsOf: folder.appending(path: "\(stem).txt"), encoding: .utf8)
            else { return nil }
            let audio = try readMono(folder.appending(path: file))
            return Clip(
                name: stem, reference: reference, samples: audio.samples,
                sampleRate: audio.sampleRate)
        }
    }

    /// One whole hold, fed in the tap's 100 ms buffers without pacing: Whisper
    /// decodes on release, so arrival speed changes nothing but the wait.
    private static func transcribe(_ samples: [Float], engine: WhisperEngine) async throws -> String {
        _ = try await engine.beginSession()
        guard let format = ModelComparison.Recording.format else {
            throw SpeechEngineError.audioFormatUnavailable
        }
        var offset = 0
        while offset < samples.count {
            let count = min(1600, samples.count - offset)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
            else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { all in
                buffer.floatChannelData![0].update(from: all.baseAddress! + offset, count: count)
            }
            engine.append(buffer)
            offset += count
        }
        return try await engine.finishSession()
    }

    private static func row(_ name: String, _ tally: Tally) -> String {
        let rate =
            tally.referenceWords > 0
            ? Double(tally.errors) / Double(tally.referenceWords) * 100 : 0
        let sorted = tally.decodeMs.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let ms = { (seconds: Double) in "\(Int((seconds * 1000).rounded())) ms" }
        // Built as a list: one long `+` chain of these is more than the type
        // checker will resolve in reasonable time.
        let columns: [String] = [
            "  ",
            pad(name, 28),
            pad(String(format: "%.1f%% (%d/%d)", rate, tally.errors, tally.referenceWords), 17),
            pad("\(tally.vocabularyFound)/\(tally.vocabularyExpected)", 8),
            pad("\(tally.prompted)/\(tally.decodeMs.count)", 10),
            pad("\(tally.cost.retries)", 9),
            pad("\(median) ms", 10),
            pad("\(sorted.reduce(0, +)) ms", 10),
            pad(ms(tally.cost.encoderSeconds), 11),
            pad(ms(tally.cost.decoderSeconds), 11),
            ms(tally.cost.retrySeconds),
            tally.failures > 0 ? "  \(tally.failures) FAILED" : "",
        ]
        return columns.joined()
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}

/// Accumulates microphone buffers at the device's own format. They arrive on
/// the audio thread.
private final class NativeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        lock.lock()
        sampleRate = buffer.format.sampleRate
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        lock.unlock()
    }

    func take() -> (samples: [Float], sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, sampleRate)
    }
}
