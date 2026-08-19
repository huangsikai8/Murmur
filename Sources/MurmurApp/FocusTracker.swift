import AppKit
import ApplicationServices

/// Remembers where dictation started so the transcript lands there.
///
/// Murmur runs as an accessory app and its overlay never becomes key, so focus
/// normally never moves. This is the safety net for the case where something
/// else steals focus mid-dictation.
@MainActor
enum FocusTracker {

    struct Target {
        let application: NSRunningApplication?
        let bundleIdentifier: String?
    }

    static func capture() -> Target {
        let app = NSWorkspace.shared.frontmostApplication
        return Target(application: app, bundleIdentifier: app?.bundleIdentifier)
    }

    /// Brings the original application back to the front if focus moved away.
    /// Returns once the target is frontmost, or immediately if it already is.
    static func restore(_ target: Target) async {
        guard let app = target.application else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier
        else { return }

        app.activate(options: [])
        // Give the window server a moment to make the switch before pasting.
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Accessibility permission

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts for Accessibility access. Needed to observe the hotkey while
    /// other apps are frontmost and to post the paste keystroke.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
