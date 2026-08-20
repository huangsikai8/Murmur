import AVFoundation
import Foundation
import MurmurCore

/// `Murmur --testturn [seconds]` — records real speech and reports, at every
/// pause, whether the turn detector would have committed or waited.
///
/// This one cannot use `say`. The model reads prosody rather than words, and
/// synthesized speech ends every utterance on the same clean falling contour
/// no matter what the text says — measured here, all six synthesized fixtures
/// came back COMPLETE, including "the meeting is on". Cutting a real sentence
/// mid-word reads 0.01–0.15, so the model works; it is the *fixture* that
/// cannot express trailing off. Only a real voice can answer whether this is
/// worth shipping.
enum TurnTest {

    /// Short on purpose. The whole point is that the silence threshold no
    /// longer has to carry the decision, so this is the value it could drop to.
    private static let silenceDuration: TimeInterval = 0.25

    static func run(seconds: Double, file: String? = nil) async -> Int32 {
        print("Murmur turn-detector test")
        print("smart-turn v3.2, 8 MB, judging the waveform rather than the words\n")

        let detector = TurnDetector()
        let loadStart = ContinuousClock.now
        do {
            try await detector.prepare()
        } catch {
            print("  FAILED to load turn detector: \(error)")
            return 1
        }
        print("Turn detector ready in \(SpeechFixture.milliseconds(since: loadStart)) ms")

        let vad = VoiceActivityDetector(
            tuning: VoiceActivityDetector.Tuning(silenceDuration: silenceDuration))
        do {
            try await vad.prepare()
        } catch {
            print("  FAILED to load VAD: \(error.localizedDescription)")
            return 1
        }
        print("VAD ready, silence threshold \(Int(silenceDuration * 1000)) ms\n")

        let samples: [Float]
        do {
            if let file {
                samples = try load(path: file)
                print("Replaying \((file as NSString).lastPathComponent)")
            } else {
                samples = try await record(seconds: seconds)
            }
        } catch {
            print("  FAILED to read audio: \(error.localizedDescription)")
            return 1
        }
        guard !samples.isEmpty else {
            print("  no audio captured")
            return 1
        }
        print("Captured \(String(format: "%.1f", Double(samples.count) / 16000)) s")

        // A silent run must not read as a result. Without this a recording that
        // never reached the microphone looks identical to one with no pauses in
        // it — same output, different meaning entirely.
        let peak = samples.map(abs).max() ?? 0
        let rms = (samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot()
        print(String(format: "Level: peak %.3f, rms %.4f", peak, rms))
        if peak < 0.01 {
            print("\n  Nothing audible was captured — peak is at the noise floor.")
            print("  Check the input device, or that Murmur has microphone access.")
            return 1
        }

        // Replay through the detector, asking the model at every pause.
        var pauses: [(time: Double, decision: TurnDetector.Decision)] = []
        var offset = 0
        var starts = 0
        let slice = 1600  // 100 ms, the granularity a microphone tap delivers
        while offset < samples.count {
            let end = min(offset + slice, samples.count)
            guard let events = try? await vad.process(Array(samples[offset..<end])) else { break }
            offset = end
            for event in events where event == .speechStarted { starts += 1 }
            for event in events where event == .speechEnded {
                let time = Double(offset) / 16000
                let window = Array(samples[0..<offset])
                if let decision = await detector.evaluate(window) {
                    pauses.append((time, decision))
                }
            }
        }

        print("Speech segments found by the VAD: \(starts)\n")
        guard !pauses.isEmpty else {
            print("No pauses found — try speaking with a pause or two, for longer.")
            return 1
        }

        print("Pauses, and what the detector would do at each:\n")
        print("    time   probability  verdict     action")
        var held = 0
        var cost = Duration.zero
        for pause in pauses {
            let complete = pause.decision.isComplete
            if !complete { held += 1 }
            cost += pause.decision.elapsed
            let verdict = complete ? "COMPLETE  " : "INCOMPLETE"
            let action = complete ? "insert here" : "keep listening"
            print(
                String(format: "  %6.2fs      %.3f     ", pause.time, pause.decision.probability)
                    + "\(verdict)  \(action)")
        }

        let average = cost / pauses.count
        print("\n\(pauses.count) pauses: \(pauses.count - held) would insert, \(held) would wait.")
        print("Detector cost \(average) per decision.\n")
        print("What to look for: every pause where you were still thinking should")
        print("say INCOMPLETE, and every finished sentence should say COMPLETE.")
        print("Wrong holds cost latency; wrong inserts are the interruption you")
        print("get today at every pause.")
        return 0
    }


    /// Reads a file and converts it to the 16 kHz mono both models want, so a
    /// recording can be replayed instead of spoken. Repeatable, unlike a
    /// microphone — but only worth anything on a *real* voice.
    private static func load(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                interleaved: false),
            let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length))
        else { throw NSError(domain: "Murmur", code: 2) }
        try file.read(into: input)

        if file.processingFormat == target {
            guard let channel = input.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: Int(input.frameLength)))
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
            let converted = AudioFormatConverter.convert(input, using: converter, to: target),
            let channel = converted.floatChannelData?[0]
        else { throw NSError(domain: "Murmur", code: 3) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    /// Records from the microphone at the 16 kHz the model and VAD both want.
    private static func record(seconds: Double) async throws -> [Float] {
        guard await AudioCapture.requestPermission() else {
            throw NSError(
                domain: "Murmur", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "microphone permission denied"])
        }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)

        let capture = AudioCapture()
        capture.prearm(targetFormat: format)

        print("Recording \(Int(seconds)) s. Speak naturally — say a sentence, pause")
        print("mid-thought as if choosing a word, then finish it.")
        for countdown in [3, 2, 1] {
            print("  starting in \(countdown)…")
            try? await Task.sleep(for: .seconds(1))
        }

        let sink = SampleSink()
        try capture.start { buffer in
            guard let channel = buffer.floatChannelData?[0] else { return }
            sink.append(
                Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        }
        print("  ● recording\n")
        try? await Task.sleep(for: .seconds(seconds))
        capture.stop()
        return sink.drain()
    }

    /// The tap runs on its own thread, so accumulation is locked.
    private final class SampleSink: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []

        func append(_ new: [Float]) {
            lock.lock()
            samples.append(contentsOf: new)
            lock.unlock()
        }

        func drain() -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }
    }
}
