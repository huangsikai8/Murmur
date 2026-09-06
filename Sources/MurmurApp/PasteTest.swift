import AppKit
import Foundation
import MurmurCore

/// Measures the other half of an insertion: how long the application in front
/// takes to actually read the pasteboard after the ⌘V is delivered.
///
/// This is the number the restore used to guess at, and guessing it wrong is
/// what put the *previous* transcript into a document. Chromium — Chrome,
/// VS Code, Electron — reads the pasteboard asynchronously, so a busy renderer
/// reads it after a fixed 0.35 s restore and pastes whatever was put back.
///
/// Run it against the applications actually dictated into. Two things must
/// hold, and the second is the one that fails silently: the focused element has
/// to be watchable at all — an element that reports neither a length nor a
/// caret sends every insertion back to the ceiling, which would make the fix a
/// slower restore and nothing else — and the paste has to be *seen* to land.
@MainActor
enum PasteTest {

    static func run(iterations: Int) async -> Int32 {
        print("Click into a text field in the application you want to measure.")
        print("A short sentence will be typed into it \(iterations) time(s).\n")
        for remaining in stride(from: 5, through: 1, by: -1) {
            print("  \(remaining)…")
            try? await Task.sleep(for: .seconds(1))
        }

        let target = NSWorkspace.shared.frontmostApplication
        let name = target?.localizedName ?? "unknown"
        let focus = ClipboardPasteInserter.describeFocus(
            target: target?.processIdentifier)
        print("\nfront application: \(name)")
        print("focused element:   \(focus.description)")

        guard focus.verdict == .acceptsText else {
            print(
                "\nThis element does not take text, so nothing here is restored and "
                    + "there is nothing to measure. Click into a real text field.")
            return 1
        }

        let watcher = ClipboardPasteInserter.focusedElementWatcher(target?.processIdentifier)
        print("watchable:         \(watcher == nil ? "no — every paste would wait out the ceiling" : "yes")")

        let lines = Reports()
        ClipboardPasteInserter.diagnostics = { message in
            guard message.hasPrefix("paste ") || message.hasPrefix("clipboard ") else { return }
            lines.append(message)
        }

        let keepsake = "clipboard from before the test"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(keepsake, forType: .string)

        let inserter = ClipboardPasteInserter()
        var failures = 0
        for index in 1...iterations {
            let sentence = "Murmur paste test \(index). "
            let before = lines.count
            // The synchronous half, which sits between the transcript being
            // ready and the text appearing: the focus verdict, the watcher's
            // own read of the element, the pasteboard write and the ⌘V.
            let started = ContinuousClock.now
            let extentBefore = ClipboardPasteInserter.focusedElementExtent(
                target: target?.processIdentifier)
            let outcome = try? inserter.insert(sentence, into: target?.processIdentifier)
            let insertMs = Double((ContinuousClock.now - started) / .microseconds(1)) / 1000

            // Long enough for the ceiling to have expired either way, so an
            // unconfirmed paste is reported rather than waited for again.
            try? await Task.sleep(for: .milliseconds(400))
            let extentAfter = ClipboardPasteInserter.focusedElementExtent(
                target: target?.processIdentifier)
            print("     extent \(extentBefore ?? "nil") -> \(extentAfter ?? "nil")")
            try? await Task.sleep(for: .seconds(2.1))
            let reported = lines.suffix(from: before).first ?? "nothing reported"
            print(
                String(
                    format: "  %d: %@ in %.1f ms, %@", index,
                    outcome.map(String.init(describing:)) ?? "threw", insertMs, reported))

            if reported.contains("not seen to land") || reported == "nothing reported" {
                failures += 1
            }
        }

        let restored = NSPasteboard.general.string(forType: .string)
        print("\nclipboard afterwards: \(restored ?? "empty")")
        if restored != keepsake {
            print("FAIL: the clipboard from before the test was not put back")
            failures += 1
        }

        // Deliberately not asserted on a time: a slow application is not a
        // defect, and the point of the change is that a slow one is waited for
        // rather than guessed at. What must hold is that the paste was seen.
        if failures > 0 {
            print("FAIL: \(failures) insertion(s) could not be confirmed")
            return 1
        }
        print("OK: every paste was seen to land, and the clipboard came back")
        return 0
    }
}

/// The diagnostics lines, which arrive on the clipboard queue.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func suffix(from index: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return index < storage.count ? Array(storage[index...]) : []
    }
}
