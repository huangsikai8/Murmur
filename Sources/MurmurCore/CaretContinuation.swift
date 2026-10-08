import Foundation

/// How a transcript should join the text already in front of the caret.
///
/// Every engine here capitalizes the first word of what it returns, which is
/// right when dictation starts a sentence and wrong the rest of the time:
/// putting the caret after "and then " and dictating produces "and then We
/// should ship it". Nothing downstream can fix that, because
/// `capitalizeSentences` only ever *adds* capitals and neither it nor the
/// engine has ever been told what is to the left of the insertion point.
///
/// `ScreenContext` now reads that text, so the two decisions it settles are
/// made here: whether the first word opens a sentence, and whether a space is
/// needed so the transcript does not fuse onto the word before it.
///
/// Both are deliberately conservative. An unreadable field means no prefix,
/// which means the old behaviour exactly — a capital and no added space — so a
/// failure to read leaves dictation as it was rather than making it worse.
public enum CaretContinuation {

    /// Characters that end a sentence, so a capital after them is correct.
    ///
    /// A newline counts, for the reason `capitalizeSentences` treats it as one:
    /// a line break opens a sentence, so it has to close one here too.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", ":", ";", "\n"]

    /// Characters that already provide their own separation, so a transcript
    /// following them needs no space of its own.
    private static let openingCharacters: Set<Character> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}", "/", "-", "\u{2014}", "@", "#", "$"]

    /// Adjusts `text` to continue whatever `prefix` left off.
    ///
    /// `prefix` is the text immediately before the insertion point. Empty or
    /// unknown means dictation is treated as starting a sentence, which is what
    /// it did before this existed.
    public static func join(_ text: String, following prefix: String) -> String {
        guard !prefix.isEmpty else { return text }
        let continued = lowercasingOpeningWord(text, following: prefix)
        return needsLeadingSpace(after: prefix, before: continued)
            ? " " + continued : continued
    }

    /// Whether a space has to be inserted so the transcript does not fuse onto
    /// the character before it.
    ///
    /// Only ever *before* the transcript, never inside it: the whole-app
    /// invariant is that nothing may put a space inside a word, and this adds
    /// one between two things that are already separate words.
    public static func needsLeadingSpace(after prefix: String, before text: String) -> Bool {
        guard let last = prefix.last, let first = text.first else { return false }
        // Whitespace already separates them, and so does an opening bracket or
        // quote — "(" wants the word right against it.
        guard !last.isWhitespace, !openingCharacters.contains(last) else { return false }
        // Punctuation that belongs to the preceding word must stay against it,
        // which is the same rule `UtteranceJoiner` follows between utterances.
        guard !first.isWhitespace else { return false }
        guard !isTrailingPunctuation(first) else { return false }
        return true
    }

    /// Punctuation that belongs to the word before it, so a transcript opening
    /// with one is closing the previous sentence rather than starting a new
    /// thing to be spaced away from it.
    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        ",.!?;:)]}\u{201D}\u{2019}%".contains(character)
    }

    /// Lowercases the transcript's first word when the caret sits mid-sentence.
    ///
    /// The word list is `SentenceOpeners.safeToLowercase`, and it is the only
    /// thing standing between a stray capital and somebody's name: a transcript
    /// opening "Sarah said that" is indistinguishable by position from one
    /// opening "Of that day". Wrongly lowercasing a name is worse than leaving
    /// a stray capital, so a word the list does not know keeps its capital.
    public static func lowercasingOpeningWord(
        _ text: String, following prefix: String
    ) -> String {
        // Trailing spaces are skipped, but a newline is not: it ends a sentence
        // here for the same reason it opens one elsewhere.
        guard let ending = prefix.last(where: { $0 != " " && $0 != "\t" }),
            !sentenceTerminators.contains(ending)
        else { return text }

        guard let start = text.firstIndex(where: { !$0.isWhitespace }),
            text[start].isUppercase
        else { return text }

        let word = text[start...].prefix { !$0.isWhitespace }
        // An acronym is not a stray capital, and neither is a bare "I". Both
        // have no lowercase letter after the first, which is the same test.
        guard word.dropFirst().contains(where: \.isLowercase) else { return text }

        let key = word.lowercased().filter { $0.isLetter || $0 == "\u{2019}" || $0 == "'" }
        guard SentenceOpeners.safeToLowercase.contains(key) else { return text }

        return text.replacingCharacters(in: start...start, with: text[start].lowercased())
    }
}
