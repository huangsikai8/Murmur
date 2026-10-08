import ApplicationServices
import Foundation

/// Text already on screen around where the transcript is about to land, read
/// through the accessibility tree so a cleanup pass can spell names the way the
/// document already spells them.
///
/// Measured on this machine with `--testaxtree`, which is why the shape below
/// is what it is:
///
/// * `AXFocusedUIElement` is not the way in. Chrome answered `noValue` 37 times
///   out of 37 in one real session and VS Code answers it the same way, while
///   both publish the focused surface inside their own tree with `AXFocused`
///   set. The tree search is the primary route and the direct question is only
///   a fast path.
/// * The focused element is usually empty. Dictation goes into a chat box, and
///   a chat box holds nothing until you have already typed. The context that
///   matters is the conversation *above* it — 52,857 characters in the VS Code
///   panel, 806 in the ChatGPT app — so an empty field is a reason to widen the
///   read, not to give up.
/// * A browser address bar is deliberately refused. Dictating a search query,
///   the page behind it has nothing to do with what is being searched for, and
///   feeding it in would bias a transcript towards words that happen to be on
///   an unrelated page.
///
/// Everything here is read-only and stays on this Mac.
public enum ScreenContext {

    /// The most text that may be handed to a cleanup model. A panel holds tens
    /// of thousands of characters and a prompt cannot take them; the tail is
    /// what is recent, because accessibility trees follow document order and
    /// chat appends at the end.
    public static let characterBudget = 600

    /// How many elements a single read may visit. The walk happens while
    /// someone is still speaking, so this is a ceiling on a background cost
    /// rather than a latency budget — but an accessibility tree for a loaded
    /// page is tens of thousands of nodes and unbounded is not a size.
    private static let elementBudget = 2500

    /// Roles that publish text worth reading.
    private static let textRoles: Set<String> = [
        kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole,
    ]

    /// Roles whose *own* text is chrome rather than content. A button's label
    /// is "Send", and a transcript spelled to match the buttons around it is
    /// not what anyone meant by context.
    private static let ignoredRoles: Set<String> = [
        kAXButtonRole, kAXMenuItemRole, kAXMenuBarItemRole, kAXMenuRole, kAXPopUpButtonRole,
        kAXCheckBoxRole, kAXRadioButtonRole, kAXToolbarRole, kAXTabGroupRole,
    ]

    /// Titles Chrome and Safari give their address bars. Matched on the
    /// element's own title rather than on the application, so a browser is
    /// refused by what the field *is*, and a text field inside a page — which
    /// is ordinary dictation — is not.
    private static let addressBarTitles: Set<String> = [
        "Address and search bar", "Address", "Smart Search Field", "Search or enter address",
    ]

    /// The result of one read, kept apart from the text so a caller can log
    /// what happened without logging what was on screen.
    public struct Reading: Sendable {
        /// Text to hand to a cleanup model, already trimmed to the budget.
        public let text: String
        /// Where it came from, for the log: "focused field", "panel", or why not.
        public let source: String
        /// The characters immediately before the insertion point, when the
        /// focused element is a field that could be read.
        ///
        /// Separate from `text` because the two answer different questions and
        /// must not be confused: `text` may be a whole conversation harvested
        /// from a panel, which is *not* what sits to the left of the caret.
        /// Only a real field produces a prefix, and only a prefix may decide
        /// capitalization and spacing.
        public let caretPrefix: String?

        public init(text: String, source: String, caretPrefix: String? = nil) {
            self.text = text
            self.source = source
            self.caretPrefix = caretPrefix
        }
    }

    /// How much of the text before the caret is kept. Enough to see the end of
    /// the previous sentence, and no more: this decides one capital and one
    /// space, not what the document is about.
    public static let caretPrefixBudget = 120

    /// Reads context for the application that will receive the transcript.
    ///
    /// Returns `nil` when there is nothing worth sending, which includes an
    /// address bar, an unreadable tree, and a screen holding too little text to
    /// tell a cleanup model anything it does not already know.
    public static func read(target: pid_t?) -> Reading? {
        guard AXIsProcessTrusted(), let target else { return nil }
        let application = AXUIElementCreateApplication(target)

        guard let focused = focusedElement(in: application) else {
            return Reading(text: "", source: "no focused element")
        }

        if isAddressBar(focused) {
            return Reading(text: "", source: "address bar, context refused")
        }

        // The characters to the left of the caret, which decide whether the
        // transcript opens a sentence. Taken whenever the field can be read at
        // all — a two-word prefix is useless as context and is exactly what
        // settles the capital.
        let caret = textBeforeCaret(focused)
        let prefix = caret.map { String($0.suffix(caretPrefixBudget)) }

        // A real editor or a field with something in it: the text before the
        // caret is the best context there is, and needs no walking.
        if let caret, caret.count >= 40 {
            return Reading(
                text: tail(of: caret), source: "focused field", caretPrefix: prefix)
        }

        // Otherwise the field is empty or is a web area standing for a whole
        // panel, and the conversation above it is what to read.
        guard let container = containingSurface(focused) else {
            return Reading(text: "", source: "no readable surface", caretPrefix: prefix)
        }
        let harvested = harvest(container)
        guard harvested.count >= 40 else {
            return Reading(
                text: "", source: "surface held \(harvested.count) characters",
                caretPrefix: prefix)
        }
        return Reading(
            text: tail(of: harvested), source: "surrounding panel", caretPrefix: prefix)
    }

    // MARK: - Finding what to read

    /// The focused element, asking directly first and searching the tree when
    /// that is declined — which, on this machine, is most of the time.
    private static func focusedElement(in application: AXUIElement) -> AXUIElement? {
        var direct: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            application, kAXFocusedUIElementAttribute as CFString, &direct) == .success,
            let value = direct, CFGetTypeID(value) == AXUIElementGetTypeID()
        {
            return (value as! AXUIElement)
        }

        var queue: [AXUIElement] = [application]
        var budget = elementBudget
        while let element = queue.first, budget > 0 {
            queue.removeFirst()
            budget -= 1

            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focused)
                == .success, let flag = focused as? Bool, flag
            {
                return element
            }
            queue.append(contentsOf: children(of: element))
        }
        return nil
    }

    /// Walks up to the nearest surface that stands for a document or a panel,
    /// so the read is scoped to the pane holding the caret. VS Code publishes
    /// twelve web areas at once and the other eleven are a different
    /// conversation entirely.
    private static func containingSurface(_ element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var hops = 0
        while let node = current, hops < 10 {
            if role(of: node) == "AXWebArea" { return node }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent)
                == .success, let value = parent, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { break }
            current = (value as! AXUIElement)
            hops += 1
        }
        // No web area above it: read the element's own subtree, which is what a
        // native application's text view gives.
        return element
    }

    // MARK: - Reading

    /// Text before the insertion point, when the focused element is a genuine
    /// text field that has some.
    ///
    /// Never the whole value: the notes on `ClipboardPasteInserter` say why
    /// reading a large document's text costs more than it is worth, and context
    /// only needs the recent end of it.
    private static func textBeforeCaret(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            == .success, let text = value as? String
        else { return nil }

        var placeholder: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            element, kAXPlaceholderValueAttribute as CFString, &placeholder)

        var caret: Int?
        var selection: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
            let range = selection, CFGetTypeID(range) == AXValueGetTypeID()
        {
            var cfRange = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &cfRange) {
                caret = cfRange.location
            }
        }
        return caretPrefix(value: text, caret: caret, placeholder: placeholder as? String)
    }

    /// What sits before the insertion point, given what a field reports.
    ///
    /// Pure, because every one of its three rules came from a real field
    /// misreporting and each one lowercased somebody's first word in Chrome:
    ///
    /// * An empty chat box in Chrome reports its *placeholder* as its value —
    ///   "Ask anything", "Reply to Claude…" — so a box the speaker sees as empty
    ///   looked like one holding half a sentence. Measured: 23 and 33 characters
    ///   read from boxes with nothing typed in them.
    /// * A caret at position 0 has nothing before it. This used to return the
    ///   whole value instead, which is the same failure by another route.
    /// * No caret position at all means the answer is unknown, not "all of it".
    ///   Unknown returns nil, and nil keeps the capital — a wrong lowercase is
    ///   the visible failure, a missed one is merely today's behaviour.
    public static func caretPrefix(value: String, caret: Int?, placeholder: String?) -> String? {
        if let placeholder, !placeholder.isEmpty, value == placeholder { return "" }
        guard let caret else { return nil }
        guard caret > 0, !value.isEmpty else { return "" }
        return String(value.prefix(min(caret, value.count)))
    }

    /// Collects the text below a surface in document order, stopping at the
    /// budget. Chrome and Electron both publish page content as `AXStaticText`,
    /// so this is the same walk everywhere.
    private static func harvest(_ surface: AXUIElement) -> String {
        var pieces: [String] = []
        var queue: [AXUIElement] = [surface]
        var budget = elementBudget

        while let element = queue.first, budget > 0 {
            queue.removeFirst()
            budget -= 1

            let elementRole = role(of: element) ?? ""
            if !ignoredRoles.contains(elementRole), textRoles.contains(elementRole) {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                    == .success, let text = value as? String
                {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { pieces.append(trimmed) }
                }
            }
            queue.append(contentsOf: children(of: element))
        }
        return pieces.joined(separator: " ")
    }

    /// The last `characterBudget` characters, cut at a word boundary so a
    /// cleanup model is not handed half a word as though it were one.
    public static func tail(of text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > characterBudget else { return collapsed }
        let cut = collapsed.suffix(characterBudget)
        guard let space = cut.firstIndex(of: " ") else { return String(cut) }
        return String(cut[cut.index(after: space)...])
    }


    // MARK: - Tree helpers

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
            == .success
        else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            == .success, let list = value as? [AXUIElement]
        else { return [] }
        return list
    }

    /// Whether this is a browser's address bar, which is refused.
    private static func isAddressBar(_ element: AXUIElement) -> Bool {
        guard role(of: element) == kAXTextFieldRole else { return false }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                let text = value as? String, addressBarTitles.contains(text)
            {
                return true
            }
        }
        return false
    }

    // MARK: - Terms

    /// The words from context that a cleaner may introduce: names, identifiers
    /// and anything that is not ordinary lowercase prose.
    ///
    /// This is the narrow part, and it is narrow on purpose. `CleanupGuard`
    /// rejects a cleaned transcript that contains vocabulary the speaker never
    /// used, which is the check that stops a model rewriting what was said into
    /// what it would rather have heard. Context has to loosen that check to be
    /// useful at all, so it loosens it only for the class of word context can
    /// actually help with — "SpeechAnalyzer", "Murmur", "TDT" — and never for
    /// ordinary words, which is where a conversation's phrasing would otherwise
    /// leak into someone's sentence.
    public static func terms(in context: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for word in context.split(whereSeparator: { $0.isWhitespace }) {
            let token = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard token.count <= 40, token.contains(where: \.isLetter) else { continue }
            // Two characters is enough when one of them is a digit: "M5" and
            // "v2" are exactly the kind of identifier a transcript gets wrong
            // and the screen gets right. Two letters are not — "of", "to" and
            // "In" at the start of a sentence would drag ordinary prose in.
            let hasDigit = token.contains(where: \.isNumber)
            guard token.count >= (hasDigit ? 2 : 3) else { continue }

            let hasInnerCapital = token.dropFirst().contains(where: \.isUppercase)
            let startsCapital = token.first?.isUppercase ?? false
            guard hasInnerCapital || hasDigit || (startsCapital && token.count > 3) else {
                continue
            }
            let key = token.lowercased()
            if seen.insert(key).inserted { terms.append(token) }
        }
        return terms
    }
}
