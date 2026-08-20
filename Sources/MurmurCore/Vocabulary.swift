import Foundation

/// A term Murmur should recognize and spell your way.
public struct VocabularyTerm: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: String { text.lowercased() }

    /// Canonical spelling, exactly as it should be inserted. "VS Code", "Claude".
    public var text: String

    /// What the recognizer mishears this as. "Claude" often arrives as "cloud".
    /// These are corrected using surrounding context, not blind replacement.
    public var soundsLike: [String]

    /// Replace `soundsLike` matches unconditionally, without weighing context.
    /// Off by default: "cloud" is a real word, and forcing it would corrupt
    /// "stored it in the cloud".
    public var alwaysReplace: Bool

    public init(_ text: String, soundsLike: [String] = [], alwaysReplace: Bool = false) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.soundsLike =
            soundsLike
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.alwaysReplace = alwaysReplace
    }

    // Decoding tolerates word lists saved before these fields existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        soundsLike = try container.decodeIfPresent([String].self, forKey: .soundsLike) ?? []
        alwaysReplace =
            try container.decodeIfPresent(Bool.self, forKey: .alwaysReplace) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case text, soundsLike, alwaysReplace
    }
}

/// Your custom word list, persisted between launches.
public final class VocabularyStore: @unchecked Sendable {

    public static let shared = VocabularyStore()

    private let defaultsKey = "murmur.vocabulary"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var storage: [VocabularyTerm]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([VocabularyTerm].self, from: data) {
            storage = decoded
        } else {
            storage = []
        }
    }

    public var terms: [VocabularyTerm] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Just the strings, for handing to the recognizer and the cleanup model.
    public var phrases: [String] {
        terms.map(\.text)
    }

    /// All terms, for callers that need aliases as well as spellings.
    public var allTerms: [VocabularyTerm] { terms }

    @discardableResult
    public func add(_ text: String, soundsLike: [String] = [], alwaysReplace: Bool = false) -> Bool {
        let term = VocabularyTerm(text, soundsLike: soundsLike, alwaysReplace: alwaysReplace)
        guard !term.text.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        // Case-insensitive de-duplication: one spelling per term.
        guard !storage.contains(where: { $0.id == term.id }) else { return false }
        storage.append(term)
        persist()
        return true
    }

    public func remove(_ term: VocabularyTerm) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll { $0.id == term.id }
        persist()
    }

    /// Replaces one term in place, matched on its canonical spelling.
    public func update(_ term: VocabularyTerm) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.firstIndex(where: { $0.id == term.id }) else { return }
        storage[index] = term
        persist()
    }

    public func replaceAll(with terms: [VocabularyTerm]) {
        lock.lock()
        defer { lock.unlock() }
        storage = terms
        persist()
    }

    /// Caller already holds the lock.
    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// Rewrites recognized text to your preferred spelling of your own terms.
///
/// Two different jobs, deliberately kept apart:
///  * canonical spelling is always enforced, because "vscode" and "VS Code" are
///    the same word and only the casing differs;
///  * a misheard homophone is only replaced when you explicitly ask for it,
///    because "cloud" is a real word and rewriting it blindly would corrupt
///    "stored it in the cloud".
public enum VocabularyNormalizer {

    /// Applies canonical spelling, plus homophone replacement for any term
    /// marked `alwaysReplace`.
    public static func apply(_ terms: [VocabularyTerm], to text: String) -> String {
        var replacements: [(match: String, canonical: String)] = []
        for term in terms where !term.text.isEmpty {
            replacements.append((term.text, term.text))
            if term.alwaysReplace {
                for alternate in term.soundsLike {
                    replacements.append((alternate, term.text))
                }
            }
        }
        return applyReplacements(replacements, to: text)
    }

    /// Canonical spelling only, for callers holding plain strings.
    public static func apply(_ phrases: [String], to text: String) -> String {
        applyReplacements(phrases.map { ($0, $0) }, to: text)
    }

    /// Longest match first, so "VS Code" wins over a separate "Code" entry.
    private static func applyReplacements(
        _ replacements: [(match: String, canonical: String)],
        to text: String
    ) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        let ordered =
            replacements
            .map {
                (
                    match: $0.match.trimmingCharacters(in: .whitespacesAndNewlines),
                    canonical: $0.canonical
                )
            }
            .filter { !$0.match.isEmpty }
            .sorted { $0.match.count > $1.match.count }

        for replacement in ordered {
            guard let expression = expression(for: replacement.match) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement.canonical)
            )
        }
        return result
    }

    /// Word-bounded, case-insensitive, with optional whitespace between the
    /// parts of a multi-word term.
    ///
    /// Cached, because this runs once per term on every single insertion and a
    /// term's pattern never changes. Compiling the whole word list again for
    /// each utterance was pure repeat work on the path between the speaker
    /// finishing and the text landing.
    static func expression(for phrase: String) -> NSRegularExpression? {
        if let cached = cache.lookup(phrase) { return cached }
        guard let built = buildExpression(for: phrase) else { return nil }
        cache.store(built, for: phrase)
        return built
    }

    /// Compiled patterns, keyed by the phrase they were built from. The word
    /// list is user-sized, so this holds a handful of entries at most.
    private static let cache = ExpressionCache()

    private final class ExpressionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: NSRegularExpression] = [:]

        func lookup(_ phrase: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            return storage[phrase]
        }

        func store(_ expression: NSRegularExpression, for phrase: String) {
            lock.lock()
            defer { lock.unlock() }
            storage[phrase] = expression
        }
    }

    private static func buildExpression(for phrase: String) -> NSRegularExpression? {
        let parts = phrase.split(whereSeparator: \.isWhitespace)
        guard !parts.isEmpty else { return nil }

        let body =
            parts
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s*")

        // Word boundaries only work next to word characters; fall back to a
        // plain match for terms that start or end with punctuation.
        let leading = parts.first?.first?.isLetter == true || parts.first?.first?.isNumber == true
        let trailing = parts.last?.last?.isLetter == true || parts.last?.last?.isNumber == true
        let pattern = (leading ? "\\b" : "") + body + (trailing ? "\\b" : "")

        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
