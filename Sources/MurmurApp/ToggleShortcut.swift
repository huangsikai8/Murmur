import AppKit
import Carbon.HIToolbox
import Foundation

/// A chord that toggles hands-free dictation on and off.
///
/// Deliberately separate from `Hotkey`. Hold-to-talk keys are bare modifiers
/// with press-and-hold semantics; a toggle has to be a chord, because a bare
/// modifier tapped once is indistinguishable from the same modifier being used
/// for anything else.
public enum ToggleShortcut: String, CaseIterable, Codable, Sendable, Identifiable {
    case none
    case optionCommandD
    case controlOptionD
    case optionCommandH
    case controlOptionSpace
    case shiftCommandD

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "Off"
        case .optionCommandD: "⌥⌘D"
        case .controlOptionD: "⌃⌥D"
        case .optionCommandH: "⌥⌘H"
        case .controlOptionSpace: "⌃⌥Space"
        case .shiftCommandD: "⇧⌘D"
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .none: nil
        case .optionCommandD, .controlOptionD, .shiftCommandD: UInt32(kVK_ANSI_D)
        case .optionCommandH: UInt32(kVK_ANSI_H)
        case .controlOptionSpace: UInt32(kVK_Space)
        }
    }

    /// Carbon modifier mask, which is not the same set of constants as
    /// `NSEvent.ModifierFlags`.
    var carbonModifiers: UInt32 {
        switch self {
        case .none: 0
        case .optionCommandD, .optionCommandH: UInt32(optionKey | cmdKey)
        case .controlOptionD, .controlOptionSpace: UInt32(controlKey | optionKey)
        case .shiftCommandD: UInt32(shiftKey | cmdKey)
        }
    }
}

/// Registers one system-wide chord and reports when it is pressed.
///
/// Uses Carbon's `RegisterEventHotKey` rather than the `NSEvent` global monitor
/// that `HotkeyMonitor` uses, for one reason: a Carbon hotkey **consumes** the
/// event. `NSEvent` monitors are passive, so a toggle bound to ⌥⌘D would also
/// reach whatever application is frontmost and trigger its own ⌥⌘D. Holding a
/// bare modifier can be observed passively; claiming a chord cannot.
///
/// It also needs no permission at all, where the passive monitors need
/// Accessibility.
@MainActor
public final class ToggleShortcutMonitor {

    public var shortcut: ToggleShortcut {
        didSet {
            guard shortcut != oldValue else { return }
            register()
        }
    }

    public var onTrigger: (() -> Void)?

    /// Carbon reports a held chord as repeated presses. Left alone that flips
    /// the mode back and forth for as long as the keys are down, which reads as
    /// the shortcut simply not working.
    private var lastFired: ContinuousClock.Instant?
    private static let repeatGuard = Duration.milliseconds(400)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isStarted = false

    /// The Carbon callback is a C function pointer and cannot capture, so the
    /// live monitor is reached through this instead.
    nonisolated(unsafe) fileprivate static weak var active: ToggleShortcutMonitor?

    public init(shortcut: ToggleShortcut = .none) {
        self.shortcut = shortcut
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        Self.active = self
        installHandler()
        register()
    }

    public func stop() {
        isStarted = false
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        if Self.active === self { Self.active = nil }
    }

    private func installHandler() {
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
                Task { @MainActor in ToggleShortcutMonitor.active?.fire() }
                return noErr
            },
            1, &spec, nil, &handlerRef)
    }

    private func register() {
        unregister()
        guard isStarted, let keyCode = shortcut.keyCode else { return }

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: murmurHotKeySignature, id: 1)
        let status = RegisterEventHotKey(
            keyCode, shortcut.carbonModifiers, identifier,
            GetEventDispatcherTarget(), 0, &reference)

        // A chord another application already claimed cannot be registered, and
        // the failure is silent from the user's side — they press it and
        // nothing happens — so it is worth a line in the log.
        guard status == noErr else {
            Log.write("could not register \(shortcut.displayName): OSStatus \(status)")
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
