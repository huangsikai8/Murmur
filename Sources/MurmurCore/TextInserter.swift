import AppKit
import ApplicationServices
import Foundation

/// What became of a transcript that was handed to an inserter.
public enum InsertionOutcome: Sendable, Equatable {
    /// Pasted into a focused editable field. The previous clipboard was put
    /// back, as it always is.
    case pasted
    /// Nothing looked able to receive it, so the transcript was left on the
    /// clipboard instead of being dropped. The previous clipboard is gone —
    /// deliberately, because the transcript is the more valuable of the two at
    /// that moment, and losing dictated words is the failure worth avoiding.
    case leftOnClipboard
}

/// Delivers a finished transcript into whatever text field currently has focus.
public protocol TextInserting: AnyObject, Sendable {
    @discardableResult
    func insert(_ text: String) throws -> InsertionOutcome

    /// Removes the last `count` characters, as pressing Delete that many times
    /// would. Used to take back an insertion the speaker rejected.
    func deleteBackward(count: Int) throws
}

/// Clipboard-and-paste insertion.
///
/// The whole transcript is placed on the pasteboard and pasted in one
/// synthesized Command-V. Because the string crosses the boundary as a single
/// value, it cannot be split mid-word the way per-keystroke synthesis can.
/// The user's previous clipboard is captured beforehand and restored
/// asynchronously once the paste has landed.
public final class ClipboardPasteInserter: TextInserting, @unchecked Sendable {

    /// Injected so tests can exercise clipboard save/restore without
    /// synthesizing real key events.
    public typealias PasteAction = @Sendable () -> Void

    /// Whether anything is able to receive typed text right now. Injected for
    /// the same reason `paste` is: a test process has no focused field, so the
    /// real probe would answer "no" to every case and the restore behaviour
    /// could not be exercised at all.
    public typealias FocusProbe = @Sendable () -> Bool

    private let pasteboard: NSPasteboard
    private let paste: PasteAction
    private let restoreDelay: TimeInterval
    private let canReceiveText: FocusProbe
    private let queue = DispatchQueue(label: "com.sikaihuang.murmur.clipboard")

    public init(
        pasteboard: NSPasteboard = .general,
        restoreDelay: TimeInterval = 0.35,
        paste: @escaping PasteAction = ClipboardPasteInserter.synthesizeCommandV,
        canReceiveText: @escaping FocusProbe = ClipboardPasteInserter.focusedElementAcceptsText
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.paste = paste
        self.canReceiveText = canReceiveText
    }

    @discardableResult
    public func insert(_ text: String) throws -> InsertionOutcome {
        guard !text.isEmpty else { return .pasted }

        // Asked *before* pasting, because afterwards the answer is confounded
        // by the paste itself. This only decides whether the clipboard is put
        // back — the paste is attempted either way, so a false negative costs
        // the previous clipboard and never costs the transcript.
        let canReceive = canReceiveText()

        let saved = Self.snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ownedChangeCount = pasteboard.changeCount

        paste()

        guard canReceive else {
            // Nothing to paste into: keep the words on the clipboard so they
            // can be placed by hand. Restoring here would silently discard a
            // sentence that was just spoken.
            return .leftOnClipboard
        }

        // Restore only if nothing else has claimed the pasteboard since, so a
        // copy the user makes during the delay is never clobbered.
        queue.asyncAfter(deadline: .now() + restoreDelay) { [pasteboard] in
            guard pasteboard.changeCount == ownedChangeCount else { return }
            Self.restore(saved, to: pasteboard)
        }
        return .pasted
    }

    // MARK: - Is there anywhere for the text to go?

    /// Whether the focused element looks able to accept typed text.
    ///
    /// Deliberately generous. A wrong "no" merely leaves the transcript on the
    /// clipboard, while a wrong "yes" is exactly today's behaviour, so the
    /// bias is towards saying yes: any element whose value can be set counts,
    /// and the text roles count even when they do not report a settable value,
    /// which some web and Electron views do not.
    /// Reports what the focused element is, so a wrong answer can be diagnosed
    /// instead of argued about. Wired to the log by the app.
    public nonisolated(unsafe) static var diagnostics: (@Sendable (String) -> Void)?

    public static let focusedElementAcceptsText: FocusProbe = {
        describeFocus().acceptsText
    }

    /// What currently has keyboard focus, and whether text can be typed into it.
    public static func describeFocus() -> (description: String, acceptsText: Bool) {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let value = focused,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            report("focus: nothing focused -> clipboard")
            return ("nothing focused", false)
        }

        let element = value as! AXUIElement

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let name = (role as? String) ?? "unknown"

        var settable: DarwinBoolean = false
        let settableKnown =
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            == .success

        // A settable value is the strong signal, and the role is the fallback
        // for the fields that do not report one. The roles are kept narrow on
        // purpose: `AXGroup` covers most of the accessibility tree, so counting
        // it meant the answer was "yes, it can take text" almost everywhere,
        // including on the desktop — which is exactly the case this exists to
        // catch.
        let accepts = (settableKnown && settable.boolValue) || textRoles.contains(name)
        report(
            "focus: role=\(name) settable=\(settableKnown ? String(settable.boolValue) : "?") "
                + "-> \(accepts ? "paste" : "clipboard")")
        return ("\(name), settable=\(settableKnown ? String(settable.boolValue) : "unknown")",
            accepts)
    }

    private static func report(_ message: String) {
        diagnostics?(message)
    }

    /// Roles that hold editable text. Deliberately narrow — see `describeFocus`.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXSearchFieldSubrole,
    ]

    // MARK: - Pasteboard preservation

    /// A detached copy of the pasteboard's current contents.
    public static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    public static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    /// Deletes backwards by synthesizing Delete presses.
    ///
    /// Backspaces rather than a selection: a selection would have to be made
    /// through the Accessibility API, which many editors expose incompletely,
    /// and getting it wrong would replace text rather than remove it. Pressing
    /// Delete is what a person would do, and behaves the same everywhere.
    public func deleteBackward(count: Int) throws {
        guard count > 0 else { return }
        // A ceiling, because the count comes from a remembered string and a
        // runaway value here would eat a document.
        let limit = min(count, Self.maximumDeletion)
        for _ in 0..<limit { Self.synthesizeDelete() }
    }

    /// Longest insertion that can be taken back. Comfortably longer than any
    /// single utterance, short enough that a bug cannot clear a page.
    public static let maximumDeletion = 2000

    // MARK: - Key synthesis

    /// Posts one Delete keystroke to the session event tap.
    static let synthesizeDelete: @Sendable () -> Void = {
        let source = CGEventSource(stateID: .combinedSessionState)
        let deleteKey: CGKeyCode = 0x33  // ANSI Delete (backspace)
        let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false)
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Posts Command-V to the session event tap. Requires Accessibility.
    public static let synthesizeCommandV: PasteAction = {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Suppress our own synthetic events from being seen as user input.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKey: CGKeyCode = 0x09  // ANSI "v"
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand

        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

/// Test double that captures exactly what would have been inserted.
public final class RecordingInserter: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    public init() {}

    public var inserted: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    @discardableResult
    public func insert(_ text: String) throws -> InsertionOutcome {
        lock.lock(); defer { lock.unlock() }
        storage.append(text)
        return .pasted
    }

    /// Characters asked to be deleted, in order, so a test can assert that a
    /// retraction removed exactly what was inserted.
    public var deletions: [Int] {
        lock.lock(); defer { lock.unlock() }
        return deleted
    }
    private var deleted: [Int] = []

    public func deleteBackward(count: Int) throws {
        lock.lock(); defer { lock.unlock() }
        deleted.append(count)
    }
}
