import AppKit
import Foundation

/// Delivers a finished transcript into whatever text field currently has focus.
public protocol TextInserting: AnyObject, Sendable {
    func insert(_ text: String) throws
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

    private let pasteboard: NSPasteboard
    private let paste: PasteAction
    private let restoreDelay: TimeInterval
    private let queue = DispatchQueue(label: "com.sikaihuang.murmur.clipboard")

    public init(
        pasteboard: NSPasteboard = .general,
        restoreDelay: TimeInterval = 0.35,
        paste: @escaping PasteAction = ClipboardPasteInserter.synthesizeCommandV
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.paste = paste
    }

    public func insert(_ text: String) throws {
        guard !text.isEmpty else { return }

        let saved = Self.snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ownedChangeCount = pasteboard.changeCount

        paste()

        // Restore only if nothing else has claimed the pasteboard since, so a
        // copy the user makes during the delay is never clobbered.
        queue.asyncAfter(deadline: .now() + restoreDelay) { [pasteboard] in
            guard pasteboard.changeCount == ownedChangeCount else { return }
            Self.restore(saved, to: pasteboard)
        }
    }

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

    // MARK: - Key synthesis

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

    public func insert(_ text: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.append(text)
    }
}
