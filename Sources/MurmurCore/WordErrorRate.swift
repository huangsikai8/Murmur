import Foundation

/// Word error rate of a transcript against the text that was actually read.
///
/// `TranscriptDiff` compares models with each other, which can say where they
/// disagree but never which one is right. With a reference this can:
/// substitutions, insertions and deletions over the reference's word count, the
/// standard measure for speech recognition.
///
/// Words are compared lowercased with punctuation dropped, because a model's
/// punctuation and capitals are not what is being scored, and a hyphen splits,
/// so "follow-up" and "follow up" agree.
public enum WordErrorRate {

    public struct Result: Sendable, Equatable {
        public let referenceWords: Int
        public let errors: Int
        /// The hypothesis with every error marked: `⟨ref→hyp⟩` substituted,
        /// `⟨+hyp⟩` inserted, `⟨−ref⟩` missing.
        public let marked: String

        public var rate: Double {
            referenceWords > 0 ? Double(errors) / Double(referenceWords) : 0
        }
    }

    /// The words a transcript is scored on.
    public static func words(_ text: String) -> [String] {
        let spaced = text.lowercased().map { $0 == "-" || $0 == "/" ? " " : $0 }
        let kept = String(spaced).filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        return kept.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func measure(reference: String, hypothesis: String) -> Result {
        let expected = words(reference)
        let heard = words(hypothesis)

        // Edit distance over words, kept whole so the alignment can be read back.
        var distance = Array(
            repeating: Array(repeating: 0, count: heard.count + 1), count: expected.count + 1)
        for i in 0...expected.count { distance[i][0] = i }
        for j in 0...heard.count { distance[0][j] = j }
        for i in stride(from: 1, through: expected.count, by: 1) {
            for j in stride(from: 1, through: heard.count, by: 1) {
                let substitution = distance[i - 1][j - 1] + (expected[i - 1] == heard[j - 1] ? 0 : 1)
                distance[i][j] = min(substitution, distance[i - 1][j] + 1, distance[i][j - 1] + 1)
            }
        }

        var marks: [String] = []
        var i = expected.count
        var j = heard.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, expected[i - 1] == heard[j - 1],
                distance[i][j] == distance[i - 1][j - 1]
            {
                marks.append(heard[j - 1])
                i -= 1
                j -= 1
            } else if i > 0, j > 0, distance[i][j] == distance[i - 1][j - 1] + 1 {
                marks.append("⟨\(expected[i - 1])→\(heard[j - 1])⟩")
                i -= 1
                j -= 1
            } else if j > 0, distance[i][j] == distance[i][j - 1] + 1 {
                marks.append("⟨+\(heard[j - 1])⟩")
                j -= 1
            } else {
                marks.append("⟨−\(expected[i - 1])⟩")
                i -= 1
            }
        }

        return Result(
            referenceWords: expected.count,
            errors: distance[expected.count][heard.count],
            marked: marks.reversed().joined(separator: " "))
    }

    /// How many times a phrase appears as whole words, on the same terms a
    /// transcript is scored on. A vocabulary term spelled as one word where it
    /// is two ("VSCode") does not count: that spelling is the error.
    public static func occurrences(of phrase: String, in text: String) -> Int {
        let needle = words(phrase)
        let haystack = words(text)
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var count = 0
        var index = 0
        while index + needle.count <= haystack.count {
            if Array(haystack[index..<(index + needle.count)]) == needle {
                count += 1
                index += needle.count
            } else {
                index += 1
            }
        }
        return count
    }
}
