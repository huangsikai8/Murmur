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
        print("loading weights…")
        let cleaner = MLXCleaner(variant: variant)
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
                    let label = level.displayName.padding(
                        toLength: 7, withPad: " ", startingAt: 0
                    )
                    print("  \(label)\(result.accepted)")
                    if result.raw != result.accepted {
                        print("          [guard rejected: \(result.raw)]")
                    }
                    print("          (\(ms(since: levelStart)) ms)")
                } catch {
                    print("  \(level.displayName): FAILED \(error.localizedDescription)")
                }
            }
            print("")
        }
        return 0
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
        return 0
    }

    private static func ms(since instant: ContinuousClock.Instant) -> Int {
        Int(Double((ContinuousClock.now - instant).components.attoseconds) / 1e15)
    }
}
