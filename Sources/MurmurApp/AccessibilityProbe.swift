import AppKit
import ApplicationServices
import Foundation
import MurmurCore

/// `--testaxtree [application name]`: whether an application exposes an
/// accessibility tree at all, and how long it takes to appear after Chromium's
/// opt-in is set.
///
/// This exists because `Murmur.log` says only "unreadable", which is one word
/// for three different failures: the application was never asked, it was asked
/// and refused, or it was asked and had not finished building the tree by the
/// time anything looked. Measured on one real session, Chrome was unreadable 37
/// times out of 37 while VS Code — also Chromium, also Electron — answered with
/// a settable `AXTextArea` 13 times out of 13, so the difference is not the
/// architecture and guessing at it is how an afternoon disappears.
///
/// Nothing here clicks or types. The tree is walked from the application
/// element down, so a focused text field is not required and a browser sitting
/// on a page with no caret in it still gives an answer.
enum AccessibilityProbe {

    /// How long to keep re-querying after the opt-in is set. Chromium builds
    /// the tree asynchronously and a single query immediately afterwards is the
    /// most likely way to conclude "refused" about an application that was
    /// merely still working.
    private static let window: Duration = .seconds(6)
    private static let interval: Duration = .milliseconds(500)

    static func run(applicationName: String?) async -> Int32 {
        guard AXIsProcessTrusted() else {
            print("Murmur is not trusted for Accessibility, so every query here would fail.")
            print("Grant it in System Settings > Privacy & Security > Accessibility.")
            return 1
        }

        let targets = applications(named: applicationName)
        guard !targets.isEmpty else {
            print("No running application matched \(applicationName ?? "the default set").")
            return 1
        }

        print("Murmur accessibility tree probe\n")
        print("Text-bearing roles are what a context feature would read. A tree with")
        print("windows but no such roles is an application exposing its chrome and not")
        print("its content, which is a different answer from exposing nothing.\n")

        var anyReadable = false
        for application in targets {
            let readable = await probe(application)
            anyReadable = anyReadable || readable
        }
        return anyReadable ? 0 : 2
    }

    private static func applications(named name: String?) -> [NSRunningApplication] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.localizedName != nil
        }
        guard let name else {
            // The applications this actually matters for: the ones the logs
            // show dictation going into.
            let wanted = ["Google Chrome", "Code", "Slack", "ChatGPT", "Claude", "Notes"]
            return running.filter { wanted.contains($0.localizedName ?? "") }
        }
        let needle = name.lowercased()
        return running.filter { ($0.localizedName ?? "").lowercased().contains(needle) }
    }

    private static func probe(_ application: NSRunningApplication) async -> Bool {
        let name = application.localizedName ?? "?"
        let element = AXUIElementCreateApplication(application.processIdentifier)
        print("\(name) (pid \(application.processIdentifier))")

        // Before asking, so the difference the opt-in makes is visible rather
        // than assumed. An application that was readable all along says
        // something quite different about the 37 failures in the log.
        let before = survey(element)
        print("  before the opt-in: \(before.summary)")

        let status = AXUIElementSetAttributeValue(
            element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        print("  AXManualAccessibility set: \(describe(status))")

        let start = ContinuousClock.now
        var best = before
        var settled: Duration?
        while ContinuousClock.now - start < window {
            let now = survey(element)
            if now.textRoles > best.textRoles || (now.windows > 0 && best.windows == 0) {
                best = now
                if now.textRoles > 0, settled == nil {
                    settled = ContinuousClock.now - start
                }
            }
            if best.textRoles > 0 { break }
            try? await Task.sleep(for: interval)
        }

        print("  after \(format(ContinuousClock.now - start)): \(best.summary)")
        if let settled {
            print("  text roles appeared \(format(settled)) after the opt-in")
        }

        // The query the inserter actually makes, so the probe and the app agree
        // about the same application.
        let focus = ClipboardPasteInserter.describeFocus(target: application.processIdentifier)
        print("  focused element: \(focus.description)")

        // The distinction the log cannot make. `AXFocusedUIElement` is one
        // question an application may decline while still publishing the very
        // same element inside its tree with `AXFocused` set — which is what
        // Chrome does, and it is the difference between "no context is
        // reachable here" and "ask a different way".
        if let marked = focusedByFlag(element) {
            print("  AXFocused in the tree: \(marked)")
        } else {
            print("  AXFocused in the tree: none found")
        }

        inventoryWebAreas(element)

        let readable = best.textRoles > 0
        print(
            "  verdict: "
                + (readable
                    ? "readable — a context feature could read text here"
                    : "not readable — nothing to read even after asking"))
        print("")
        return readable
    }

    private struct Survey {
        var windows = 0
        var elements = 0
        var textRoles = 0
        var roles: [String: Int] = [:]

        var summary: String {
            guard elements > 0 else { return "no tree at all (0 elements)" }
            let top = roles.sorted { $0.value > $1.value }.prefix(4)
                .map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
            return "\(windows) window(s), \(elements) elements visited, "
                + "\(textRoles) text-bearing — \(top)"
        }
    }

    /// Roles that carry editable or readable text. `AXStaticText` counts: page
    /// content a context feature would read is static text, not a text field.
    private static let textBearing: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXStaticTextRole, "AXWebArea", "AXTextRange",
    ]

    /// Walks the tree breadth-first with a hard budget. An accessibility tree
    /// for a loaded web page is tens of thousands of elements, and the question
    /// here is only whether text is reachable — not what it says.
    private static func survey(_ application: AXUIElement) -> Survey {
        var survey = Survey()
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &windows) == .success,
            let list = windows as? [AXUIElement]
        {
            survey.windows = list.count
        }

        var queue: [AXUIElement] = [application]
        var budget = 4000
        while let element = queue.first, budget > 0 {
            queue.removeFirst()
            budget -= 1
            survey.elements += 1

            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                == .success, let name = role as? String
            {
                survey.roles[name, default: 0] += 1
                if textBearing.contains(name) { survey.textRoles += 1 }
            }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &children) == .success,
                let list = children as? [AXUIElement]
            {
                queue.append(contentsOf: list)
            }
        }
        return survey
    }


    /// Finds the element the application marks `AXFocused`, which is a
    /// different question from `AXFocusedUIElement` and is answered by
    /// applications that decline that one.
    private static func focusedByFlag(_ application: AXUIElement) -> String? {
        var queue: [AXUIElement] = [application]
        var budget = 6000
        while let element = queue.first, budget > 0 {
            queue.removeFirst()
            budget -= 1

            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focused)
                == .success, let flag = focused as? Bool, flag
            {
                var role: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                var characters: CFTypeRef?
                let hasCount = AXUIElementCopyAttributeValue(
                    element, kAXNumberOfCharactersAttribute as CFString, &characters) == .success
                let count = (characters as? Int).map { "\($0) characters" } ?? "no character count"
                // Which surface this is, not only what role it plays. One
                // application can hold an editor and a chat panel that are the
                // same role, the same settability and the same log line, and
                // want opposite context: the document around the caret, or the
                // conversation above an empty field.
                let identity = [
                    attribute(element, kAXTitleAttribute),
                    attribute(element, kAXDescriptionAttribute),
                    attribute(element, kAXPlaceholderValueAttribute),
                    attribute(element, "AXDOMIdentifier"),
                    attribute(element, "AXDOMClassList"),
                ].compactMap { $0 }.joined(separator: " | ")
                let ancestry = ancestorRoles(element)
                return "\(role as? String ?? "?") — \(hasCount ? count : "no character count")"
                    + (identity.isEmpty ? "" : "\n    identity: \(identity)")
                    + "\n    ancestors: \(ancestry)"
            }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &children) == .success,
                let list = children as? [AXUIElement]
            {
                queue.append(contentsOf: list)
            }
        }
        return nil
    }


    /// A non-empty string attribute, or nil. Used to name the surface rather
    /// than describe it.
    private static func attribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let text = value as? String, !text.isEmpty
        else { return nil }
        return "\(name.replacingOccurrences(of: "AX", with: "")): \(text.prefix(60))"
    }

    /// The chain of roles above an element, which is what separates a webview
    /// panel from an editor inside the same process.
    private static func ancestorRoles(_ element: AXUIElement) -> String {
        var roles: [String] = []
        var current: AXUIElement? = element
        var hops = 0
        while let node = current, hops < 8 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent)
                == .success, let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID()
            else { break }
            let element = next as! AXUIElement
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                == .success, let name = role as? String
            {
                roles.append(name)
            }
            current = element
            hops += 1
        }
        return roles.isEmpty ? "none" : roles.joined(separator: " < ")
    }


    /// Every web view in the application, with how much text hangs below it.
    ///
    /// One process can hold several — an editor, a preview, a chat panel — and
    /// they are not interchangeable: a panel whose conversation is exposed is
    /// context, and one that publishes only its own frame is a container with
    /// nothing in it. The count is what separates them, and nothing in
    /// `Murmur.log` has ever distinguished the two.
    private static func inventoryWebAreas(_ application: AXUIElement) {
        var found: [(title: String, texts: Int, characters: Int)] = []
        var queue: [AXUIElement] = [application]
        var budget = 8000
        while let element = queue.first, budget > 0 {
            queue.removeFirst()
            budget -= 1

            var role: CFTypeRef?
            let isWebArea =
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                == .success && (role as? String) == "AXWebArea"

            if isWebArea {
                let title = attribute(element, kAXTitleAttribute) ?? "untitled"
                let harvest = harvestText(element)
                found.append((title, harvest.count, harvest.characters))
            }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &children) == .success,
                let list = children as? [AXUIElement]
            {
                queue.append(contentsOf: list)
            }
        }

        guard !found.isEmpty else {
            print("  web views: none")
            return
        }
        print("  web views: \(found.count)")
        for area in found.sorted(by: { $0.characters > $1.characters }).prefix(6) {
            print("    \(area.texts) text nodes, \(area.characters) characters — \(area.title)")
        }
    }

    /// Reads the text below an element the way a context feature would: static
    /// text and field values only, with a budget, and counting characters
    /// rather than keeping them.
    private static func harvestText(_ root: AXUIElement) -> (count: Int, characters: Int) {
        var nodes = 0
        var characters = 0
        var queue: [AXUIElement] = [root]
        var budget = 3000
        while let element = queue.first, budget > 0 {
            queue.removeFirst()
            budget -= 1

            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                == .success, let text = value as? String, !text.isEmpty
            {
                nodes += 1
                characters += text.count
            }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &children) == .success,
                let list = children as? [AXUIElement]
            {
                queue.append(contentsOf: list)
            }
        }
        return (nodes, characters)
    }

    private static func format(_ duration: Duration) -> String {
        String(format: "%.1f s", Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18)
    }

    private static func describe(_ status: AXError) -> String {
        switch status {
        case .success: "success"
        case .attributeUnsupported: "attributeUnsupported (not a Chromium application)"
        case .cannotComplete: "cannotComplete"
        case .notImplemented: "notImplemented"
        default: "\(status.rawValue)"
        }
    }
}
