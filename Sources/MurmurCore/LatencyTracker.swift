import Foundation
import os

/// Timing instrumentation for the dictation pipeline.
///
/// Marks are recorded in every build but only logged in debug builds, so
/// release runs carry no console cost.
public final class LatencyTracker: @unchecked Sendable {

    public enum Mark: String, CaseIterable, Sendable {
        case hotkeyDown = "hotkey down"
        case microphoneRunning = "microphone running"
        case recognizerReady = "recognizer ready"
        case firstPartial = "first partial transcript"
        case hotkeyUp = "hotkey up"
        case finalTranscript = "final transcript"
        case cleanupComplete = "cleanup complete"
        case inserted = "text inserted"
    }

    private static let log = Logger(subsystem: "com.sikaihuang.murmur", category: "latency")

    /// Where the breakdown is written in addition to the console.
    ///
    /// `print` goes nowhere when LaunchServices starts the app, and os_log at
    /// `.debug` is not persisted, so the timings existed but could not be read
    /// back from a real session. The app points this at its own log file.
    public nonisolated(unsafe) static var sink: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var marks: [(Mark, ContinuousClock.Instant)] = []
    private var origin: ContinuousClock.Instant?

    public init() {}

    public func begin() {
        lock.lock(); defer { lock.unlock() }
        marks.removeAll(keepingCapacity: true)
        origin = ContinuousClock.now
    }

    public func mark(_ mark: Mark) {
        lock.lock(); defer { lock.unlock() }
        guard origin != nil else { return }
        // Only the first occurrence matters (e.g. first partial, not every one).
        guard !marks.contains(where: { $0.0 == mark }) else { return }
        marks.append((mark, ContinuousClock.now))
    }

    /// Milliseconds from the start of the dictation to each mark.
    public func elapsedMilliseconds() -> [(String, Double)] {
        lock.lock(); defer { lock.unlock() }
        guard let origin else { return [] }
        return marks.map { mark, instant in
            (mark.rawValue, (instant - origin) / .milliseconds(1))
        }
    }

    /// Milliseconds between two marks, when both were recorded.
    public func interval(from start: Mark, to end: Mark) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let a = marks.first(where: { $0.0 == start })?.1,
              let b = marks.first(where: { $0.0 == end })?.1
        else { return nil }
        return (b - a) / .milliseconds(1)
    }

    /// Emits the timing breakdown.
    ///
    /// The console half is debug-only, but the sink is not: it is the only way
    /// these numbers survive a real session, since `print` goes nowhere under
    /// LaunchServices. Gating the sink too meant a release build recorded no
    /// push-to-talk timings at all — the exact gap this instrumentation exists
    /// to close.
    public func report() {
        let rows = elapsedMilliseconds()
        guard !rows.isEmpty else { return }
        var lines = ["[murmur] latency breakdown (ms from hotkey down)"]
        for (name, ms) in rows {
            lines.append(String(format: "  %-26s %8.1f", (name as NSString).utf8String!, ms))
        }
        if let capture = interval(from: .hotkeyDown, to: .microphoneRunning) {
            lines.append(String(format: "  -> hotkey to microphone:   %.1f ms", capture))
        }
        if let partial = interval(from: .microphoneRunning, to: .firstPartial) {
            lines.append(String(format: "  -> speech to first partial: %.1f ms", partial))
        }
        if let finalize = interval(from: .hotkeyUp, to: .finalTranscript) {
            lines.append(String(format: "  -> release to final:        %.1f ms", finalize))
        }
        if let cleanup = interval(from: .finalTranscript, to: .cleanupComplete) {
            lines.append(String(format: "  -> cleanup:                 %.1f ms", cleanup))
        }
        if let insert = interval(from: .cleanupComplete, to: .inserted)
            ?? interval(from: .finalTranscript, to: .inserted) {
            lines.append(String(format: "  -> insertion:               %.1f ms", insert))
        }
        let message = lines.joined(separator: "\n")
        Self.log.debug("\(message, privacy: .public)")
        #if DEBUG
        print(message)
        #endif
        Self.sink?(message)
    }
}
