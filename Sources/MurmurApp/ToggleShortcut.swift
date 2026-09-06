import AppKit
import Carbon.HIToolbox
import Foundation
import MurmurCore

/// The fixed chords the hands-free toggle used to be chosen from.
///
/// Kept only to read a preference written by an older build: shortcuts are
/// recorded now, so nothing new is ever stored in this form. `chord` is the
/// whole of the migration.
enum ToggleShortcut: String, CaseIterable, Codable, Sendable, Identifiable {
    case none
    case optionCommandD
    case controlOptionD
    case optionCommandH
    case controlOptionSpace
    case shiftCommandD

    var id: String { rawValue }

    var chord: KeyChord? {
        switch self {
        case .none: nil
        case .optionCommandD:
            KeyChord(
                keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(optionKey | cmdKey),
                keyLabel: "D")
        case .controlOptionD:
            KeyChord(
                keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey | optionKey),
                keyLabel: "D")
        case .optionCommandH:
            KeyChord(
                keyCode: UInt32(kVK_ANSI_H), carbonModifiers: UInt32(optionKey | cmdKey),
                keyLabel: "H")
        case .controlOptionSpace:
            KeyChord(
                keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey),
                keyLabel: "Space")
        case .shiftCommandD:
            KeyChord(
                keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(shiftKey | cmdKey),
                keyLabel: "D")
        }
    }
}

/// Registers one system-wide chord and reports when it is pressed.
///
/// Uses Carbon's `RegisterEventHotKey` rather than the `NSEvent` global monitor
/// that `HotkeyMonitor` uses, for one reason: a Carbon hotkey **consumes** the
/// event. `NSEvent` monitors are passive, so a chord bound to ⌥⌘D would also
/// reach whatever application is frontmost and trigger its own ⌥⌘D. Holding a
/// bare modifier can be observed passively; claiming a chord cannot.
///
/// It also needs no permission at all, where the passive monitors need
/// Accessibility.
///
/// More than one of these can be live at a time — hands-free and the history
/// window each own one — so every instance takes its own hotkey id and the
/// single Carbon handler dispatches on it. One shared `active` monitor, which
/// is what this had while there was only one shortcut, would have meant the
/// second one silently replacing the first.
@MainActor
final class ShortcutMonitor {

    var chord: KeyChord? {
        didSet {
            guard chord != oldValue else { return }
            register()
        }
    }

    var onTrigger: (() -> Void)?

    /// Named in the log, so a chord another application already owns can be
    /// told apart from one that is simply not bound.
    private let name: String

    /// Carbon reports a held chord as repeated presses. Left alone that flips
    /// the mode back and forth for as long as the keys are down, which reads as
    /// the shortcut simply not working.
    private var lastFired: ContinuousClock.Instant?
    private static let repeatGuard = Duration.milliseconds(400)

    private let identifier: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var isStarted = false

    /// The Carbon callback is a C function pointer and cannot capture, so the
    /// live monitors are reached through this instead, keyed by the hotkey id
    /// the event carries.
    private static var monitors: [UInt32: ShortcutMonitor] = [:]
    private static var nextIdentifier: UInt32 = 1
    /// One handler for the process, not one per monitor: `InstallEventHandler`
    /// on the dispatcher target would otherwise deliver every hotkey press to
    /// every handler installed.
    private static var handlerRef: EventHandlerRef?

    init(name: String, chord: KeyChord? = nil) {
        self.name = name
        self.chord = chord
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        Self.monitors[identifier] = self
        Self.installHandler()
        register()
    }

    func stop() {
        isStarted = false
        unregister()
        Self.monitors[identifier] = nil
    }

    private static func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr, identifier.signature == murmurHotKeySignature else {
                    return OSStatus(eventNotHandledErr)
                }
                let id = identifier.id
                Task { @MainActor in ShortcutMonitor.monitors[id]?.fire() }
                return noErr
            },
            1, &spec, nil, &handlerRef)
    }

    private func register() {
        unregister()
        guard isStarted, let chord else { return }

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: murmurHotKeySignature, id: identifier)
        let status = RegisterEventHotKey(
            chord.keyCode, chord.carbonModifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &reference)

        // A chord another application already claimed cannot be registered, and
        // the failure is silent from the user's side — they press it and
        // nothing happens — so it is worth a line in the log.
        guard status == noErr else {
            Log.write("could not register \(chord.displayName) for \(name): OSStatus \(status)")
            return
        }
        hotKeyRef = reference
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    fileprivate func fire() {
        let now = ContinuousClock.now
        if let lastFired, now - lastFired < Self.repeatGuard { return }
        lastFired = now
        onTrigger?()
    }
}

/// 'MRMR', so the handler ignores hotkeys registered by anything else.
private let murmurHotKeySignature: OSType = 0x4D52_4D52
