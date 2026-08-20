import Foundation

/// Spoken phrases that act on the dictation itself rather than becoming text.
///
/// Kept apart from `SpokenFormatter`, which rewrites what you said into how it
/// should be written. These do not produce text at all — they operate on text
/// already inserted — so they have to be recognized before any cleanup runs,
/// while the words are still exactly what came out of the recognizer.
public enum VoiceCommand: Sendable, Equatable {
    /// Take back the last thing inserted.
    case scratchThat

    /// The phrases that retract the previous insertion.
    ///
    /// "Scratch that" is the long-established wording — Dragon and macOS
    /// Dictation both use it — so it is the one people try first. The rest are
    /// what someone reaches for when it does not occur to them.
    /// Includes what the recognizer *actually* produces, not only what was
    /// said. "Scratch that" comes back as "scratched" or a bare "scratch" often
    /// enough that matching the tidy phrase alone makes the command feel
    /// unreliable — and a one-word utterance of "scratch" is not something
    /// anybody dictates as prose, so accepting it costs nothing.
    private static let scratchPhrases: Set<String> = [
        "scratch that",
        "scratch that one",
        "scratch it",
        "scratch",
        "scratched",
        "scratched that",
        "delete that",
        "undo that",
        "forget that",
    ]

    /// The command an utterance *is*, or nil when it is ordinary dictation.
    ///
    /// Matched against the whole utterance and nothing less. A phrase inside a
    /// sentence is someone talking about scratching something, and deleting
    /// their work because they used the words in passing would be far worse
    /// than making them say it on its own.
    public static func parse(_ transcript: String) -> VoiceCommand? {
        scratchPhrases.contains(normalize(transcript)) ? .scratchThat : nil
    }

    /// Lowercased, stripped of the punctuation a recognizer adds on its own.
    ///
    /// The speech model punctuates: "scratch that" arrives as "Scratch that."
    /// and sometimes "Scratch that!". Comparing raw strings would match none of
    /// them, and the command would look broken at random.
    static func normalize(_ text: String) -> String {
        let stripped = text.lowercased().filter { $0.isLetter || $0.isWhitespace }
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
