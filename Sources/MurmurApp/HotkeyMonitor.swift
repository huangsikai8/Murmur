import AppKit
import Carbon.HIToolbox
import Foundation

/// Hold-to-talk hotkeys. Every option uses press-and-hold / release semantics;
/// none of them toggle.
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

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isHeld = false

    public init(hotkey: Hotkey = .fn) {
        self.hotkey = hotkey
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    public func start() {
        stop()
        let mask: NSEvent.EventTypeMask =
            hotkey.isModifierKey ? [.flagsChanged] : [.keyDown, .keyUp, .flagsChanged]

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
        guard event.type == .flagsChanged else { return }
        // Only the physical key we care about; the flag alone is ambiguous
        // because arrow and function keys also set `.function`.
        guard event.keyCode == hotkey.keyCode, let flag = hotkey.modifierFlag else { return }

        let pressed = event.modifierFlags.contains(flag)
        setHeld(pressed)
    }

    private func handleRegularKey(_ event: NSEvent) {
        // Releasing the required modifier ends the hold even if the key event
        // itself is swallowed by another application.
        if event.type == .flagsChanged {
            if isHeld, !event.modifierFlags.contains(hotkey.requiredFlags) {
                setHeld(false)
            }
            return
        }
        guard event.keyCode == hotkey.keyCode else { return }
        guard !event.isARepeat else { return }

        switch event.type {
        case .keyDown:
            guard event.modifierFlags.contains(hotkey.requiredFlags) else { return }
            setHeld(true)
        case .keyUp:
            setHeld(false)
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
