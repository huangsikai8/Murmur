import AVFoundation
import Foundation

/// Holds microphone buffers until the recognizer is ready for them.
///
/// The microphone opens *first*, into this. Awaiting `beginSession()` before
/// starting capture serializes two costs that have no reason to be serial, and
/// throws away the first 70-122 ms of every utterance — measured, from real
/// sessions. Holding a key hid it, because the hold outlasted the gap. A latch
/// does not: you tap and speak immediately, and the first word is simply never
/// recorded.
///
/// Order matters: buffers must reach an engine in the sequence they were
/// captured, so both the replay and the hand-off happen under one lock rather
/// than by spawning a task per buffer.
///
/// **The audio tap must hold this strongly.** Nothing else owns it once the
/// session is running, so a weak capture deallocates it at the end of
/// `attach(_:)` and every buffer from that moment on is dropped. That failure
/// is silent in every place anyone looks: the level meter is computed upstream
/// in `AudioCapture` so the overlay still moves, the recognizer still starts
/// cleanly, and the only symptom is an empty transcript.
public final class StartupAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var engine: (any SpeechRecognitionEngine)?

    public init() {}

    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let engine {
            engine.append(buffer)
        } else {
            pending.append(buffer)
        }
    }

    /// Replays what was captured while the recognizer was loading, in order,
    /// then hands the tap straight through.
    public func attach(_ engine: any SpeechRecognitionEngine) {
        lock.lock()
        defer { lock.unlock() }
        for buffer in pending { engine.append(buffer) }
        pending.removeAll(keepingCapacity: false)
        self.engine = engine
    }
}
