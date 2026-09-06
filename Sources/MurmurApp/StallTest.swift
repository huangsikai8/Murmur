import CoreGraphics
import Foundation

/// `Murmur --teststall` — does a stalled main thread still take the keyboard
/// down with it?
///
/// This is the test for the failure that has no other evidence. A hang writes no
/// log line of its own, leaves no crash report, and the only thing anybody can
/// say about it afterwards is that the machine stopped typing — measured once on
/// a real session, with the menu bar unresponsive and Spotlight the only thing
/// still accepting keys.
///
/// So the stall is manufactured rather than waited for, the same way
/// `WhisperEngine.forcedSampleLength` manufactures an early decoder stop. The
/// main thread is blocked outright for a fixed span while a real event tap is
/// installed, and the two things that have to be true are asserted:
///
///   * the watchdog suspends the tap **while** the main thread is still stuck,
///     which is the whole point — a rescue that arrives after the thread frees
///     itself rescues nothing;
///   * it resumes the tap once the thread answers, or the fix trades a frozen
///     keyboard for a Return key that stays broken until the next relaunch.
///
/// `Thread.sleep` on the main thread is exactly the right instrument here. It is
/// what a synchronous model load or a paging storm looks like from the outside,
/// and it is the one thing no amount of `await` discipline in the app can be
/// trusted to have ruled out.
enum StallTest {

    static func run(stallSeconds: Double = 2.0) -> Int32 {
        var failures = 0

        print("Main-thread stall — does the keyboard survive it?")
        print(String(repeating: "─", count: 60))

        // A real tap, created the same way `FinalizeKeyMonitor` creates one.
        // Nothing here is swallowed: the callback passes every event straight
        // through, so running this test cannot eat a keystroke.
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                userInfo: nil
            )
        else {
            print("  event tap not created — grant Accessibility and run again")
            return 1
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        KeyboardTapGate.shared.adopt(tap)
        defer {
            KeyboardTapGate.shared.adopt(nil)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
        }

        MainThreadWatchdog.shared.start()
        // Let the watchdog take a clean reading before the thread goes away.
        Thread.sleep(forTimeInterval: 0.3)

        guard !KeyboardTapGate.shared.isSuspended else {
            print("  FAIL  the tap was suspended before the main thread stalled")
            return 1
        }
        print("  before the stall: tap enabled, main thread answering")

        // Sampled from another thread, because the thread being measured is
        // about to stop running anything at all.
        let observed = Observation()
        let watcher = Thread {
            let deadline = Date().addingTimeInterval(stallSeconds)
            while Date() < deadline {
                if KeyboardTapGate.shared.isSuspended { observed.markSuspended() }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        watcher.start()

        let began = Date()
        Thread.sleep(forTimeInterval: stallSeconds)
        let blocked = Date().timeIntervalSince(began)
        print(String(format: "  main thread blocked for %.2f s", blocked))

        if let at = observed.suspendedAfter(began) {
            print(String(format: "  PASS  keyboard released %.0f ms into the stall", at * 1000))
        } else {
            failures += 1
            print("  FAIL  the tap was never suspended — a stall still freezes the keyboard")
        }

        // The main run loop has to turn for the watchdog's probe to be answered,
        // which is precisely what says the thread is alive again.
        let resumeDeadline = Date().addingTimeInterval(3)
        while KeyboardTapGate.shared.isSuspended, Date() < resumeDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if KeyboardTapGate.shared.isSuspended {
            failures += 1
            print("  FAIL  the tap was never resumed — Return stays broken after a stall")
        } else {
            print("  PASS  keyboard tap resumed once the main thread answered")
        }

        print(String(repeating: "─", count: 60))
        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    /// What the sampling thread saw, since the main thread cannot record it.
    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Date?

        func markSuspended() {
            lock.lock()
            defer { lock.unlock() }
            if first == nil { first = Date() }
        }

        func suspendedAfter(_ start: Date) -> TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            return first.map { $0.timeIntervalSince(start) }
        }
    }
}
