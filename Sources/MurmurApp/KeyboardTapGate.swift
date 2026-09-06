import CoreGraphics
import Foundation

/// The installed keyboard tap, reachable from any thread.
///
/// `FinalizeKeyMonitor` installs an **active** event tap on the main run loop,
/// which means every key press on the machine is routed through this process's
/// main thread and held there until the callback returns. That is fine while the
/// main thread is answering and catastrophic when it is not: a stalled main
/// thread is not a frozen menu bar icon, it is a keyboard that has stopped
/// working in every application at once. Measured on a real machine, with the
/// menu bar unresponsive and only Spotlight — which is serviced outside the
/// session tap's path — still accepting keys.
///
/// The obvious repair is for the tap to notice the stall and stop consuming, and
/// it cannot: that code would run in the callback, on the thread that is stuck,
/// so it never executes. The rescue has to come from somewhere else, and
/// `CGEvent.tapEnable` is safe to call from any thread. This is the handle a
/// watchdog on another thread uses to let the keyboard go.
///
/// Everything here is lock-protected rather than main-actor isolated for exactly
/// that reason — an actor hop is a request to run on the thread that has already
/// failed to answer.
final class KeyboardTapGate: @unchecked Sendable {

    static let shared = KeyboardTapGate()

    private let lock = NSLock()
    private var port: CFMachPort?
    private var suspended = false

    private init() {}

    /// Takes ownership of the tap the monitor just installed, or `nil` when it
    /// is torn down. A new tap always starts un-suspended.
    func adopt(_ port: CFMachPort?) {
        lock.lock()
        defer { lock.unlock() }
        self.port = port
        suspended = false
    }

    /// Whether the keyboard is currently being held open for a stall.
    ///
    /// Read by the tap callback, which must not re-enable a tap the watchdog
    /// deliberately switched off — the system disabling a slow tap and the
    /// watchdog releasing a stuck one look identical from inside the callback,
    /// and only one of them is safe to undo there.
    var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suspended
    }

    /// Stops consuming keystrokes. Returns whether this call is what changed it.
    ///
    /// The cost is that Return is not swallowed while suspended, so a Return
    /// pressed during a stall may submit whatever is in the field early. That is
    /// the whole trade, and it is not close: one mistimed Return against a
    /// keyboard that does not work in any application.
    @discardableResult
    func suspend() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let port, !suspended else { return false }
        CGEvent.tapEnable(tap: port, enable: false)
        suspended = true
        return true
    }

    /// Resumes consuming keystrokes once the main thread is answering again.
    @discardableResult
    func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let port, suspended else { return false }
        CGEvent.tapEnable(tap: port, enable: true)
        suspended = false
        return true
    }
}
