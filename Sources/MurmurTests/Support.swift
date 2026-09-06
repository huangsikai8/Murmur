import AVFoundation
import AppKit
import Foundation
import MurmurCore

/// Thread-safe capture boxes for the injected paste closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// Stands in for `AudioCapture`'s tap. It owns the buffer handler and nothing
/// else owns it back, which is the ownership the real audio path has: the tap
/// is installed on the input node and outlives the function that installed it.
final class TapHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func install(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    /// One buffer arriving from the microphone.
    func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(buffer)
    }

    /// What `AudioCapture.stop()` does: removes the tap, which is the only
    /// thing keeping anything captured in the handler alive.
    func remove() {
        lock.lock()
        handler = nil
        lock.unlock()
    }
}

/// A speech engine that records what it was handed, in order. Frame counts are
/// enough to tell replayed audio from dropped audio without comparing samples.
final class RecordingEngine: SpeechRecognitionEngine, @unchecked Sendable {
    static let engineName = "Recording"

    private let lock = NSLock()
    private var frames: [AVAudioFrameCount] = []

    var appendedFrames: [AVAudioFrameCount] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func preferredInputFormat() async -> AVAudioFormat? { nil }
    func prepare() async throws {}
    func beginSession() async throws -> AsyncStream<TranscriptUpdate> {
        AsyncStream { $0.finish() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        frames.append(buffer.frameLength)
        lock.unlock()
    }

    func finishSession() async throws -> String { "" }
    func cancelSession() async {}
    func releaseModels() async {}
}

/// A latch the injected paste watcher reads, so a test can decide when the
/// paste "lands".
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// One key press, as the shortcut recorder would receive it.
func keyPress(
    _ characters: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 2
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}
