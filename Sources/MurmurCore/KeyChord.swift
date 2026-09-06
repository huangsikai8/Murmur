import AppKit
import Carbon.HIToolbox

/// One system-wide key combination: a key, the modifiers held with it, and the
/// text to draw for it.
///
/// Recorded from a real key press rather than picked out of a list, so it can
/// be whatever is free on this machine. That is also why the label is stored
/// rather than derived: the character a key prints depends on the keyboard
/// layout in use, and the layout can change after the chord is recorded —
/// asking Carbon what `kVK_ANSI_D` prints *today* would relabel a shortcut the
/// speaker set months ago, while the key they physically press stays the same.
public struct KeyChord: Codable, Equatable, Sendable, Identifiable {

    /// Virtual key code (`kVK_*`). This, not the character, is what Carbon
    /// registers and what the key on the keyboard actually is.
    public let keyCode: UInt32

    /// Carbon modifier mask (`cmdKey`, `optionKey`, …), which is deliberately
    /// not the same set of constants as `NSEvent.ModifierFlags`.
    public let carbonModifiers: UInt32

    /// What the key printed when it was recorded — "D", "Space", "↩".
    public let keyLabel: String

    public var id: String { "\(carbonModifiers)-\(keyCode)" }

    /// Drawn in the order macOS draws them: ⌃⌥⇧⌘, then the key.
    public var displayName: String {
        var glyphs = ""
        if carbonModifiers & UInt32(controlKey) != 0 { glyphs += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { glyphs += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { glyphs += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { glyphs += "⌘" }
        return glyphs + keyLabel
    }

    public init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    /// The chord a key press describes, or `nil` if it does not describe one.
    ///
    /// Two presses are refused. A bare key, because a global hotkey on `D`
    /// would claim the letter everywhere, in every application, for as long as
    /// Murmur runs. And Shift alone as the modifier, for the same reason one
    /// step removed: ⇧D is a capital D.
    public init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }

        guard let label = Self.label(for: event) else { return nil }
        self.init(
            keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, keyLabel: label)
    }

    /// How to name the key that was pressed.
    ///
    /// The table comes first: `charactersIgnoringModifiers` answers "\r" for
    /// Return and "\u{7f}" for Delete, which would be drawn as nothing at all.
    private static func label(for event: NSEvent) -> String? {
        if let named = namedKeys[Int(event.keyCode)] { return named }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }
        // A control character that is not in the table above is a key with no
        // name worth drawing, so the press is refused rather than recorded as
        // an empty box.
        guard let scalar = characters.unicodeScalars.first, scalar.value >= 0x20 else {
            return nil
        }
        return characters.uppercased()
    }

    /// Keys whose character cannot be drawn, named the way macOS names them in
    /// its own menus.
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_ANSI_KeypadEnter: "⌤",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
