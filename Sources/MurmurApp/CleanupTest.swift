import Foundation
import MurmurCore

/// `Murmur --testcleanup` — runs sample transcripts through every level.
enum CleanupTest {

    /// Deliberately messy: fillers, false starts, repetition, and a question
    /// that must come back as a question rather than being answered.
    static let samples = [
        "um so like i think we should uh move the meeting to thursday maybe",
        "okay so the the thing is that i i wanted to say that the report is "
            + "basically done um but i still need to check the numbers",
        "can you move the meeting to thursday afternoon",
        "is the dictation cleanup engine working correctly",
        "hey can you tell me what the weather is like today",
        "Hello, I'm testing this feature.",
    ]

    /// Sentences where the recognizer produced a homophone of a custom term.
    /// The pair is (what the recognizer wrote, what the speaker meant).
    static let homophoneSamples: [(String, String)] = [
        ("i asked cloud to review my code", "should become Claude"),
        ("i stored the file in the cloud", "must stay cloud"),
        ("open vs coat and check the terminal", "should become VS Code"),
        ("he wore a nice coat to the meeting", "must stay coat"),
    ]

    static func runHomophones() async -> Int32 {
        print("Murmur homophone disambiguation test\n")
        if let reason = FoundationModelsCleaner.unavailableReason {
            print("Cleanup model unavailable: \(reason)")
            return 1
        }

        let cleaner = FoundationModelsCleaner()
        try? await cleaner.prepare()
        await cleaner.setProtectedVocabulary([
            VocabularyTerm("Claude", soundsLike: ["cloud", "clawed"]),
            VocabularyTerm("VS Code", soundsLike: ["vs coat", "vscoat"]),
        ])

        for (input, expectation) in homophoneSamples {
            print("INPUT   \(input)")
            print("        (\(expectation))")
            for level in [CleanupLevel.light, .medium, .high] {
                do {
                    let cleaned = try await cleaner.clean(input, level: level)
                    print("  \(level.displayName.padding(toLength: 7, withPad: " ", startingAt: 0))\(cleaned)")
                } catch {
                    print("  \(level.displayName): FAILED \(error.localizedDescription)")
                }
            }
            print("")
        }
        return 0
    }

    /// Runs the samples through a downloadable MLX model instead of Apple's.
    ///
    /// A model that reasons is measured twice, with and without `/no_think`,
    /// back to back on the same weights. Run separately the two arms would be
    /// compared across different machine states — and on a 16 GB machine
    /// cycling 4B models, swap pressure moves the absolute numbers by more
    /// than the effect being measured.
    static func runMLX(modelID: String) async -> Int32 {
        guard let variant = MLXCleaner.Variant.from(modelID: modelID) else {
            print("Not an MLX model: \(modelID)")
            return 1
        }
        guard MLXCleaner.isInstalled(variant) else {
            print("Not downloaded. Run: Murmur --download \(modelID)")
            return 1
        }

        print("Murmur cleanup test — \(variant.repositoryID)\n")
        let arms: [(String, MLXCleaner.Reasoning)] =
            variant.reasons
            ? [("reasoning", .allowed), ("/no_think", .suppressed)]
            : [("", .allowed)]

        for (label, reasoning) in arms {
            if !label.isEmpty { print("═══ \(label) ═══\n") }
            print("loading weights…")
            let cleaner = MLXCleaner(variant: variant, reasoning: reasoning)
            let start = ContinuousClock.now
            do {
                try await cleaner.prepare()
            } catch {
                print("FAILED to load: \(error.localizedDescription)")
                return 1
            }
            print("Model loaded in \(ms(since: start)) ms\n")

            for sample in samples.prefix(3) {
                print("INPUT   \(sample)")
                for level in [CleanupLevel.light, .high] {
                    let levelStart = ContinuousClock.now
                    do {
                        let result = try await cleaner.cleanDetailed(sample, level: level)
                        let elapsed = ms(since: levelStart)
                        let name = level.displayName.padding(
                            toLength: 7, withPad: " ", startingAt: 0)
                        print("  \(name)\(result.accepted)")
                        if let stats = result.stats { print("          \(describe(stats))") }
                        // The raw reply is only worth printing when it differs
                        // from what was accepted: that is where a stripped
                        // <think> block, or a guard rejection, becomes visible.
                        if result.raw != result.accepted {
                            print("          [raw] \(condense(result.raw))")
                        }
                        print("          (\(elapsed) ms)")
                    } catch {
                        print("  \(level.displayName): FAILED \(error.localizedDescription)")
                    }
                }
                print("")
            }
            await cleaner.releaseModels()
        }
        return 0
    }

    /// One line of generation cost, with the reasoning share called out.
    private static func describe(_ stats: MLXCleaner.Stats) -> String {
        var line =
            "[gen] \(stats.generatedTokens) tok in \(stats.generateMs) ms "
            + "(\(String(format: "%.1f", stats.tokensPerSecond)) tok/s), "
            + "prompt \(stats.promptTokens) tok in \(stats.promptMs) ms"
        if stats.thinkingCharacters > 0 {
            let share = Double(stats.thinkingCharacters) / Double(max(stats.replyCharacters, 1))
            line += " — \(Int(share * 100))% of the reply was <think>"
        }
        return line
    }

    /// Keeps a long reasoning block readable on one screen without hiding
    /// whether it ever closed.
    private static func condense(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > 300 else { return flat }
        return flat.prefix(200) + " …[\(flat.count) chars]… " + flat.suffix(80)
    }

    static func run() async -> Int32 {
        print("Murmur cleanup test\n")

        if let reason = FoundationModelsCleaner.unavailableReason {
            print("Cleanup model unavailable: \(reason)")
            return 1
        }

        let cleaner = FoundationModelsCleaner()
        let start = ContinuousClock.now
        try? await cleaner.prepare()
        print("Model warm in \(ms(since: start)) ms\n")

        for sample in samples {
            print("INPUT   \(sample)")
            for level in CleanupLevel.allCases where level != .off {
                let levelStart = ContinuousClock.now
                do {
                    let result = try await cleaner.cleanDetailed(sample, level: level)
                    let elapsed = ms(since: levelStart)
                    let label = level.displayName.padding(toLength: 7, withPad: " ", startingAt: 0)
                    print("  \(label)\(result.accepted)")
                    if result.raw != result.accepted {
                        print("          [guard rejected model output: \(result.raw)]")
                    }
                    print("          (\(elapsed) ms)")
                } catch {
                    print("  \(level.displayName): FAILED \(error.localizedDescription)")
                }
            }
            print("")
        }

        await runSteadyState(cleaner)
        return 0
    }

    /// Times the samples at one fixed level, back to back, twice.
    ///
    /// The pass above walks every level for each input, which is what you want
    /// when judging output quality but not when judging speed: the app sits at
    /// one level for a whole session, so a session prepared for the next
    /// utterance is always the right one. Alternating levels defeats that and
    /// makes every call pay a prefill no real session pays. The second lap is
    /// the number to read — by then the pipeline is in the state it is in
    /// during ordinary use.
    private static func runSteadyState(_ cleaner: FoundationModelsCleaner) async {
        let level = CleanupLevel.medium
        print("═══ steady state — \(level.displayName), consecutive ═══\n")

        for lap in 1...2 {
            var timings: [Int] = []
            for sample in samples {
                let start = ContinuousClock.now
                _ = try? await cleaner.clean(sample, level: level)
                timings.append(ms(since: start))
            }
            guard !timings.isEmpty else { continue }
            let mean = timings.reduce(0, +) / timings.count
            print(
                "lap \(lap): mean \(mean) ms, min \(timings.min() ?? 0) ms, "
                    + "max \(timings.max() ?? 0) ms  \(timings.map(String.init).joined(separator: " "))")
        }
        print("")
    }

    private static func ms(since instant: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - instant) / .milliseconds(1))
    }
}
