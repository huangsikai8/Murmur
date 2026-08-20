import AppKit
import Carbon.HIToolbox
import Foundation

/// Dictation hotkeys. Each one can drive either press-and-hold or a latch,
/// depending on `HotkeyMode`.
/// How the dictation key behaves.
public enum HotkeyMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Hold the key, speak, release. The speaker owns both boundaries and the
    /// key is down the whole time.
    case hold
    /// Tap to start, tap again to finish. Also owns both boundaries, without
    /// asking anyone to hold a key through a long sentence — and unlike
    /// hands-free, no silence threshold is involved at all, so a pause to think
    /// costs nothing.
    case latch

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hold: "Hold to talk"
        case .latch: "Tap to start, tap to stop"
        }
    }
}

public enum Hotkey: String, CaseIterable, Codable, Sendable {
    case fn
    case rightOption
    case rightCommand
    case rightControl
    case controlSpace
    case f13, f14, f15, f16, f17, f18, f19

    public var displayName: String {
        switch self {
        case .fn: "Fn (Globe)"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .rightControl: "Right Control"
        case .controlSpace: "Control + Space"
        case .f13: "F13"
        case .f14: "F14"
        case .f15: "F15"
        case .f16: "F16"
        case .f17: "F17"
        case .f18: "F18"
        case .f19: "F19"
        }
    }

    /// Modifier-style keys are tracked through `.flagsChanged`; the rest
    /// through `.keyDown` / `.keyUp`.
    var isModifierKey: Bool {
        switch self {
        case .fn, .rightOption, .rightCommand, .rightControl: true
        default: false
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .fn: 63
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .controlSpace: CGKeyCode(kVK_Space)
        case .f13: CGKeyCode(kVK_F13)
        case .f14: CGKeyCode(kVK_F14)
        case .f15: CGKeyCode(kVK_F15)
        case .f16: CGKeyCode(kVK_F16)
        case .f17: CGKeyCode(kVK_F17)
        case .f18: CGKeyCode(kVK_F18)
        case .f19: CGKeyCode(kVK_F19)
        }
    }

    /// The flag that is set while this modifier is physically held.
    var modifierFlag: NSEvent.ModifierFlags? {
        switch self {
        case .fn: .function
        case .rightOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        default: nil
        }
    }

    /// Modifiers that must accompany a non-modifier key.
    var requiredFlags: NSEvent.ModifierFlags {
        switch self {
        case .controlSpace: .control
        default: []
        }
    }
}

/// Watches for the configured hotkey being held and released, system-wide.
///
/// Uses `NSEvent` global monitors, which need Accessibility but not Input
/// Monitoring. Monitors are passive: they observe without consuming, so the
/// key still behaves normally in other applications.
@MainActor
public final class HotkeyMonitor {

    public var hotkey: Hotkey {
        didSet {
            guard hotkey != oldValue else { return }
            isHeld = false
            restart()
        }
    }

    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    /// Fired in `.latch` mode instead of `onPress`/`onRelease`.
    public var onToggle: (() -> Void)?
    /// Abandons a session started optimistically that turned out to be a chord.
    public var onCancel: (() -> Void)?
    /// Whether dictation is already running, which decides whether a press
    /// starts (optimistically, cancellable) or stops (on release, confirmed).
    public var isDictating: (() -> Bool)?

    /// Hold or latch. Changing it restarts the monitors, because latch mode on
    /// a bare modifier needs to watch ordinary keys as well.
    public var mode: HotkeyMode = .hold {
        didSet { if mode != oldValue { restart() } }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isHeld = false

    /// Latch state for a bare modifier. A modifier tapped on its own is a
    /// latch; the same modifier held down while another key is struck is
    /// someone typing ⌥C, and must not start dictation.
    private var modifierPressedAt: ContinuousClock.Instant?
    private var otherKeyDuringHold = false
    private var startedOptimistically = false

    /// Longest a bare modifier may be down and still count as a tap. Holding it
    /// longer reads as the start of a chord the user then abandoned.
    private static let tapWindow = Duration.milliseconds(600)

    public init(hotkey: Hotkey = .fn) {
        self.hotkey = hotkey
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    public func start() {
        stop()
        // A bare modifier normally needs only `.flagsChanged`. Latch mode also
        // needs `.keyDown`, to tell a tap apart from the same modifier being
        // used to type a shortcut.
        let mask: NSEvent.EventTypeMask =
            hotkey.isModifierKey && mode == .hold
            ? [.flagsChanged] : [.keyDown, .keyUp, .flagsChanged]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        // Also observe while our own menu is frontmost.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        modifierPressedAt = nil
        otherKeyDuringHold = false
        startedOptimistically = false
        if isHeld {
            isHeld = false
            onRelease?()
        }
    }

    private func restart() {
        guard globalMonitor != nil || localMonitor != nil else { return }
        start()
    }

    private func handle(_ event: NSEvent) {
        if hotkey.isModifierKey {
            handleModifier(event)
        } else {
            handleRegularKey(event)
        }
    }

    private func handleModifier(_ event: NSEvent) {
        // Any ordinary key struck while the modifier is down means the modifier
        // is being *used*, not tapped. Only latch mode observes these.
        if event.type == .keyDown {
            if modifierPressedAt != nil { otherKeyDuringHold = true }
            return
        }
        guard event.type == .flagsChanged else { return }
        // Only the physical key we care about; the flag alone is ambiguous
        // because arrow and function keys also set `.function`.
        guard event.keyCode == hotkey.keyCode, let flag = hotkey.modifierFlag else { return }

        let pressed = event.modifierFlags.contains(flag)
        guard mode == .latch else {
            setHeld(pressed)
            return
        }

        if pressed {
            modifierPressedAt = ContinuousClock.now
            otherKeyDuringHold = false
            // Starting is done on the *press*, not the release, because waiting
            // for the release adds however long the finger rests on the key to
            // an opening that already costs time — and the speaker starts
            // talking immediately after a tap. If this turns out to be ⌥C
            // rather than a tap, the release cancels it, which is clean: no
            // text has been produced yet.
            if isDictating?() == false {
                startedOptimistically = true
                onToggle?()
            }
            return
        }

        guard let pressedAt = modifierPressedAt else { return }
        modifierPressedAt = nil

        if startedOptimistically {
            startedOptimistically = false
            // Only a chord invalidates it. A slow press with no other key is
            // still someone meaning to dictate, so duration alone must not
            // throw the session away.
            if otherKeyDuringHold { onCancel?() }
            return
        }

        // Stopping stays on the release and stays strict: cutting an utterance
        // short cannot be undone, so an ambiguous press must not end one.
        guard !otherKeyDuringHold else { return }
        guard ContinuousClock.now - pressedAt <= Self.tapWindow else { return }
        onToggle?()
    }

    private func handleRegularKey(_ event: NSEvent) {
        // Releasing the required modifier ends the hold even if the key event
        // itself is swallowed by another application.
        if event.type == .flagsChanged {
            if mode != .latch, isHeld, !event.modifierFlags.contains(hotkey.requiredFlags) {
                setHeld(false)
            }
            return
        }
        guard event.keyCode == hotkey.keyCode else { return }
        guard !event.isARepeat else { return }

        switch event.type {
        case .keyDown:
            guard event.modifierFlags.contains(hotkey.requiredFlags) else { return }
            // A dedicated key is unambiguous, so latching on the press is
            // enough — no tap window, and holding it does nothing extra.
            if mode == .latch {
                onToggle?()
            } else {
                setHeld(true)
            }
        case .keyUp:
            if mode != .latch { setHeld(false) }
        default:
            break
        }
    }

    private func setHeld(_ held: Bool) {
        guard held != isHeld else { return }  // Collapse key repeat and duplicates.
        isHeld = held
        if held { onPress?() } else { onRelease?() }
    }
}
