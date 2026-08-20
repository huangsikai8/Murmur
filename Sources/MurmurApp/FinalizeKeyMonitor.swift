import AppKit
import Foundation

/// Watches for the key that ends an utterance early, and swallows it.
///
/// This cannot use the passive `NSEvent` global monitor that Escape uses.
/// A passive monitor observes without consuming, which is right for Escape —
/// cancelling costs nothing if the key also reaches the app — and wrong here.
/// Return is the submit key almost everywhere: in Slack, iMessage, a browser
/// search box, letting it through would send whatever is in the field *before*
/// cleanup finishes and the transcript arrives, splitting one sentence across
/// two messages. A `CGEventTap` is the only thing that can stop the keystroke.
///
/// The tap consumes the key only while an utterance is actually open, which is
/// the few seconds someone is mid-sentence. At every other moment Return
/// behaves exactly as it always did, including while hands-free is on and
/// nobody is speaking.
///
/// No new permission is needed: an event tap requires Accessibility, which
/// Murmur already holds in order to post the paste keystroke.
@MainActor
final class FinalizeKeyMonitor {

    /// Keys that finalize. Return and the keypad's Enter are the same gesture
    /// to a speaker, and binding only one of them reads as the feature being
    /// broken on a full-size keyboard.
    static let returnKey: CGKeyCode = 36
    static let keypadEnterKey: CGKeyCode = 76

    /// Which keys end an utterance. Settable so the binding can move off Return
    /// without touching the tap itself.
    var keys: Set<CGKeyCode> = [returnKey, keypadEnterKey]

    /// Whether a key press should be swallowed right now. Consulted on the
    /// event thread for every keystroke, so it must be cheap and must not
    /// block: anything slow here delays every keystroke on the system.
    private let shouldFinalize: @MainActor () -> Bool
    private let onFinalize: @MainActor () -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(
        shouldFinalize: @escaping @MainActor () -> Bool,
        onFinalize: @escaping @MainActor () -> Void
    ) {
        self.shouldFinalize = shouldFinalize
        self.onFinalize = onFinalize
    }

    var isRunning: Bool { tap != nil }

    /// Installs the tap. Returns false when Accessibility is not granted, in
    /// which case hands-free still works and only the early-finish key is lost.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            let created = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                // A tap that can return nil, which is what consuming requires.
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<FinalizeKeyMonitor>
                        .fromOpaque(userInfo).takeUnretainedValue()
                    return monitor.handle(type: type, event: event)
                },
                userInfo: context
            )
        else {
            Log.write("finalize key: event tap not created, Accessibility may be denied")
            return false
        }

        let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = loopSource
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    deinit {
        // `stop()` is main-actor isolated and deinit is not, so the tap is torn
        // down directly here. Leaving it installed would keep swallowing keys
        // for a monitor nothing owns any more.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    /// Runs on the event thread for every key press on the system.
    private nonisolated func handle(
        type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long, and a disabled tap
        // fails silently — the key simply stops working. Re-enabling is the
        // documented recovery.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated {
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // A modified Return — ⇧⏎ for a soft newline, ⌘⏎ to send — is somebody
        // reaching for their app's own shortcut, so it is never swallowed.
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        guard event.flags.intersection(modifiers).isEmpty else {
            return Unmanaged.passUnretained(event)
        }

        // The tap is installed on the main run loop, so the callback already
        // runs on the main thread and the state it reads is the real state
        // rather than a copy that may be stale.
        let consumed = MainActor.assumeIsolated { () -> Bool in
            guard keys.contains(code), shouldFinalize() else { return false }
            onFinalize()
            return true
        }
        return consumed ? nil : Unmanaged.passUnretained(event)
    }
}
