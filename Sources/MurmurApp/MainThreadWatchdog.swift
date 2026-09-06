import Foundation

/// Watches whether the main thread is still answering, and releases the keyboard
/// when it is not.
///
/// Two jobs, and the second is the one that matters to somebody using the
/// machine. A menu bar accessory whose main thread stalls is an annoyance; a menu
/// bar accessory holding an active event tap on that same main thread is a
/// keyboard that has stopped working in every application — see
/// `KeyboardTapGate`. The watchdog runs on its own thread precisely because the
/// main thread is the thing being measured, so it is still running when the
/// answer is "no".
///
/// Nothing here is main-actor isolated and nothing here awaits. An actor hop is
/// a request to run on the thread that has already failed to answer.
final class MainThreadWatchdog: @unchecked Sendable {

    /// How often the main thread is asked whether it is still there.
    private let interval: TimeInterval = 0.1

    /// How long it may go without answering before the keyboard is released.
    ///
    /// Deliberately short, and much shorter than `reportThreshold`. Suspending
    /// the tap costs a Return that is not swallowed; not suspending it costs
    /// every keystroke on the machine. There is no reason to be patient about
    /// which of those to risk, and a stall this brief is invisible if it turns
    /// out to be nothing.
    private let releaseThreshold: TimeInterval = 0.3

    /// How long it may go without answering before that is written down.
    ///
    /// Longer than `releaseThreshold`, because this one is judged by a person
    /// reading a log rather than by a keyboard: a model load takes seconds and is
    /// worth a line, while routine main-actor work that runs a little long is
    /// noise that would bury it.
    private let reportThreshold: TimeInterval = 1.0

    private let queue = DispatchQueue(
        label: "com.sikaihuang.murmur.watchdog", qos: .userInitiated)

    private let lock = NSLock()
    private var lastReply = Date()
    private var probeInFlight = false
    private var running = false

    /// Whether the current stall has already been logged, so one stall produces
    /// one pair of lines rather than one pair every `interval`.
    private var reported = false

    /// Whether this watchdog is the reason the keyboard is open, so it only ever
    /// resumes a tap it suspended itself.
    private var released = false

    static let shared = MainThreadWatchdog()

    private init() {}

    func start() {
        lock.lock()
        guard !running else { return lock.unlock() }
        running = true
        lastReply = Date()
        lock.unlock()
        Log.write("main-thread watchdog started")
        schedule()
    }

    private func schedule() {
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            self.tick()
            self.lock.lock()
            let keepGoing = self.running
            self.lock.unlock()
            if keepGoing { self.schedule() }
        }
    }

    private func tick() {
        let now = Date()

        lock.lock()
        let waiting = probeInFlight
        let stalled = now.timeIntervalSince(lastReply)
        if !waiting { probeInFlight = true }
        lock.unlock()

        // Only one probe is ever outstanding. A second would not measure
        // anything the first has not already established, and both would be
        // queued behind the same blockage.
        if !waiting {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.probeInFlight = false
                self.lastReply = Date()
                let wasReported = self.reported
                let wasReleased = self.released
                self.reported = false
                self.released = false
                self.lock.unlock()

                // Logged from the main thread, which is the moment it started
                // answering again — the duration is therefore the real one and
                // not a watchdog tick's worth of rounding.
                if wasReported || wasReleased {
                    if wasReleased { KeyboardTapGate.shared.resume() }
                    Log.write(
                        "main thread answering again"
                            + (wasReleased ? "; keyboard tap re-enabled" : ""))
                }
            }
        }

        if stalled >= releaseThreshold {
            lock.lock()
            let alreadyReleased = released
            if !alreadyReleased { released = true }
            lock.unlock()
            // Suspending is the whole point of the watchdog, and it happens on
            // this thread rather than being scheduled onto the one that is
            // stuck.
            if !alreadyReleased, KeyboardTapGate.shared.suspend() {
                Log.write(
                    String(
                        format:
                            "main thread unresponsive for %.0f ms; keyboard tap suspended so keys "
                            + "reach other applications", stalled * 1000))
            }
        }

        if stalled >= reportThreshold {
            lock.lock()
            let alreadyReported = reported
            if !alreadyReported { reported = true }
            lock.unlock()
            if !alreadyReported {
                // The previous line in this file is the last thing the app got
                // to record, which is as close as anything here gets to naming
                // what the main thread is stuck on.
                Log.write(
                    String(
                        format: "main thread stalled past %.1f s — see the line above for what it "
                            + "was last doing", stalled))
            }
        }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }
}
