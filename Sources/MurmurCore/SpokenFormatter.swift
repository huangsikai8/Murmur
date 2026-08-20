import Foundation

/// Deterministic tidy-up applied to every transcript before insertion.
///
/// This is the free layer: pure string work, no model, no measurable delay. It
/// sits below the optional AI correction, which costs seconds and memory.
///
/// Everything here is opt-in per rule, because each rule trades away some
/// literal speech. Saying "comma" can only become "," at the cost of never
/// being able to dictate the word itself, so the rules that rewrite meaning —
/// numbers, currency, lists, markdown — default to off and leave ordinary prose
/// untouched.
public struct SpokenFormatter {

    public struct Options: Sendable, Equatable, Codable {
        /// Master switch. When off, nothing here runs at all.
        public var enabled: Bool
        /// "comma" becomes ",", "new line" becomes a line break.
        public var spokenPunctuation: Bool
        /// Drops "um" and "uh" where they stand alone.
        public var removeFillers: Bool
        /// "twenty twenty six" becomes 2026.
        public var numbers: Bool
        /// "five dollars" becomes $5.
        public var currency: Bool
        /// "bullet buy milk" becomes "- buy milk".
        public var lists: Bool
        /// "heading intro" becomes "# intro".
        public var markdown: Bool

        public init(
            enabled: Bool = true,
            spokenPunctuation: Bool = true,
            removeFillers: Bool = true,
            numbers: Bool = false,
            currency: Bool = false,
            lists: Bool = false,
            markdown: Bool = false
        ) {
            self.enabled = enabled
            self.spokenPunctuation = spokenPunctuation
            self.removeFillers = removeFillers
            self.numbers = numbers
            self.currency = currency
            self.lists = lists
            self.markdown = markdown
        }
    }

    // MARK: - Vocabulary

    /// Spoken punctuation, longest phrase first so "exclamation mark" is not
    /// matched as "exclamation".
    private static let punctuationPhrases: [([String], String)] = [
        (["new", "paragraph"], "\n\n"),
        (["exclamation", "mark"], "!"),
        (["exclamation", "point"], "!"),
        (["question", "mark"], "?"),
        (["full", "stop"], "."),
        (["new", "line"], "\n"),
        (["newline"], "\n"),
        (["semicolon"], ";"),
        (["comma"], ","),
        (["period"], "."),
        (["colon"], ":"),
    ]

    private static let fillers: Set<String> = ["um", "uh", "erm", "uhm", "hmm"]

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    // MARK: - Entry point

    public static func format(_ text: String, options: Options) -> String {
        guard options.enabled else { return text }

        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return text }

        tokens = apply(tokens, options: options)
        let joined = tokens.joined(separator: " ")

        // Spacing is left entirely to the existing normalizer, which may only
        // remove whitespace and already knows which punctuation hugs which
        // side. It is run per line: it treats a newline as collapsible
        // whitespace, so finalizing the whole string would erase the very line
        // breaks "new line" exists to produce.
        let tidied = joined
            .components(separatedBy: "\n")
            .map(TextNormalizer.finalize)
            .joined(separator: "\n")

        return capitalizeSentences(options.markdown ? restoreHeadingSpaces(tidied) : tidied)
    }

    // MARK: - Token rewriting

    private static func apply(_ tokens: [String], options: Options) -> [String] {
        var output: [String] = []
        var index = 0
        var atSegmentStart = true

        while index < tokens.count {
            let token = tokens[index]
            let word = normalized(token)

            if options.markdown, atSegmentStart, word == "heading", index + 1 < tokens.count {
                output.append("#")
                index += 1
                atSegmentStart = false
                continue
            }

            if options.markdown, word == "bold", index + 1 < tokens.count {
                let (wrapped, consumed) = wrapToSegmentEnd(tokens, from: index + 1, with: "**")
                output.append(contentsOf: wrapped)
                index = consumed
                atSegmentStart = false
                continue
            }

            if options.lists, word == "bullet", index + 1 < tokens.count {
                // A bullet only makes sense at the head of its own line.
                if !output.isEmpty, !endsSegment(output.last) { output.append("\n") }
                output.append("-")
                index += 1
                atSegmentStart = false
                continue
            }

            if options.spokenPunctuation,
                let (mark, consumed) = matchPunctuation(tokens, at: index)
            {
                output.append(mark)
                index = consumed
                atSegmentStart = mark.contains("\n") || mark == "." || mark == "!" || mark == "?"
                continue
            }

            if options.currency, let (rendered, consumed) = matchCurrency(tokens, at: index) {
                output.append(rendered)
                index = consumed
                atSegmentStart = false
                continue
            }

            if options.numbers, let (rendered, consumed) = matchNumber(tokens, at: index) {
                // "nineteen august" converts the day and leaves the month as it
                // was heard. A month beside a figure is a date, so it is a
                // proper noun here whatever case the recognizer used.
                if let last = output.last, isMonthWord(last) {
                    output[output.count - 1] = capitalizedMonth(last)
                }
                output.append(rendered)
                index = consumed
                atSegmentStart = false
                continue
            }

            // The mirror case: the figure came first and the month follows it.
            // Only ever beside a figure, because "may" is a verb far more often
            // than it is a month.
            if options.numbers, isMonthWord(token), let last = output.last,
                last.allSatisfy(\.isNumber), !last.isEmpty
            {
                output.append(capitalizedMonth(token))
                atSegmentStart = false
                index += 1
                continue
            }

            if options.removeFillers, fillers.contains(word), isBareWord(token) {
                index += 1
                continue
            }

            output.append(token)
            atSegmentStart = endsSegment(token)
            index += 1
        }
        return output
    }

    /// Wraps everything up to the end of the sentence in `marker`, returning
    /// the wrapped tokens and the index just past them.
    private static func wrapToSegmentEnd(
        _ tokens: [String], from start: Int, with marker: String
    ) -> ([String], Int) {
        var wrapped: [String] = []
        var index = start
        while index < tokens.count {
            wrapped.append(tokens[index])
            index += 1
            if endsSegment(wrapped.last) { break }
        }
        guard !wrapped.isEmpty else { return ([], start) }

        wrapped[0] = marker + wrapped[0]

        // The closing marker goes inside any trailing punctuation, or the
        // emphasis swallows the full stop: "**ship it.**" reads as a mistake.
        let last = wrapped[wrapped.count - 1]
        let trailing = String(last.reversed().prefix(while: { $0.isPunctuation }).reversed())
        let core = String(last.dropLast(trailing.count))
        wrapped[wrapped.count - 1] = core + marker + trailing

        return (wrapped, index)
    }

    // MARK: - Matchers

    private static func matchPunctuation(_ tokens: [String], at index: Int) -> (String, Int)? {
        for (phrase, mark) in punctuationPhrases where phrase.count <= tokens.count - index {
            let slice = tokens[index..<(index + phrase.count)].map(normalized)
            if slice == phrase { return (mark, index + phrase.count) }
        }
        return nil
    }

    /// "five dollars" and "five dollars fifty" become $5 and $5.50.
    private static func matchCurrency(_ tokens: [String], at index: Int) -> (String, Int)? {
        guard let (amount, afterAmount) = readNumber(tokens, from: index) else { return nil }
        guard afterAmount < tokens.count else { return nil }

        let unit = normalized(tokens[afterAmount])
        guard unit == "dollars" || unit == "dollar" else { return nil }

        var cursor = afterAmount + 1
        var cents: Int?
        // "and fifty cents" or the shorthand "fifty".
        var lookahead = cursor
        if lookahead < tokens.count, normalized(tokens[lookahead]) == "and" { lookahead += 1 }
        if let (value, after) = readNumber(tokens, from: lookahead), value < 100 {
            let trailing = after < tokens.count ? normalized(tokens[after]) : ""
            if trailing == "cents" || trailing == "cent" {
                cents = value
                cursor = after + 1
            } else if lookahead == cursor {
                cents = value
                cursor = after
            }
        }

        if let cents {
            return (String(format: "$%d.%02d", amount, cents), cursor)
        }
        return ("$\(amount)", cursor)
    }

    private static func matchNumber(_ tokens: [String], at index: Int) -> (String, Int)? {
        if let (year, after) = readYear(tokens, from: index) { return (String(year), after) }
        guard let (value, after) = readNumber(tokens, from: index) else { return nil }
        // "three point five" is unmistakably a figure however small its whole
        // part is, so it is read before the single-small-word guard below can
        // reject it.
        if let (digits, decimalEnd) = readDecimal(tokens, from: after) {
            return ("\(value).\(digits)", decimalEnd)
        }
        // Every number word becomes a figure, with one exception: a bare
        // "one".
        //
        // "One" is the only number word that is routinely not a number. "One of
        // them", "one of the things", "just one more" — it works as a pronoun,
        // and "1 of the things" reads as a typo. Every other number word,
        // "nineteen" included, is a count when it stands alone. The exception
        // is deliberately narrow: "twenty one" and "one hundred" are compounds
        // and still convert, because there "one" really is arithmetic.
        if after - index == 1, normalized(tokens[index]) == "one" { return nil }
        return (String(value), after)
    }

    private static func isMonthWord(_ token: String) -> Bool {
        monthNames.contains(normalized(token))
    }

    /// Capitalizes the month while leaving any punctuation the recognizer
    /// attached to it — "august," must not become "August" with the comma lost.
    private static func capitalizedMonth(_ token: String) -> String {
        guard let first = token.first, first.isLowercase else { return token }
        return first.uppercased() + token.dropFirst()
    }

    private static func isMonthName(_ tokens: [String], at index: Int) -> Bool {
        guard index >= 0, index < tokens.count else { return false }
        return monthNames.contains(normalized(tokens[index]))
    }

    /// Month names, long and short. A number beside one of these is a date.
    private static let monthNames: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept",
        "oct", "nov", "dec",
    ]

    /// Reads the fractional half of a spoken decimal: "point five" after a
    /// whole number already read, as the digits that follow it.
    ///
    /// Digits are taken one at a time, which is how decimals are spoken —
    /// "three point one four" is 3.14, not 3.14 by way of "fourteen". Only
    /// digit words count, so "point" keeps its ordinary meaning everywhere
    /// else: "a three point turn" has no digit after "point" and is left
    /// exactly as spoken, and so is "at that point I left".
    private static func readDecimal(_ tokens: [String], from index: Int) -> (String, Int)? {
        guard index < tokens.count, normalized(tokens[index]) == "point" else { return nil }

        var cursor = index + 1
        var digits = ""
        while cursor < tokens.count, let digit = decimalDigits[normalized(tokens[cursor])] {
            digits.append(String(digit))
            cursor += 1
        }
        guard !digits.isEmpty else { return nil }
        return (digits, cursor)
    }

    /// Digits usable after a decimal point. "oh" is included because "three
    /// point oh five" is said at least as often as "three point zero five".
    private static let decimalDigits: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    /// "twenty twenty six" and "nineteen eighty four" become 2026 and 1984.
    private static func readYear(_ tokens: [String], from index: Int) -> (Int, Int)? {
        guard index + 1 < tokens.count else { return nil }
        let first = normalized(tokens[index])
        // 1900s come from the teens ("nineteen"), 2000s from a tens word
        // ("twenty"), so both tables have to be consulted.
        let century: Int
        if let teen = units[first], teen >= 10, teen <= 19 {
            century = teen
        } else if let ten = tens[first], ten == 20 {
            century = ten
        } else {
            return nil
        }

        let secondWord = normalized(tokens[index + 1])
        if let teen = units[secondWord], teen >= 10 {
            return (century * 100 + teen, index + 2)
        }
        guard let tensValue = tens[secondWord] else { return nil }

        var total = century * 100 + tensValue
        var cursor = index + 2
        if cursor < tokens.count, let unit = units[normalized(tokens[cursor])], unit < 10 {
            total += unit
            cursor += 1
        }
        return (total, cursor)
    }

    /// Reads a spelled cardinal, returning its value and the index after it.
    private static func readNumber(_ tokens: [String], from index: Int) -> (Int, Int)? {
        var cursor = index
        var total = 0
        var current = 0
        var consumedAny = false
        var sawScale = false

        while cursor < tokens.count {
            let word = normalized(tokens[cursor])
            if let unit = units[word] {
                current += unit
            } else if let ten = tens[word] {
                current += ten
            } else if word == "hundred" {
                current = max(current, 1) * 100
                sawScale = true
            } else if word == "thousand" {
                total += max(current, 1) * 1000
                current = 0
                sawScale = true
            } else if word == "million" {
                total += max(current, 1) * 1_000_000
                current = 0
                sawScale = true
            } else if word == "and", sawScale, cursor + 1 < tokens.count,
                isNumberWord(normalized(tokens[cursor + 1]))
            {
                // "two thousand and sixteen" is one number; "two and three" is
                // not. Only a scale word already read makes the "and" part of
                // the figure rather than a conjunction between two of them.
                cursor += 1
                continue
            } else {
                break
            }
            consumedAny = true
            cursor += 1
        }
        guard consumedAny else { return nil }
        return (total + current, cursor)
    }

    // MARK: - Helpers

    private static func isNumberWord(_ word: String) -> Bool {
        units[word] != nil || tens[word] != nil
            || word == "hundred" || word == "thousand" || word == "million"
    }

    /// Lowercased, stripped of surrounding punctuation, for comparison only.
    private static func normalized(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
    }

    /// True when the token carries no punctuation of its own, so removing it
    /// cannot take a comma or full stop with it.
    private static func isBareWord(_ token: String) -> Bool {
        token.allSatisfy { $0.isLetter }
    }

    private static func endsSegment(_ token: String?) -> Bool {
        guard let last = token?.last else { return false }
        return last == "." || last == "!" || last == "?" || last == "\n"
    }

    /// `TextNormalizer` binds "#" to the word after it, which is correct for a
    /// hashtag and wrong for a markdown heading. Only a leading "#" is a
    /// heading, so only that one gets its space back.
    private static func restoreHeadingSpaces(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line -> String in
                let hashes = line.prefix(while: { $0 == "#" })
                guard !hashes.isEmpty, hashes.count <= 6 else { return line }
                let rest = line.dropFirst(hashes.count)
                guard let first = rest.first, !first.isWhitespace else { return line }
                return hashes + " " + rest
            }
            .joined(separator: "\n")
    }

    /// Capitalizes the first letter of the text and of every sentence after a
    /// terminator. Never changes any other character, so an acronym or a
    /// deliberate lowercase name survives untouched.
    private static func capitalizeSentences(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        out.reserveCapacity(characters.count)
        var startOfSentence = true

        for (index, character) in characters.enumerated() {
            if startOfSentence, character.isLetter || character.isNumber {
                // A digit opens a sentence just as a letter does — otherwise
                // "2000 and I left" capitalizes the "and" because the digits
                // could not be uppercased. Markers like "-", "#" and "*" stay
                // transparent, so a list item or heading capitalizes its first
                // real word.
                startOfSentence = false
                if character.isLetter {
                    out.append(contentsOf: character.uppercased())
                    continue
                }
            }
            if character == "!" || character == "?" || character == "\n" {
                startOfSentence = true
            } else if character == "." {
                // The dot in 45.50 is not a sentence terminator, and treating
                // it as one capitalizes the middle of a sentence.
                let previous = index > 0 ? characters[index - 1] : " "
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                startOfSentence = !(previous.isNumber && next.isNumber)
            }
            out.append(character)
        }
        return out
    }
}
