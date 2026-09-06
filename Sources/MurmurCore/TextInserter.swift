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
    /// Pasted, but the focused element could not be read at all, so there is
    /// no way to know whether anything received it. Treated as the cautious
    /// middle: the words stay on the clipboard as with `leftOnClipboard`, but
    /// nothing is announced, because in practice the paste has landed and
    /// saying it did not is worse than saying nothing.
    case pastedUnverified
}

/// Whether the thing with keyboard focus can take typed text.
public enum FocusVerdict: Sendable, Equatable {
    /// A focused element was read and looks editable.
    case acceptsText
    /// A focused element was read and cannot hold text — or the frontmost
    /// application reports no focused element at all, which is the case this
    /// whole check exists for.
    case rejectsText
    /// The accessibility tree could not be read. Not the same as "no": on
    /// macOS 26 the system-wide `AXFocusedUIElement` query returns
    /// `cannotComplete` immediately, for every application, so treating a
    /// failed query as a definite "nothing focused" made the app claim it had
    /// only copied to the clipboard while the paste was landing normally.
    case unknown
}

/// Delivers a finished transcript into whatever text field currently has focus.
public protocol TextInserting: AnyObject, Sendable {
    /// `targetProcess` is the application dictation started in, which is where
    /// the paste is going. It is only used to ask the right process whether it
    /// has a field focused — the paste itself goes wherever the keystroke goes,
    /// as it always has.
    @discardableResult
    func insert(_ text: String, into targetProcess: pid_t?) throws -> InsertionOutcome

    /// Removes the last `count` characters, as pressing Delete that many times
    /// would. Used to take back an insertion the speaker rejected.
    func deleteBackward(count: Int) throws
}

extension TextInserting {
    @discardableResult
    public func insert(_ text: String) throws -> InsertionOutcome {
        try insert(text, into: nil)
    }
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
    public typealias FocusProbe = @Sendable (pid_t?) -> FocusVerdict

    /// Watches the place the text was sent to and reports whether it has
    /// arrived yet.
    ///
    /// Returns `nil` when there is nothing to watch — an element that reports
    /// neither a length nor a caret cannot answer the question, and a watcher
    /// that always says "not yet" would hold the clipboard for the full
    /// ceiling on every utterance. Injected for the same reason the probe is:
    /// a test process has no focused field.
    public typealias PasteWatcher = @Sendable (pid_t?) -> (@Sendable () -> Bool)?

    private let pasteboard: NSPasteboard
    private let paste: PasteAction
    private let restoreDelay: TimeInterval
    private let canReceiveText: FocusProbe
    private let watchPaste: PasteWatcher
    private let queue = DispatchQueue(label: "com.sikaihuang.murmur.clipboard")

    /// The change count the pasteboard had when Murmur last wrote a transcript
    /// to it.
    ///
    /// Kept so a transcript is never mistaken for the user's own clipboard and
    /// handed back in the middle of a paste — see `insert`. The change count
    /// rather than the text: it is exact where comparing strings is a guess,
    /// since a speaker who copies the sentence they just dictated has a
    /// clipboard of their own that happens to read the same. Static because
    /// the question is whether *Murmur* put it there, which is not a question
    /// about any one inserter. Keyed by pasteboard, because a change count is
    /// only meaningful on the board it was read from.
    private nonisolated(unsafe) static var placedChangeCounts: [NSPasteboard.Name: Int] = [:]
    private static let placedLock = NSLock()

    public init(
        pasteboard: NSPasteboard = .general,
        restoreDelay: TimeInterval = ClipboardPasteInserter.confirmationCeiling,
        paste: @escaping PasteAction = ClipboardPasteInserter.synthesizeCommandV,
        canReceiveText: @escaping FocusProbe = ClipboardPasteInserter.focusedElementAcceptsText,
        watchPaste: @escaping PasteWatcher = ClipboardPasteInserter.focusedElementWatcher
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.paste = paste
        self.canReceiveText = canReceiveText
        self.watchPaste = watchPaste
    }

    /// Longest the transcript is left on the pasteboard when the paste cannot
    /// be confirmed to have landed.
    ///
    /// The old behaviour was this alone, at 0.35 s, and 0.35 s is a guess about
    /// somebody else's process. Chromium — Chrome, VS Code, Electron apps —
    /// reads the pasteboard asynchronously after the ⌘V is delivered, so a busy
    /// renderer reads it *after* the restore and pastes whatever was put back.
    /// Long enough to cover that, and paid only when nothing can be watched:
    /// a confirmed paste restores as soon as the text appears.
    public static let confirmationCeiling: TimeInterval = 1.5

    /// How often the target is asked whether the text has arrived. Two
    /// attribute reads on one element — a length and a caret position, never
    /// the text itself, which on a large document would be the expensive one.
    private static let confirmationInterval: TimeInterval = 0.02

    /// Waited after the text is seen to arrive. The insertion happens after the
    /// application has read the pasteboard, so this is margin rather than
    /// necessity.
    private static let confirmationGrace: TimeInterval = 0.05

    @discardableResult
    public func insert(_ text: String, into targetProcess: pid_t? = nil) throws
        -> InsertionOutcome
    {
        guard !text.isEmpty else { return .pasted }

        // Asked *before* pasting, because afterwards the answer is confounded
        // by the paste itself. This only decides whether the clipboard is put
        // back — the paste is attempted either way, so a false negative costs
        // the previous clipboard and never costs the transcript.
        let verdict = canReceiveText(targetProcess)

        // A transcript this inserter left behind is not the user's clipboard,
        // and putting it back is how the *previous* utterance ends up pasted
        // in place of this one: two paths here deliberately leave the words on
        // the pasteboard (`leftOnClipboard`, `pastedUnverified`) and the
        // changeCount guard skips the restore on a third, so the value sitting
        // there when the next dictation starts is very often the last
        // transcript. Restoring nothing leaves the current transcript in
        // place, so a late read can only ever paste the right words twice.
        let ours = Self.isOurs(pasteboard.changeCount, on: pasteboard)

        // Only the accepting path restores, so on the other two this was a
        // copy of the whole pasteboard taken to be discarded a few lines later.
        let restores = verdict == .acceptsText && !ours
        let saved = restores ? Self.snapshot(pasteboard) : []

        // Snapshotted before the paste is posted, so what it compares against
        // is the state of the field before anything arrived in it.
        let confirm = restores ? watchPaste(targetProcess) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ownedChangeCount = pasteboard.changeCount
        Self.remember(ownedChangeCount, on: pasteboard)

        paste()

        guard verdict == .acceptsText else {
            // Nothing to paste into, or no way to tell: keep the words on the
            // clipboard so they can be placed by hand. Restoring here would
            // silently discard a sentence that was just spoken.
            return verdict == .unknown ? .pastedUnverified : .leftOnClipboard
        }
        guard restores else {
            Self.report("clipboard held Murmur's own last transcript; not restoring it")
            return .pasted
        }

        scheduleRestore(saved, ownedChangeCount: ownedChangeCount, confirm: confirm)
        return .pasted
    }

    private static func remember(_ changeCount: Int, on pasteboard: NSPasteboard) {
        placedLock.lock()
        placedChangeCounts[pasteboard.name] = changeCount
        placedLock.unlock()
    }

    /// Whether what is on the pasteboard now is a transcript Murmur left there,
    /// untouched since.
    private static func isOurs(_ changeCount: Int, on pasteboard: NSPasteboard) -> Bool {
        placedLock.lock()
        defer { placedLock.unlock() }
        return changeCount == placedChangeCounts[pasteboard.name]
    }

    // MARK: - Putting the clipboard back

    /// Restores `saved` once the paste has landed, or at the ceiling if that
    /// can never be established.
    ///
    /// Restoring on a timer alone is a guess about another process's schedule,
    /// and it is wrong in exactly the case that matters: an application that
    /// reads the pasteboard asynchronously reads it after the restore and
    /// pastes the value that was put back. Every restore is also conditional on
    /// nothing else having claimed the pasteboard since, so a copy the user
    /// makes while this is waiting is never clobbered.
    private func scheduleRestore(
        _ saved: [NSPasteboardItem], ownedChangeCount: Int, confirm: (@Sendable () -> Bool)?
    ) {
        let started = ContinuousClock.now
        guard let confirm else {
            queue.asyncAfter(deadline: .now() + restoreDelay) { [pasteboard] in
                guard pasteboard.changeCount == ownedChangeCount else { return }
                Self.restore(saved, to: pasteboard)
            }
            return
        }
        poll(saved, ownedChangeCount: ownedChangeCount, confirm: confirm, since: started)
    }

    private func poll(
        _ saved: [NSPasteboardItem], ownedChangeCount: Int, confirm: @escaping @Sendable () -> Bool,
        since started: ContinuousClock.Instant
    ) {
        queue.asyncAfter(deadline: .now() + Self.confirmationInterval) { [self, pasteboard] in
            guard pasteboard.changeCount == ownedChangeCount else { return }

            let waited = ContinuousClock.now - started
            let waitedMs = Int(waited / .milliseconds(1))
            if confirm() {
                queue.asyncAfter(deadline: .now() + Self.confirmationGrace) {
                    guard pasteboard.changeCount == ownedChangeCount else { return }
                    Self.restore(saved, to: pasteboard)
                    Self.report(
                        "paste landed after \(waitedMs) ms, clipboard restored")
                }
                return
            }
            guard waited < .seconds(restoreDelay) else {
                Self.restore(saved, to: pasteboard)
                Self.report(
                    "paste not seen to land within \(waitedMs) ms, "
                        + "clipboard restored anyway")
                return
            }
            poll(saved, ownedChangeCount: ownedChangeCount, confirm: confirm, since: started)
        }
    }

    // MARK: - Is there anywhere for the text to go?

    /// Reports each query and its answer, so a wrong verdict can be diagnosed
    /// instead of argued about. Wired to the log by the app.
    public nonisolated(unsafe) static var diagnostics: (@Sendable (String) -> Void)?

    public static let focusedElementAcceptsText: FocusProbe = { target in
        describeFocus(target: target).verdict
    }

    /// Watches the focused element for text arriving in it.
    ///
    /// The two attributes read are a length and a caret position, never the
    /// value: a paste moves both, and on a large document reading the text
    /// itself to compare it would cost more than the wait it is shortening.
    /// An element that reports neither cannot be watched, and `nil` sends the
    /// restore back to the ceiling rather than to a watcher that would never
    /// say yes.
    /// What `focusedElementWatcher` reads, for `--testpaste` to print.
    public static func focusedElementExtent(target: pid_t?) -> String? {
        guard let element = describeFocus(target: target).element else { return nil }
        return textExtent(of: element)
    }

    public static let focusedElementWatcher: PasteWatcher = { target in
        guard let element = describeFocus(target: target).element else { return nil }
        // A hung or busy application must not stall the polling queue: these
        // reads happen every 20 ms and the answer is only ever advisory.
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let before = textExtent(of: element) else { return nil }
        return { textExtent(of: element).map { $0 != before } ?? false }
    }

    /// How much text the element holds and where the caret sits in it.
    ///
    /// Both move when text is pasted, and either one alone is enough — a field
    /// that reports no length still moves its caret, and one that reports no
    /// caret still grows.
    static func textExtent(of element: AXUIElement) -> String? {
        var parts: [String] = []

        var characters: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &characters) == .success,
            let count = characters as? Int
        {
            parts.append("n=\(count)")
        }

        var selection: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
            let value = selection, CFGetTypeID(value) == AXValueGetTypeID()
        {
            var range = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &range) {
                parts.append("caret=\(range.location)+\(range.length)")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// What has keyboard focus in the application the text is going to, and
    /// whether text can be typed into it.
    ///
    /// Asking "what is focused right now" is the obvious approach and it does
    /// not work. Measured on macOS 26: the system-wide `AXFocusedUIElement`
    /// returns `cannotComplete` in 0 ms from a command-line process, and
    /// `noValue` from the running app in the instant after the overlay is
    /// hidden — while the paste that follows lands in the field perfectly.
    /// Both were read as "nothing focused", which is what produced the card
    /// claiming the text had only been copied.
    ///
    /// So the question asked is a narrower one with a stable answer: does the
    /// application this dictation *started* in have an editable element
    /// focused. That target is captured on the hotkey, before any of this
    /// churn, and it is where the paste is going.
    public static func describeFocus(target: pid_t? = nil)
        -> (description: String, verdict: FocusVerdict, element: AXUIElement?)
    {
        var attempts: [String] = []

        for query in queries(target: target) {
            var focused: CFTypeRef?
            var status = AXUIElementCopyAttributeValue(
                query.element, kAXFocusedUIElementAttribute as CFString, &focused)

            // Chromium — so VS Code, Slack, Discord, every Electron app —
            // builds no accessibility tree until an assistive app asks for
            // one, and answers `noValue` until it has. Asking is a single
            // attribute write, after which the same query returns the real
            // focused element.
            if status != .success, let pid = query.process, enableChromiumAccessibility(pid) {
                focused = nil
                status = AXUIElementCopyAttributeValue(
                    query.element, kAXFocusedUIElementAttribute as CFString, &focused)
                attempts.append("\(query.name)=asked for an accessibility tree")
            }

            guard status == .success, let value = focused,
                CFGetTypeID(value) == AXUIElementGetTypeID()
            else {
                attempts.append("\(query.name)=\(describe(status))")
                continue
            }

            let element = value as! AXUIElement
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            let name = (role as? String) ?? "unknown"

            var settable: DarwinBoolean = false
            let settableKnown =
                AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
                == .success

            // A settable value is the strong signal, and the role is the
            // fallback for the fields that do not report one. The roles are
            // kept narrow on purpose: `AXGroup` covers most of the
            // accessibility tree, so counting it meant the answer was "yes, it
            // can take text" almost everywhere, including on the desktop —
            // which is exactly the case this exists to catch.
            let accepts = (settableKnown && settable.boolValue) || textRoles.contains(name)
            let settableText = settableKnown ? String(settable.boolValue) : "?"
            report(
                "focus: \(attempts.joined(separator: ", "))\(attempts.isEmpty ? "" : ", ")"
                    + "\(query.name)=role \(name) settable=\(settableText) "
                    + "-> \(accepts ? "paste" : "clipboard")")
            return (
                "\(name), settable=\(settableText), via \(query.name)",
                accepts ? .acceptsText : .rejectsText,
                accepts ? element : nil
            )
        }

        // Nothing could be read anywhere. Deliberately *not* reported as
        // "nothing focused": every observed failure here — `cannotComplete`
        // from a system-wide query that never works, `noValue` in the moment
        // after the overlay closes — sat in front of a paste that landed. A
        // wrong "no" here is a false alarm on every single utterance, which is
        // worse than the silence, and the transcript is kept on the clipboard
        // either way so nothing is lost.
        report("focus: \(attempts.joined(separator: ", ")) -> unreadable, pasting anyway")
        return ("unreadable (\(attempts.joined(separator: ", ")))", .unknown, nil)
    }

    /// The elements worth asking, most authoritative first, each named for the
    /// log so a failing step is identifiable rather than inferred.
    private static func queries(target: pid_t?)
        -> [(name: String, element: AXUIElement, process: pid_t?)]
    {
        var queries: [(String, AXUIElement, pid_t?)] = []
        let frontmost = NSWorkspace.shared.frontmostApplication

        if let target {
            let name =
                NSRunningApplication(processIdentifier: target)?.localizedName ?? "pid \(target)"
            queries.append(("target \(name)", AXUIElementCreateApplication(target), target))
        }
        if let frontmost, frontmost.processIdentifier != target {
            let pid = frontmost.processIdentifier
            queries.append((
                "frontmost \(frontmost.localizedName ?? "pid \(pid)")",
                AXUIElementCreateApplication(pid), pid
            ))
        }
        queries.append(("system-wide", AXUIElementCreateSystemWide(), nil))
        return queries
    }

    /// Applications already asked to build an accessibility tree, so the write
    /// happens once each rather than on every utterance.
    private nonisolated(unsafe) static var accessibilityRequested: Set<pid_t> = []
    private static let requestedLock = NSLock()

    /// Asks a Chromium-based application to expose its accessibility tree.
    ///
    /// `AXManualAccessibility` is Chromium's own opt-in switch, ignored by
    /// every application that is not built on it — so this is a no-op
    /// everywhere else rather than something that needs to detect Electron.
    /// Returns whether it is worth querying again.
    private static func enableChromiumAccessibility(_ pid: pid_t) -> Bool {
        requestedLock.lock()
        let alreadyAsked = accessibilityRequested.contains(pid)
        if !alreadyAsked { accessibilityRequested.insert(pid) }
        requestedLock.unlock()
        guard !alreadyAsked else { return false }

        let application = AXUIElementCreateApplication(pid)
        let status = AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return status == .success
    }

    private static func report(_ message: String) {
        diagnostics?(message)
    }

    private static func describe(_ status: AXError) -> String {
        switch status {
        case .success: "success"
        case .failure: "failure"
        case .illegalArgument: "illegalArgument"
        case .invalidUIElement: "invalidUIElement"
        case .cannotComplete: "cannotComplete"
        case .attributeUnsupported: "attributeUnsupported"
        case .noValue: "noValue"
        case .apiDisabled: "apiDisabled"
        case .notImplemented: "notImplemented"
        default: "error \(status.rawValue)"
        }
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
    public func insert(_ text: String, into targetProcess: pid_t? = nil) throws
        -> InsertionOutcome
    {
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
