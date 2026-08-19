import AVFoundation
import Foundation
import MurmurCore

/// `Murmur --selftest` — drives the real recognizer end to end using speech
/// synthesized by `say`, so the pipeline can be verified without a microphone
/// and without a human reading sentences aloud.
enum SelfTest {

    /// Sentences chosen to exercise punctuation, contractions, and the words
    /// that other dictation apps corrupt.
    static let sentences = [
        "Hello, I'm testing this feature.",
        "Okay, it actually displays correctly.",
        "Yes, I think you've got the issue right.",
        "Can you move the meeting to Thursday afternoon?",
    ]

    static func run(modelID: String = ModelCatalog.appleSpeechID) async -> Int32 {
        ModelCatalog.coreMLEngineWired = true
        FluidAudioEngine.debugEnabled = true
        let descriptor = ModelCatalog.model(id: modelID)
        print("Murmur end-to-end self-test")
        print("Engine: \(descriptor?.name ?? modelID)\n")

        ModelCatalog.moonshineEngineWired = true
        // The same resolution the app uses, so a passing self-test says
        // something about the engine dictation will actually run.
        guard let engine = SpeechEngineFactory.engine(for: modelID) else {
            print("  FAILED: no engine implements \(modelID)")
            return 1
        }
        print("Preparing engine (first run may download the model)…")
        let prepareStart = ContinuousClock.now
        do {
            try await engine.prepare()
        } catch {
            print("  FAILED: \(error.localizedDescription)")
            return 1
        }
        print("  ready in \(milliseconds(since: prepareStart)) ms\n")

        // A nil preferred format means the engine resamples internally, so the
        // file's own format is passed straight through.
        let format = await engine.preferredInputFormat()

        // A misheard word is a property of synthesized speech, not a defect in
        // the pipeline. Only assembly corruption fails the run.
        var corruptions = 0
        var mismatches = 0
        for sentence in sentences {
            do {
                let result = try await transcribe(sentence, engine: engine, format: format)
                let matched = normalize(result.text) == normalize(sentence)
                print("  \(matched ? "✓" : "✗") \"\(sentence)\"")
                if !matched {
                    print("      got: \"\(result.text)\"")
                }
                print(
                    "      first partial \(result.firstPartialMs) ms, "
                        + "finalize \(result.finalizeMs) ms"
                )
                // Word-splitting corruption is a hard failure regardless of
                // whether the recognizer heard every word correctly.
                for corruption in ["act ually", "cor rectly", "beca use", " ."] {
                    if result.text.contains(corruption) {
                        print("      CORRUPTION: contains \"\(corruption)\"")
                        corruptions += 1
                    }
                }
                if !matched { mismatches += 1 }
            } catch {
                print("  ✗ \"\(sentence)\" — \(error.localizedDescription)")
                corruptions += 1
            }
        }

        print("")
        if corruptions > 0 {
            print("FAILED: \(corruptions) text-assembly corruption(s).\n")
            return 1
        }
        if mismatches > 0 {
            print("Passed with \(mismatches) misrecognized word(s), no corruption.")
            print("Synthesized speech is harsher than a real voice, so a wrong word")
            print("here is expected; corrupted spacing would not be.\n")
            return 0
        }
        print("All \(sentences.count) sentences transcribed exactly.\n")
        return 0
    }

    private struct Outcome {
        let text: String
        let firstPartialMs: Int
        let finalizeMs: Int
    }

    /// Renders `sentence` with `say`, then streams it through the engine in
    /// realistic buffer-sized chunks.
    private static func transcribe(
        _ sentence: String,
        engine: any SpeechRecognitionEngine,
        format: AVAudioFormat?
    ) async throws -> Outcome {
        let audioURL = try synthesize(sentence)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let file = try AVAudioFile(forReading: audioURL)
        let updates = try await engine.beginSession()

        let start = ContinuousClock.now
        let firstPartial = FirstMark()
        let collector = Task {
            for await update in updates where !update.text.isEmpty {
                firstPartial.recordIfUnset(milliseconds(since: start))
            }
        }

        // Feed in ~100 ms chunks, the same granularity as the microphone tap.
        let chunkFrames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        let converter: AVAudioConverter? =
            if let format, file.processingFormat != format {
                AVAudioConverter(from: file.processingFormat, to: format)
            } else {
                nil
            }

        while file.framePosition < file.length {
            guard
                let chunk = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: chunkFrames
                )
            else { break }
            try file.read(into: chunk, frameCount: chunkFrames)
            guard chunk.frameLength > 0 else { break }

            if let converter, let format {
                guard
                    let converted = AudioFormatConverter.convert(
                        chunk, using: converter, to: format
                    )
                else { continue }
                engine.append(converted)
            } else {
                engine.append(chunk)
            }
        }

        let releaseTime = ContinuousClock.now
        let text = try await engine.finishSession()
        collector.cancel()

        return Outcome(
            text: text,
            firstPartialMs: firstPartial.value ?? -1,
            finalizeMs: milliseconds(since: releaseTime)
        )
    }

    /// Renders text to a 16 kHz mono float WAV using the system speech synthesizer.
    private static func synthesize(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-selftest-\(UUID().uuidString).wav")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "--file-format=WAVE", "--data-format=LEI16@16000",
            "-o", url.path, text,
        ]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "Murmur.SelfTest", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "`say` failed to synthesize audio"]
            )
        }
        return url
    }

    /// Comparison that ignores casing and trailing punctuation differences the
    /// recognizer may legitimately choose differently.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .filter { !$0.isPunctuation && !$0.isWhitespace }
    }

    private static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        Int(Double((ContinuousClock.now - instant).components.attoseconds) / 1e15)
    }
}

/// Records only the first value it is given.
private final class FirstMark: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int?

    func recordIfUnset(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        if storage == nil { storage = value }
    }

    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
