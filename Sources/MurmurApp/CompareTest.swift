import AVFoundation
import Foundation
import MurmurCore

/// `Murmur --testcompare` — speak once, see what every installed model made of
/// it, side by side.
///
/// The published measurements compare models on speech from `say`, which is
/// harsher and flatter than a real voice. This is the same idea driven by your
/// own microphone, which is the only way to find out which model is best for a
/// particular person in a particular room.
enum CompareTest {

    struct Options: Sendable {
        /// Seconds to record from the microphone.
        var seconds: Double = 6
        /// Synthesize this sentence with `say` instead of opening the
        /// microphone. Makes a run repeatable, and lets the command be
        /// verified where no one can speak into a mic.
        var sentence: String?
        /// Run every bubble's transcript through this cleanup model too.
        var cleanupModelID: String?
        var cleanupLevel: CleanupLevel = .light
    }

    static func run(options: Options) async -> Int32 {
        ModelCatalog.coreMLEngineWired = true
        ModelCatalog.mlxSupported = true
        ModelCatalog.moonshineEngineWired = true

        print("Murmur multi-model comparison\n")

        let bubbles = defaultBubbles(cleanup: options.cleanupModelID, level: options.cleanupLevel)
        guard !bubbles.isEmpty else {
            print("  FAILED: no speech models are usable on this machine.")
            return 1
        }
        print("Comparing \(bubbles.count) configuration(s):")
        for bubble in bubbles { print("  • \(bubble.label)") }
        print("")

        let recording: ModelComparison.Recording
        do {
            recording =
                if let sentence = options.sentence {
                    try synthesized(sentence)
                } else {
                    try await recorded(seconds: options.seconds)
                }
        } catch {
            print("  FAILED to capture audio: \(error.localizedDescription)")
            return 1
        }

        guard !recording.isEmpty else {
            print("  FAILED: captured no audio.")
            return 1
        }
        print("Captured \(String(format: "%.1f", recording.duration)) s\n")

        // Speech models decode first, then cleanup models, so results arrive
        // out of bubble order and have to be collected before printing.
        var transcripts: [UUID: String] = [:]
        var cleaned: [UUID: String] = [:]
        var timings: [UUID: String] = [:]
        var failures: [UUID: String] = [:]

        for await event in ModelComparison.run(recording, bubbles: bubbles) {
            switch event {
            case .loading(let modelID):
                let name = ModelCatalog.model(id: modelID)?.name ?? modelID
                print("  loading \(name)…")

            case .transcribed(let bubble, let text, let firstPartialMs, let decodeMs):
                transcripts[bubble] = text
                let partial =
                    firstPartialMs < 0
                    ? "no partials (decodes on release)"
                    : "first partial \(firstPartialMs) ms"
                timings[bubble] = "\(partial), finalize \(decodeMs) ms"

            case .cleaned(let bubble, let text, let elapsedMs):
                cleaned[bubble] = text
                timings[bubble, default: ""] += ", cleanup \(elapsedMs) ms"

            case .failed(let bubble, let message):
                failures[bubble] = message
            }
        }

        return report(
            bubbles: bubbles, transcripts: transcripts, cleaned: cleaned,
            timings: timings, failures: failures)
    }

    // MARK: - Reporting

    private static func report(
        bubbles: [ModelComparison.BubbleConfig],
        transcripts: [UUID: String],
        cleaned: [UUID: String],
        timings: [UUID: String],
        failures: [UUID: String]
    ) -> Int32 {
        print("")

        // The text a bubble shows is its cleaned output when it has one, since
        // that is what would have been inserted.
        var entries: [TranscriptDiff.Entry] = []
        for bubble in bubbles {
            guard let text = cleaned[bubble.id] ?? transcripts[bubble.id] else { continue }
            entries.append(TranscriptDiff.Entry(label: bubble.label, text: text))
        }

        guard !entries.isEmpty else {
            print("Every configuration failed:")
            for bubble in bubbles {
                print("  ✗ \(bubble.label) — \(failures[bubble.id] ?? "unknown error")")
            }
            return 1
        }

        let comparison = TranscriptDiff.compare(entries)
        let width = entries.map(\.label.count).max() ?? 0

        for bubble in bubbles {
            let label = bubble.label
            guard let row = comparison.rows.first(where: { $0.label == label }) else {
                print("  ✗ \(label.padding(toLength: width, withPad: " ", startingAt: 0))  "
                    + "\(failures[bubble.id] ?? "no result")")
                continue
            }
            let padded = label.padding(toLength: width, withPad: " ", startingAt: 0)
            // Contested words are bracketed rather than coloured so the output
            // survives being piped into a file or pasted into a note.
            let rendered = row.tokens.map { $0.agrees ? $0.text : "⟨\($0.text)⟩" }
                .joined(separator: " ")
            print("  \(padded)  \(rendered)")
            if let timing = timings[bubble.id] { print("  \(String(repeating: " ", count: width))  \(timing)") }
        }

        print("")
        if comparison.unanimous {
            print("All \(entries.count) configurations agreed word for word.")
            print("Any of them would have inserted the same text.\n")
        } else {
            print("\(comparison.disagreements) contested word(s), shown in ⟨⟩.")
            print("There is no ground truth here — read the contested words and")
            print("decide which model heard you correctly.\n")
        }
        return 0
    }

    // MARK: - Bubbles

    /// Every speech model that could actually run here, paired with an optional
    /// cleanup model. A model that is not downloaded is skipped rather than
    /// reported as broken.
    private static func defaultBubbles(
        cleanup: String?, level: CleanupLevel
    ) -> [ModelComparison.BubbleConfig] {
        let installed = ModelCatalog.installedModelIDs()
        return ModelCatalog.models(in: .speechRecognition)
            .filter { $0.id == ModelCatalog.appleSpeechID || installed.contains($0.id) }
            .map {
                ModelComparison.BubbleConfig(
                    speechModelID: $0.id,
                    cleanupModelID: cleanup,
                    cleanupLevel: cleanup == nil ? .off : level)
            }
    }

    // MARK: - Capture

    /// Opens the microphone for a fixed window, counting down so the speaker
    /// knows when to start.
    private static func recorded(seconds: Double) async throws -> ModelComparison.Recording {
        guard await AudioCapture.requestPermission() else {
            throw SpeechEngineError.unavailable("Microphone access was denied.")
        }

        let capture = AudioCapture()
        let buffer = ModelComparison.RecordingBuffer()
        // The neutral format: what the detector uses, and what every engine
        // either wants directly or resamples from. Per-engine conversion
        // happens at replay time, not here.
        capture.prearm(targetFormat: ModelComparison.Recording.format)

        for countdown in [3, 2, 1] {
            print("  starting in \(countdown)…")
            try await Task.sleep(for: .seconds(1))
        }

        try capture.start { buffer.append($0) }
        print("  RECORDING — speak now (\(Int(seconds)) s)")
        for remaining in stride(from: Int(seconds), to: 0, by: -1) {
            try await Task.sleep(for: .seconds(1))
            print("  \(remaining - 1) s")
        }
        capture.stop()

        return buffer.recording()
    }

    /// Renders a sentence with `say` and reads it back as samples.
    private static func synthesized(_ sentence: String) throws -> ModelComparison.Recording {
        print("  synthesizing \"\(sentence)\"")
        let url = try SpeechFixture.synthesize(sentence, float: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else {
            throw SpeechEngineError.audioFormatUnavailable
        }
        try file.read(into: buffer)

        guard let channel = buffer.floatChannelData?[0] else {
            throw SpeechEngineError.audioFormatUnavailable
        }
        return ModelComparison.Recording(
            samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }
}
