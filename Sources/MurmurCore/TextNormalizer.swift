import Foundation

/// Punctuation-safe assembly of streamed transcript chunks.
///
/// Design rule that makes word-splitting corruption (`act ually`, `beca use`)
/// structurally impossible: this type **never inserts whitespace inside a chunk**.
/// It may only
///   * insert a single space *at a boundary between two chunks*, and
///   * remove or collapse whitespace that is already present.
///
/// Because a recognizer only ever finalizes at word/phrase granularity, a
/// boundary can never fall inside a word, so no rule here can split one.
public enum TextNormalizer {

    /// Punctuation that must hug the preceding word: no space before it.
    static let closingPunctuation: Set<Character> = [
        ",", ".", "!", "?", ";", ":", "%", ")", "]", "}",
        "'", "\u{2019}", "\u{201D}", "\u{2026}",
    ]

    /// Punctuation that must hug the following word: no space after it.
    static let openingPunctuation: Set<Character> = ["(", "[", "{", "\u{201C}", "$", "#", "@"]

    /// Appends `chunk` to `accumulated`, inserting a separator only when the
    /// boundary genuinely needs one.
    public static func join(_ accumulated: String, _ chunk: String) -> String {
        if accumulated.isEmpty {
            // Leading whitespace on the very first chunk is noise.
            return String(chunk.drop(while: { $0.isWhitespace }))
        }
        guard let incoming = chunk.first else { return accumulated }
        guard let trailing = accumulated.last else { return chunk }

        // Either side already supplies the separator.
        if trailing.isWhitespace || incoming.isWhitespace { return accumulated + chunk }
        // Punctuation binds to the word before it.
        if closingPunctuation.contains(incoming) { return accumulated + chunk }
        // An opening bracket/symbol binds to the word after it.
        if openingPunctuation.contains(trailing) { return accumulated + chunk }

        return accumulated + " " + chunk
    }

    /// Single tidy pass applied once, immediately before insertion.
    ///
    /// Only ever *removes* whitespace, never adds any, so it cannot introduce a
    /// space into the middle of a word or a decimal number.
    public static func finalize(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)

        var pendingSpace = false
        var lastEmitted: Character?

        for character in text {
            if character.isWhitespace {
                // Collapse any run of whitespace; drop it outright at the start.
                if lastEmitted != nil { pendingSpace = true }
                continue
            }

            if pendingSpace {
                let hugsPrevious = closingPunctuation.contains(character)
                let previousHugsNext = lastEmitted.map(openingPunctuation.contains) ?? false
                if !hugsPrevious && !previousHugsNext { out.append(" ") }
                pendingSpace = false
            }

            out.append(character)
            lastEmitted = character
        }
        return out
    }
}
