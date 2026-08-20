import Foundation

/// Side-by-side comparison of several transcripts of the *same* audio.
///
/// When one recording is decoded by several models, the useful information is
/// not any single transcript but the handful of words they disagree about.
/// This aligns them and marks exactly those, so a comparison is read by looking
/// at three words rather than three paragraphs.
///
/// There is no ground truth here — nobody typed out what was really said — so
/// nothing in this file scores a model as right or wrong. It reports only where
/// the models differ, and leaves the judgement to whoever is reading.
public enum TranscriptDiff {

    /// One word, and whether every transcript agreed on it.
    public struct Token: Sendable, Equatable {
        public let text: String
        /// False when at least one transcript did not match this word. These
        /// are the only places worth reading.
        public let agrees: Bool

        public init(text: String, agrees: Bool) {
            self.text = text
            self.agrees = agrees
        }
    }

    public struct Row: Sendable, Equatable {
        public let label: String
        public let tokens: [Token]

        public init(label: String, tokens: [Token]) {
            self.label = label
            self.tokens = tokens
        }

        public var text: String { tokens.map(\.text).joined(separator: " ") }
        public var disagreements: Int { tokens.count { !$0.agrees } }
    }

    public struct Entry: Sendable, Equatable {
        public let label: String
        public let text: String

        public init(label: String, text: String) {
            self.label = label
            self.text = text
        }
    }

    public struct Comparison: Sendable, Equatable {
        public let rows: [Row]
        /// The transcript the others were aligned against.
        public let backbone: String
        /// Total words, across every row, that some other row did not match.
        public var disagreements: Int { rows.reduce(0) { $0 + $1.disagreements } }
        public var unanimous: Bool { disagreements == 0 }

        public init(rows: [Row], backbone: String) {
            self.rows = rows
            self.backbone = backbone
        }
    }

    /// Aligns every entry against the most representative one and marks the
    /// words that are contested. Row order is preserved, so the caller's
    /// bubbles stay where the reader put them.
    public static func compare(_ entries: [Entry]) -> Comparison {
        guard !entries.isEmpty else { return Comparison(rows: [], backbone: "") }

        let words = entries.map { tokenize($0.text) }
        let keys = words.map { $0.map(normalized) }

        // A single transcript has nothing to disagree with, and comparing it
        // against itself would mark an empty one as unanimous either way.
        guard entries.count > 1 else {
            let row = Row(
                label: entries[0].label,
                tokens: words[0].map { Token(text: $0, agrees: true) })
            return Comparison(rows: [row], backbone: entries[0].text)
        }

        let backbone = backboneIndex(of: keys)
        let backboneKey = keys[backbone]

        // How many rows matched each backbone word, and where each row's own
        // words landed against it.
        var backboneMatches = [Int](repeating: 0, count: backboneKey.count)
        var alignment = [[Int: Int]](repeating: [:], count: entries.count)

        for index in entries.indices where index != backbone {
            for (backbonePosition, rowPosition) in lcs(backboneKey, keys[index]) {
                backboneMatches[backbonePosition] += 1
                alignment[index][rowPosition] = backbonePosition
            }
        }

        // A position is contested unless *every* transcript matched it.
        // Requiring only a majority would quietly hide a word that one model
        // heard differently, which is the case this exists to surface.
        let others = entries.count - 1
        let contested = backboneMatches.map { $0 < others }

        var rows: [Row] = []
        for index in entries.indices {
            let tokens = words[index].enumerated().map { position, word -> Token in
                if index == backbone {
                    return Token(text: word, agrees: !contested[position])
                }
                // A word that matched the backbone still counts as contested
                // when some *other* row disagreed there. Marking the whole
                // column, rather than only the rows that differ, keeps the
                // disputed word in one place down the page instead of making
                // the majority look unanimous and the minority look broken.
                guard let backbonePosition = alignment[index][position] else {
                    return Token(text: word, agrees: false)
                }
                return Token(text: word, agrees: !contested[backbonePosition])
            }
            rows.append(Row(label: entries[index].label, tokens: tokens))
        }

        return Comparison(rows: rows, backbone: entries[backbone].text)
    }

    // MARK: - Alignment

    /// The entry sharing the most words with all the others.
    ///
    /// Taking the first entry, or the longest, would let one outlier model
    /// define what "agreement" means and paint every other row as wrong.
    private static func backboneIndex(of keys: [[String]]) -> Int {
        var best = 0
        var bestScore = -1
        for (index, key) in keys.enumerated() {
            var score = 0
            for (other, otherKey) in keys.enumerated() where other != index {
                score += lcs(key, otherKey).count
            }
            if score > bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }

    /// Longest common subsequence, as the pairs of positions that matched.
    ///
    /// A subsequence rather than a windowed comparison because models drop and
    /// insert words as well as substitute them: one engine hearing an extra
    /// "the" must not knock every following word out of alignment.
    private static func lcs(_ left: [String], _ right: [String]) -> [(Int, Int)] {
        guard !left.isEmpty, !right.isEmpty else { return [] }

        var table = [[Int]](
            repeating: [Int](repeating: 0, count: right.count + 1), count: left.count + 1)
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                table[i][j] =
                    left[i] == right[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < left.count, j < right.count {
            if left[i] == right[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    // MARK: - Tokens

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Compared loosely on purpose: a model that writes "Thursday." where
    /// another writes "Thursday" heard the same word, and flagging that as a
    /// disagreement would bury the one place the models really differ.
    /// Punctuation is still shown, because it is displayed from the original.
    private static func normalized(_ token: String) -> String {
        token.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .filter { !$0.isPunctuation }
    }
}
