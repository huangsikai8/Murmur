import Foundation
import MurmurCore

/// `Murmur --testformatting` — shows what the deterministic pass does to a set
/// of spoken phrases, with every rule enabled.
///
/// The rules trade literal speech for formatting, so being able to see the
/// trade on one screen matters more here than a pass/fail number.
enum FormattingTest {

    private static let phrases = [
        "hello comma world period",
        "is it ready question mark",
        "first line new line second line",
        "um so uh the report is done",
        "it was twenty twenty six",
        "back in nineteen eighty four",
        "about twenty five people",
        "it cost five dollars",
        "it cost five dollars and fifty cents",
        "two thousand and sixteen",
        "one hundred and five",
        "I ate twenty and thirty",
        "bullet buy milk",
        "heading intro",
        "bold ship it",
        // Prose that must survive every rule untouched.
        "one of the things I wanted to mention",
        "I paid $45.50 for it, which is 12.5% more than before.",
    ]

    static func run() async -> Int32 {
        print("Murmur formatting pass\n")

        var options = SpokenFormatter.Options()
        options.numbers = true
        options.currency = true
        options.lists = true
        options.markdown = true

        var defaults = SpokenFormatter.Options()
        defaults.enabled = true

        print("With every rule on:")
        for phrase in phrases {
            show(phrase, SpokenFormatter.format(phrase, options: options))
        }

        print("\nWith the shipped defaults (numbers, currency, lists, markdown off):")
        for phrase in phrases {
            show(phrase, SpokenFormatter.format(phrase, options: defaults))
        }
        // This layer sits in the path of every utterance, so its cost has to
        // be known rather than assumed.
        let sample = phrases.joined(separator: " ")
        let start = ContinuousClock.now
        let runs = 1000
        for _ in 0..<runs { _ = SpokenFormatter.format(sample, options: options) }
        let each = (ContinuousClock.now - start) / .microseconds(1) / Double(runs)
        print(
            "\nCost: \(String(format: "%.0f", each)) µs for "
                + "\(sample.split(separator: " ").count) words, every rule on.")
        print("")
        return 0
    }

    private static func show(_ input: String, _ output: String) {
        let rendered = output.replacingOccurrences(of: "\n", with: "\\n")
        print("  \"\(input)\"")
        print("    → \"\(rendered)\"")
    }
}
