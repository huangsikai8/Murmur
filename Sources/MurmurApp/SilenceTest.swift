import AVFoundation
import Foundation
import MurmurCore

/// `Murmur --testsilence [modelID]` — holds the key and says nothing.
///
/// The one case no other test covers, and the one that corrupts text rather
/// than merely losing it: an engine that answers a silent hold with words puts
/// a sentence nobody spoke into the document. Whisper does exactly this — it
/// was trained on captioned audio, where silence is followed by "Thank you."
/// and "Thanks for watching" — and WhisperKit cannot stop it, because the
/// `noSpeechProb` its `noSpeechThreshold` compares against is hardcoded to
/// zero with a TODO, so that gate never fires.
///
/// Room tone rather than digital zero, because zero is not what a microphone
/// records and an engine may special-case it. The levels are the ones
/// `AudioCapture` measures in a real room.
enum SilenceTest {

    /// Each case is what the microphone hands over when nobody is speaking.
    private static let cases: [(name: String, dBFS: Float, seconds: Double)] = [
        ("digital silence", -120, 2.0),
        ("quiet room", -55, 2.0),
        ("noisy room", -45, 2.0),
        ("a long silent hold", -50, 6.0),
    ]

    static func run(modelID: String = ModelCatalog.appleSpeechID) async -> Int32 {
        ModelCatalog.coreMLEngineWired = true
        ModelCatalog.moonshineEngineWired = true

        let descriptor = ModelCatalog.model(id: modelID)
        print("Murmur silent-hold test")
        print("Engine: \(descriptor?.name ?? modelID)")
        print("Holds the key with nobody speaking. Every result must be empty:")
        print("words here are words nobody said.\n")

        guard let engine = SpeechEngineFactory.engine(for: modelID) else {
            print("  FAILED: no engine implements \(modelID)")
            return 1
        }
        do {
            try await engine.prepare()
        } catch {
            print("  FAILED to prepare: \(error.localizedDescription)")
            return 1
        }

        let format =
            await engine.preferredInputFormat()
            ?? AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                interleaved: false)!

        var invented = 0
        for probe in cases {
            let text: String
            do {
                text = try await hold(
                    seconds: probe.seconds, dBFS: probe.dBFS, engine: engine, format: format)
            } catch {
                print("  ✗ \(probe.name): \(error.localizedDescription)")
                invented += 1
                continue
            }

            if text.isEmpty {
                print("  ✓ \(probe.name) (\(Int(probe.seconds))s at \(Int(probe.dBFS)) dBFS) → nothing")
            } else {
                print("  ✗ \(probe.name) (\(Int(probe.seconds))s at \(Int(probe.dBFS)) dBFS) → \"\(text)\"")
                invented += 1
            }
        }

        print("")
        if invented == 0 {
            print("Silence produced no text.")
            return 0
        }
        print("\(invented) of \(cases.count) silent holds produced words nobody spoke.")
        return 1
    }

    /// Feeds `seconds` of noise at `dBFS` through a whole session, in the same
    /// 100 ms chunks the microphone tap delivers.
    private static func hold(
        seconds: Double, dBFS: Float, engine: any SpeechRecognitionEngine, format: AVAudioFormat
    ) async throws -> String {
        _ = try await engine.beginSession()

        let amplitude = dBFS <= -100 ? 0 : pow(10, dBFS / 20)
        let chunkFrames = AVAudioFrameCount(format.sampleRate / 10)
        let chunks = Int(seconds * 10)
        // Deterministic, so a failure can be reproduced exactly.
        var seed: UInt64 = 0x5DEE_CE66

        for _ in 0..<chunks {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
                let channel = buffer.floatChannelData?[0]
            else { break }
            buffer.frameLength = chunkFrames
            for frame in 0..<Int(chunkFrames) {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let uniform = Float(seed >> 40) / Float(1 << 24) * 2 - 1
                channel[frame] = uniform * amplitude
            }
            engine.append(buffer)
            // Paced so an engine that decodes on a timer behaves as it would
            // live rather than being handed the whole hold at once.
            try? await Task.sleep(for: .milliseconds(10))
        }

        return try await engine.finishSession()
    }
}
