import Foundation

/// Decides what goes between two utterances inserted back to back.
///
/// In continuous dictation a pause mid-sentence ends one utterance and starts
/// another, so the text arrives as separate pastes. Without a separator they
/// collide — "the meeting" plus "is on Thursday" lands as
/// "the meetingis on Thursday".
///
/// This may only ever add a space *between* two inserted pieces. It never
/// changes either piece, so nothing can put a space inside a word.
public struct UtteranceJoiner {

    /// The last thing inserted, and where. Cleared when the field changes or
    /// continuous dictation stops.
    private var previous: String?
    private var previousTarget: String?

    public init() {}

    /// Punctuation that belongs tight against the preceding word. A recognizer
    /// that resumes with ", and then" must not be pushed away from it.
    private static let hugsPreviousWord: Set<Character> = [
        ",", ".", "!", "?", ";", ":", ")", "]", "}", "%", "\u{2019}", "\u{201D}", "…",
    ]

    /// The separator to place before `next`, which is either empty or a single
    /// space. Call once per insertion, in order.
    public mutating func separator(before next: String, target: String?) -> String {
        defer { record(next, target: target) }
        return pendingSeparator(before: next, target: target)
    }

    /// The separator that *would* be used, recording nothing.
    private func pendingSeparator(before next: String, target: String?) -> String {
        // A different field is a fresh start: its cursor position has nothing
        // to do with what was typed into the last one.
        guard previousTarget == target, let previous, !previous.isEmpty else { return "" }
        guard let last = previous.last, let first = next.first else { return "" }

        if last.isWhitespace || last.isNewline { return "" }
        if first.isWhitespace || first.isNewline { return "" }
        if Self.hugsPreviousWord.contains(first) { return "" }
        return " "
    }

    /// Notes an utterance that has already been written, so the next one is
    /// separated from it correctly.
    public mutating func record(_ text: String, target: String?) {
        previous = text
        previousTarget = target
    }

    /// Forgets the previous utterance, so the next one is treated as a fresh
    /// start. Call when continuous dictation stops.
    public mutating func reset() {
        previous = nil
        previousTarget = nil
    }
}
