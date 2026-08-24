import AVFoundation
import AppKit
import Foundation
import MurmurCore

/// The sentences that must survive the pipeline byte-for-byte.
let referenceSentences: [String] = [
    "Hello, I'm testing this feature.",
    "Okay, it actually displays correctly.",
    "Yes, I think you've got the issue right.",
    "Can you move the meeting to Thursday afternoon?",
    "Today, I'm testing this feature.",
    "I paid $45.50 for it, which is 12.5% more than before.",
    "It's because the feature works correctly now.",
]

let runner = TestRunner()

// MARK: - Transcript fidelity

runner.suite("Transcript fidelity")

await runner.test("finalize leaves well-formed text alone") {
    for sentence in referenceSentences {
        runner.expectEqual(TextNormalizer.finalize(sentence), sentence)
    }
}

// Guard against `act ually` and `beca use`.
await runner.test("word-by-word streaming reconstructs exactly") {
    for sentence in referenceSentences {
        var buffer = TranscriptBuffer()
        for word in sentence.split(separator: " ") {
            buffer.apply(text: String(word), isFinal: true)
        }
        runner.expectEqual(buffer.finalText, sentence)
    }
}

// Recognizers usually emit chunks with a leading space; that must not double up.
await runner.test("leading-space chunks reconstruct exactly") {
    for sentence in referenceSentences {
        var buffer = TranscriptBuffer()
        for (index, word) in sentence.split(separator: " ").enumerated() {
            buffer.apply(text: index == 0 ? String(word) : " " + word, isFinal: true)
        }
        runner.expectEqual(buffer.finalText, sentence)
    }
}

await runner.test("every whitespace-boundary chunk split reconstructs exactly") {
    for sentence in referenceSentences {
        let characters = Array(sentence)
        for splitIndex in 1..<characters.count where characters[splitIndex] == " " {
            var buffer = TranscriptBuffer()
            buffer.apply(text: String(characters[0..<splitIndex]), isFinal: true)
            buffer.apply(text: String(characters[splitIndex...]), isFinal: true)
            runner.expectEqual(buffer.finalText, sentence, "split at index \(splitIndex)")
        }
    }
}

await runner.test("no space is left before closing punctuation") {
    var buffer = TranscriptBuffer()
    buffer.apply(text: "this feature", isFinal: true)
    buffer.apply(text: ".", isFinal: true)
    runner.expectEqual(buffer.finalText, "this feature.")

    runner.expectEqual(TextNormalizer.finalize("feature ."), "feature.")
    runner.expectEqual(TextNormalizer.finalize("Today , I'm here"), "Today, I'm here")
    runner.expectEqual(TextNormalizer.finalize("really ?"), "really?")
    runner.expectEqual(TextNormalizer.finalize("wait ; then go"), "wait; then go")
}

await runner.test("runs of whitespace collapse to a single space") {
    runner.expectEqual(TextNormalizer.finalize("Hello,   I'm  testing"), "Hello, I'm testing")
    runner.expectEqual(TextNormalizer.finalize("  leading and trailing  "), "leading and trailing")
    runner.expectEqual(TextNormalizer.finalize("line\nbreak"), "line break")
}

// Adding whitespace is what would split a word or a decimal number.
await runner.test("finalize never adds whitespace") {
    let inputs =
        referenceSentences + [
            "3.14159", "version2.0", "e.g.", "U.S.A.", "actually", "because", "correctly",
        ]
    for input in inputs {
        let output = TextNormalizer.finalize(input)
        runner.expect(
            output.filter(\.isWhitespace).count <= input.filter(\.isWhitespace).count,
            "finalize added whitespace to \"\(input)\""
        )
        runner.expectEqual(
            String(output.filter { !$0.isWhitespace }),
            String(input.filter { !$0.isWhitespace }),
            "non-whitespace content changed for \"\(input)\""
        )
    }
}

await runner.test("known corruption patterns are not produced") {
    var buffer = TranscriptBuffer()
    for word in ["Okay,", "it", "actually", "displays", "correctly."] {
        buffer.apply(text: word, isFinal: true)
    }
    let result = buffer.finalText
    for corruption in ["act ually", "cor rectly", "feature .", "beca use", "displa ys"] {
        runner.expect(!result.contains(corruption), "produced \"\(corruption)\"")
    }
    runner.expectEqual(result, "Okay, it actually displays correctly.")
}

await runner.test("volatile results replace rather than duplicate") {
    var buffer = TranscriptBuffer()
    buffer.apply(text: "Can you move", isFinal: false)
    buffer.apply(text: "Can you move the", isFinal: false)
    buffer.apply(text: "Can you move the meeting", isFinal: false)
    runner.expectEqual(buffer.liveText, "Can you move the meeting")

    buffer.apply(text: "Can you move the meeting", isFinal: true)
    runner.expectEqual(buffer.finalText, "Can you move the meeting")
    runner.expectEqual(buffer.liveText, "Can you move the meeting")
}

await runner.test("interleaved final and volatile results do not duplicate phrases") {
    var buffer = TranscriptBuffer()
    buffer.apply(text: "Hello,", isFinal: true)
    buffer.apply(text: "I'm test", isFinal: false)
    buffer.apply(text: "I'm testing", isFinal: false)
    buffer.apply(text: "I'm testing this feature.", isFinal: true)
    runner.expectEqual(buffer.finalText, "Hello, I'm testing this feature.")
}

await runner.test("volatile text is excluded from the final output") {
    var buffer = TranscriptBuffer()
    buffer.apply(text: "Hello, I'm testing this feature.", isFinal: true)
    buffer.apply(text: "and this was never confirmed", isFinal: false)
    runner.expectEqual(buffer.finalText, "Hello, I'm testing this feature.")
}

await runner.test("reset clears everything") {
    var buffer = TranscriptBuffer()
    buffer.apply(text: "something", isFinal: true)
    buffer.apply(text: "pending", isFinal: false)
    buffer.reset()
    runner.expect(buffer.isEmpty, "buffer was not empty after reset")
    runner.expectEqual(buffer.finalText, "")
}

// MARK: - Insertion

runner.suite("Insertion")

await runner.test("the inserter receives the exact string") {
    for sentence in referenceSentences {
        var buffer = TranscriptBuffer()
        for word in sentence.split(separator: " ") {
            buffer.apply(text: String(word), isFinal: true)
        }
        let inserter = RecordingInserter()
        try inserter.insert(buffer.finalText)
        runner.expectEqual(inserter.inserted, [sentence])
    }
}

await runner.test("an empty transcript is never pasted") {
    let pasteboard = NSPasteboard(name: .init("murmur.test.empty"))
    pasteboard.clearContents()
    pasteboard.setString("original", forType: .string)

    let counter = Counter()
    let inserter = ClipboardPasteInserter(
        pasteboard: pasteboard,
        restoreDelay: 0.01,
        paste: { counter.increment() }
    )
    try inserter.insert("")

    runner.expectEqual(counter.value, 0)
    runner.expectEqual(pasteboard.string(forType: .string), "original")
}

await runner.test("the transcript is on the pasteboard when paste fires") {
    // nonisolated(unsafe): the paste closure is @Sendable, and this pasteboard
    // is touched only from this test.
    nonisolated(unsafe) let pasteboard = NSPasteboard(name: .init("murmur.test.timing"))
    let sentence = "Hello, I'm testing this feature."

    let observed = Box()
    let inserter = ClipboardPasteInserter(
        pasteboard: pasteboard,
        restoreDelay: 5.0,
        paste: { observed.value = pasteboard.string(forType: .string) }
    )
    try inserter.insert(sentence)
    runner.expectEqual(observed.value, sentence)
}

// One pasteboard value means the text cannot arrive as fragments.
await runner.test("the transcript is written atomically") {
    let pasteboard = NSPasteboard(name: .init("murmur.test.atomic"))
    let sentence = "Yes, I think you've got the issue right."

    let counter = Counter()
    let inserter = ClipboardPasteInserter(
        pasteboard: pasteboard,
        restoreDelay: 5.0,
        paste: { counter.increment() }
    )
    try inserter.insert(sentence)

    runner.expectEqual(counter.value, 1, "pasted in more than one operation")
    runner.expectEqual(pasteboard.pasteboardItems?.count, 1)
    runner.expectEqual(pasteboard.string(forType: .string), sentence)
}

await runner.test("the previous clipboard is restored afterwards") {
    let pasteboard = NSPasteboard(name: .init("murmur.test.restore"))
    pasteboard.clearContents()
    pasteboard.setString("user's original clipboard", forType: .string)

    let inserter = ClipboardPasteInserter(
        pasteboard: pasteboard, restoreDelay: 0.05, paste: {}, canReceiveText: { _ in .acceptsText })
    try inserter.insert("Okay, it actually displays correctly.")
    runner.expectEqual(
        pasteboard.string(forType: .string),
        "Okay, it actually displays correctly."
    )

    try await Task.sleep(for: .milliseconds(400))
    runner.expectEqual(pasteboard.string(forType: .string), "user's original clipboard")
}

await runner.test("restore is skipped when the clipboard changed meanwhile") {
    let pasteboard = NSPasteboard(name: .init("murmur.test.contested"))
    pasteboard.clearContents()
    pasteboard.setString("old clipboard", forType: .string)

    let inserter = ClipboardPasteInserter(
        pasteboard: pasteboard, restoreDelay: 0.2, paste: {}, canReceiveText: { _ in .acceptsText })
    try inserter.insert("transcript text")

    // The user copies something during the restore window.
    pasteboard.clearContents()
    pasteboard.setString("user copied this", forType: .string)

    try await Task.sleep(for: .milliseconds(600))
    runner.expectEqual(pasteboard.string(forType: .string), "user copied this")
}

await runner.test("all clipboard types are preserved, not just plain text") {
    let pasteboard = NSPasteboard(name: .init("murmur.test.types"))
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString("plain text", forType: .string)
    item.setString("<b>rich</b>", forType: .html)
    pasteboard.writeObjects([item])

    let inserter = ClipboardPasteInserter(
        pasteboard: pasteboard, restoreDelay: 0.05, paste: {}, canReceiveText: { _ in .acceptsText })
    try inserter.insert("dictated sentence")

    try await Task.sleep(for: .milliseconds(400))
    runner.expectEqual(pasteboard.string(forType: .string), "plain text")
    runner.expectEqual(pasteboard.string(forType: .html), "<b>rich</b>")
}

// Dictating with nothing focused used to lose the sentence outright: the
// transcript went onto the clipboard, the paste landed nowhere, and the restore
// put the old clipboard back over it a third of a second later.
await runner.test("with nothing focused the transcript stays on the clipboard") {
    let pasteboard = NSPasteboard(name: .init("murmur.test.fallback"))
    pasteboard.clearContents()
    pasteboard.setString("user's original clipboard", forType: .string)

    let inserter = ClipboardPasteInserter(
        pasteboard: pasteboard, restoreDelay: 0.05, paste: {}, canReceiveText: { _ in .rejectsText })
    let outcome = try inserter.insert("the sentence that had nowhere to go")
    runner.expectEqual(outcome, .leftOnClipboard)

    // Well past the restore delay: the transcript must still be there.
    try await Task.sleep(for: .milliseconds(400))
    runner.expectEqual(
        pasteboard.string(forType: .string), "the sentence that had nowhere to go")
}

// The system-wide AXFocusedUIElement query fails outright on macOS 26, and
// reading that failure as "nothing focused" made the card claim the text had
// only been copied while the paste was landing normally.
await runner.test("unreadable focus pastes, keeps a copy, and claims nothing") {
    let pasteboard = NSPasteboard(name: .init("murmur.test.unknownfocus"))
    pasteboard.clearContents()
    pasteboard.setString("user's original clipboard", forType: .string)

    let inserter = ClipboardPasteInserter(
        pasteboard: pasteboard, restoreDelay: 0.05, paste: {}, canReceiveText: { _ in .unknown })
    runner.expectEqual(try inserter.insert("the sentence that did land"), .pastedUnverified)

    try await Task.sleep(for: .milliseconds(400))
    runner.expectEqual(pasteboard.string(forType: .string), "the sentence that did land")
}

await runner.test("a focused field reports pasted and restores the clipboard") {
    let pasteboard = NSPasteboard(name: .init("murmur.test.outcome"))
    pasteboard.clearContents()
    pasteboard.setString("original", forType: .string)

    let inserter = ClipboardPasteInserter(
        pasteboard: pasteboard, restoreDelay: 0.05, paste: {}, canReceiveText: { _ in .acceptsText })
    runner.expectEqual(try inserter.insert("landed"), .pasted)

    try await Task.sleep(for: .milliseconds(400))
    runner.expectEqual(pasteboard.string(forType: .string), "original")
}

runner.suite("Voice commands")

await runner.test("scratch that is recognized however the recognizer punctuates it") {
    for spoken in ["scratch that", "Scratch that.", "SCRATCH THAT!", "  scratch   that  "] {
        runner.expectEqual(
            VoiceCommand.parse(spoken), .scratchThat, "not recognized: \(spoken)")
    }
    // What the recognizer really returns, which is not always what was said.
    runner.expectEqual(VoiceCommand.parse("Scratched."), .scratchThat)
    runner.expectEqual(VoiceCommand.parse("Scratch!"), .scratchThat)
    runner.expectEqual(VoiceCommand.parse("delete that"), .scratchThat)
    runner.expectEqual(VoiceCommand.parse("undo that"), .scratchThat)
}

// Deleting is destructive, so the phrase has to be the whole utterance. Someone
// talking about scratching something must never lose their last sentence.
await runner.test("the phrase inside a sentence is not a command") {
    runner.expectEqual(
        VoiceCommand.parse("I had to scratch that idea completely"), nil)
    runner.expectEqual(VoiceCommand.parse("scratch that plan and start again"), nil)
    runner.expectEqual(VoiceCommand.parse("we should delete that file"), nil)
    runner.expectEqual(VoiceCommand.parse("ordinary dictation"), nil)
    runner.expectEqual(VoiceCommand.parse(""), nil)
}

await runner.test("a retraction removes exactly what was inserted") {
    let inserter = RecordingInserter()
    let sentence = "This is the sentence I regret."
    try inserter.insert(sentence)
    try inserter.deleteBackward(count: sentence.count)

    runner.expectEqual(inserter.inserted, [sentence])
    runner.expectEqual(inserter.deletions, [sentence.count])
}

// MARK: - Cleanup safety

runner.suite("Cleanup guard")

// The realistic failure: the model answers the dictation instead of tidying it.
await runner.test("a chat reply is rejected in favour of the original") {
    let original = "Hello, I'm testing this feature."
    let chatReply = "Hello! I'm here to help with any questions or tasks you have. "
        + "What can I assist you with today?"
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: chatReply, level: .high),
        original
    )
}

await runner.test("an answered question is rejected") {
    let original = "Can you move the meeting to Thursday afternoon?"
    let answer = "Sure, I can help with that. I have moved your meeting to Thursday "
        + "afternoon and notified all attendees of the change."
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: answer, level: .medium),
        original
    )
}

await runner.test("a genuine cleanup is accepted") {
    let original = "um so like i think we should uh move the meeting to thursday maybe"
    let cleaned = "So I think we should move the meeting to Thursday, maybe."
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: cleaned, level: .light),
        cleaned
    )
}

// High is allowed to compress rambling that Light must not.
await runner.test("high tolerates compression that light rejects") {
    let original = "okay so the the thing is that i i wanted to say that the report "
        + "is basically done um but i still need to check the numbers"
    let compressed = "The report is basically done, but I still need to check the numbers."
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: compressed, level: .high),
        compressed
    )
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: compressed, level: .light),
        original
    )
}

await runner.test("empty or whitespace output falls back to the original") {
    let original = "Hello, I'm testing this feature."
    runner.expectEqual(CleanupGuard.accept(original: original, cleaned: "", level: .light), original)
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: "   \n ", level: .light),
        original
    )
}

await runner.test("off always returns the original untouched") {
    let original = "um so i think we should go"
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: "So I think we should go.", level: .off),
        original
    )
}

await runner.test("a short utterance is not allowed to become a paragraph") {
    let original = "yes exactly"
    let rambling = "Yes, exactly! That is a great point and I completely agree with "
        + "your assessment of the situation as described."
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: rambling, level: .medium),
        original
    )
    // A plausible tidy of the same phrase still passes.
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: "Yes, exactly.", level: .medium),
        "Yes, exactly."
    )
}

await runner.test("cleanup output is trimmed of stray whitespace") {
    let original = "um so i think we should go to the meeting now"
    runner.expectEqual(
        CleanupGuard.accept(
            original: original,
            cleaned: "  So I think we should go to the meeting now.  ",
            level: .light
        ),
        "So I think we should go to the meeting now."
    )
}

await runner.test("every level has non-empty instructions and a summary") {
    for level in CleanupLevel.allCases {
        runner.expect(!level.instructions.isEmpty, "\(level) has no instructions")
        runner.expect(!level.summary.isEmpty, "\(level) has no summary")
        runner.expect(!level.displayName.isEmpty, "\(level) has no display name")
    }
    // Every level must forbid answering the text.
    for level in CleanupLevel.allCases {
        runner.expect(
            level.instructions.contains("Never answer"),
            "\(level) does not forbid answering the dictation"
        )
    }
}

// The exact failure seen in real use: the model answered the dictation.
await runner.test("a refusal reply is rejected (reported real-world failure)") {
    let original = "is the dictation cleanup engine working correctly"
    let refusal = "I'm sorry, but I cannot provide feedback on whether the "
        + "dictation cleanup engine is working correctly."
    for level in [CleanupLevel.light, .medium, .high] {
        runner.expectEqual(
            CleanupGuard.accept(original: original, cleaned: refusal, level: level),
            original,
            "level \(level) let a refusal through"
        )
    }
}

await runner.test("assistant openers are rejected at every level") {
    let original = "so i think we should probably ship this on friday afternoon"
    let replies = [
        "Sure, I can help with that! Here is what I suggest for your schedule.",
        "I'd be happy to help you plan the release for Friday afternoon.",
        "As an AI, I cannot make scheduling decisions for your team.",
        "Here's the corrected version: we should ship this on Friday.",
        "I'm unable to assist with that particular request right now.",
    ]
    for reply in replies {
        for level in [CleanupLevel.light, .medium, .high] {
            runner.expectEqual(
                CleanupGuard.accept(original: original, cleaned: reply, level: level),
                original,
                "let through: \(reply)"
            )
        }
    }
}

// The speaker's own words must not trip the reply detector.
await runner.test("the speaker saying sorry is not mistaken for a refusal") {
    let original = "um i'm sorry i cannot make it to the meeting on thursday"
    let cleaned = "I'm sorry, I cannot make it to the meeting on Thursday."
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: cleaned, level: .light),
        cleaned
    )
}

await runner.test("vocabulary the speaker never used is rejected") {
    let original = "lets move the standup to nine thirty tomorrow morning"
    let invented = "The synchronization ceremony has been rescheduled to "
        + "half past nine on the following calendar day."
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: invented, level: .high),
        original
    )
}

await runner.test("word overlap is computed on content words") {
    runner.expectEqual(
        CleanupGuard.wordOverlap(
            original: "move the meeting to thursday",
            cleaned: "Move the meeting to Thursday."
        ),
        1.0
    )
    runner.expect(
        CleanupGuard.wordOverlap(
            original: "move the meeting to thursday",
            cleaned: "I cannot provide feedback about your calendar request."
        ) < 0.5,
        "unrelated text scored too high"
    )
}

// MARK: - Vocabulary

runner.suite("Custom vocabulary")

await runner.test("a term is spelled the user's way regardless of casing") {
    let terms = ["VS Code", "Claude", "Anthropic"]
    runner.expectEqual(
        VocabularyNormalizer.apply(terms, to: "I use vs code every day."),
        "I use VS Code every day."
    )
    runner.expectEqual(
        VocabularyNormalizer.apply(terms, to: "claude helped me with this."),
        "Claude helped me with this."
    )
    runner.expectEqual(
        VocabularyNormalizer.apply(terms, to: "I work at anthropic."),
        "I work at Anthropic."
    )
}

// The recognizer often runs a two-word term together.
await runner.test("a run-together spelling is corrected") {
    runner.expectEqual(
        VocabularyNormalizer.apply(["VS Code"], to: "open vscode please"),
        "open VS Code please"
    )
    runner.expectEqual(
        VocabularyNormalizer.apply(["GitHub"], to: "push it to github"),
        "push it to GitHub"
    )
}

// The whole point of word boundaries: never rewrite inside another word.
await runner.test("a term inside a longer word is left alone") {
    runner.expectEqual(
        VocabularyNormalizer.apply(["Code"], to: "please encode the video"),
        "please encode the video"
    )
    runner.expectEqual(
        VocabularyNormalizer.apply(["Claude"], to: "the clauded version"),
        "the clauded version"
    )
    runner.expectEqual(
        VocabularyNormalizer.apply(["AI"], to: "I said again"),
        "I said again"
    )
}

await runner.test("a longer term wins over a shorter overlapping one") {
    runner.expectEqual(
        VocabularyNormalizer.apply(["VS Code", "Code"], to: "open vs code now"),
        "open VS Code now"
    )
}

await runner.test("punctuation around a term survives untouched") {
    runner.expectEqual(
        VocabularyNormalizer.apply(["VS Code"], to: "Open vscode, then quit."),
        "Open VS Code, then quit."
    )
    runner.expectEqual(
        VocabularyNormalizer.apply(["Claude"], to: "Is claude working?"),
        "Is Claude working?"
    )
}

await runner.test("text is untouched when the list is empty") {
    let sentence = "Hello, I'm testing this feature."
    runner.expectEqual(VocabularyNormalizer.apply([String](), to: sentence), sentence)
    runner.expectEqual(VocabularyNormalizer.apply(["Xyzzy"], to: sentence), sentence)
}

// The normalizer must not reintroduce the corruption the rest of the app prevents.
await runner.test("normalizing never corrupts the reference sentences") {
    let terms = ["VS Code", "Claude", "GitHub", "Anthropic"]
    for sentence in referenceSentences {
        runner.expectEqual(VocabularyNormalizer.apply(terms, to: sentence), sentence)
    }
}

await runner.test("the store de-duplicates case-insensitively and persists") {
    let defaults = UserDefaults(suiteName: "murmur.test.vocab.\(UUID().uuidString)")!
    let store = VocabularyStore(defaults: defaults)
    runner.expect(store.add("VS Code"), "first add should succeed")
    runner.expect(!store.add("vs code"), "duplicate should be rejected")
    runner.expectEqual(store.terms.count, 1)
    runner.expectEqual(store.phrases, ["VS Code"])

    // A fresh store over the same defaults must see the saved term.
    let reloaded = VocabularyStore(defaults: defaults)
    runner.expectEqual(reloaded.phrases, ["VS Code"])

    reloaded.remove(VocabularyTerm("VS CODE"))
    runner.expectEqual(reloaded.terms.count, 0)
}

await runner.test("blank entries are refused") {
    let defaults = UserDefaults(suiteName: "murmur.test.vocab.\(UUID().uuidString)")!
    let store = VocabularyStore(defaults: defaults)
    runner.expect(!store.add("   "), "whitespace should be refused")
    runner.expectEqual(store.terms.count, 0)
}

runner.suite("Homophone repair")

// Repairing a misheard term necessarily introduces a word the recognizer never
// produced. The guard must not mistake that for the model inventing text.
await runner.test("a known term is not treated as invented vocabulary") {
    let original = "i asked cloud to review my code"
    let repaired = "I asked Claude to review my code."
    for level in [CleanupLevel.light, .medium, .high] {
        runner.expectEqual(
            CleanupGuard.accept(
                original: original, cleaned: repaired, level: level, knownTerms: ["Claude"]
            ),
            repaired,
            "level \(level) rejected a legitimate term repair"
        )
    }
}

// Without the term registered, the same substitution is still suspicious.
await runner.test("an unknown substitution is still rejected at light") {
    let original = "i asked cloud to review my code"
    let altered = "I asked Barbara to review my documentation."
    runner.expectEqual(
        CleanupGuard.accept(original: original, cleaned: altered, level: .light),
        original
    )
}

await runner.test("known terms do not weaken the refusal detector") {
    let original = "is the dictation cleanup engine working correctly"
    let refusal = "I'm sorry, but I cannot provide feedback on whether the "
        + "dictation cleanup engine is working correctly."
    runner.expectEqual(
        CleanupGuard.accept(
            original: original, cleaned: refusal, level: .high, knownTerms: ["Claude", "VS Code"]
        ),
        original
    )
}

await runner.test("a homophone is only force-replaced when asked for") {
    let cautious = VocabularyTerm("Claude", soundsLike: ["cloud"])
    let forced = VocabularyTerm("Claude", soundsLike: ["cloud"], alwaysReplace: true)

    // Default: context decides, so the deterministic pass leaves "cloud" alone.
    runner.expectEqual(
        VocabularyNormalizer.apply([cautious], to: "I stored the file in the cloud."),
        "I stored the file in the cloud."
    )
    // Opt in, and every occurrence is rewritten regardless of meaning.
    runner.expectEqual(
        VocabularyNormalizer.apply([forced], to: "I asked cloud to review it."),
        "I asked Claude to review it."
    )
}

await runner.test("canonical spelling still applies without force-replace") {
    let term = VocabularyTerm("VS Code", soundsLike: ["vs coat"])
    runner.expectEqual(
        VocabularyNormalizer.apply([term], to: "open vscode now"),
        "open VS Code now"
    )
    // The homophone is left for the language model to judge.
    runner.expectEqual(
        VocabularyNormalizer.apply([term], to: "he wore a vs coat"),
        "he wore a vs coat"
    )
}

await runner.test("word lists saved before aliases existed still decode") {
    let legacy = Data(#"[{"text":"Claude"}]"#.utf8)
    let decoded = try JSONDecoder().decode([VocabularyTerm].self, from: legacy)
    runner.expectEqual(decoded.count, 1)
    runner.expectEqual(decoded.first?.text, "Claude")
    runner.expectEqual(decoded.first?.soundsLike ?? ["unset"], [])
    runner.expectEqual(decoded.first?.alwaysReplace, false)
}

// MARK: - Input level meter

runner.suite("Input level meter")

// The meter is the only feedback a batch engine gives while you hold the key,
// and it used to map -50 dB to 0 dB — full scale, which dictation never
// reaches. A normal voice sits around -30 dBFS, so speech and an empty room
// both landed in the middle of the range and looked alike.
await runner.test("speech and silence land at opposite ends of the meter") {
    func rms(dBFS: Float) -> Float { pow(10, dBFS / 20) }

    let silence = AudioCapture.loudness(ofRMS: rms(dBFS: -60))
    let room = AudioCapture.loudness(ofRMS: rms(dBFS: -50))
    let speech = AudioCapture.loudness(ofRMS: rms(dBFS: -25))
    let loud = AudioCapture.loudness(ofRMS: rms(dBFS: -18))

    // A quiet room must be flat, not merely low: the meter twitching at an
    // empty room is what "too sensitive" looks like, and it reads as the app
    // hearing something that is not there.
    runner.expectEqual(silence, 0, "silence should sit on the floor")
    runner.expectEqual(room, 0, "a quiet room moved the meter to \(room)")
    runner.expectEqual(speech > 0.5, true, "ordinary speech only reached \(speech)")
    runner.expectEqual(loud > 0.85, true, "raised voice only reached \(loud)")
}

await runner.test("the curve never falls as the input gets louder") {
    var previous: Float = -1
    for dBFS in stride(from: Float(-70), through: 0, by: 2) {
        let level = AudioCapture.loudness(ofRMS: pow(10, dBFS / 20))
        runner.expectEqual(level >= previous, true, "level fell at \(dBFS) dBFS")
        runner.expectEqual(level >= 0 && level <= 1, true, "level out of range at \(dBFS) dBFS")
        previous = level
    }
}

// MARK: - Spectrum meter

runner.suite("Spectrum analyser")

// The bars are only worth drawing if they mean something. A tone must light
// the band that contains it and leave the others alone — the failure this
// catches is a bin/band mapping that is off, which looks plausible on screen
// because a wrong band still moves with your voice.
await runner.test("a tone lands in the band that contains it") {
    let sampleRate = 16000.0
    let analyser = SpectrumAnalyser()

    func bands(ofToneAt hertz: Double) -> [Float] {
        let count = 512
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            samples[index] = 0.5 * Float(sin(2 * Double.pi * hertz * Double(index) / sampleRate))
        }
        // Twice, because the analyser attacks instantly but is smoothed: one
        // pass is enough for the peak and this proves it holds.
        _ = samples.withUnsafeBufferPointer {
            analyser.bands(of: $0.baseAddress!, count: count, sampleRate: sampleRate)
        }
        return samples.withUnsafeBufferPointer {
            analyser.bands(of: $0.baseAddress!, count: count, sampleRate: sampleRate)
        }
    }

    // A band's own edges say where it should land, so the test cannot drift
    // apart from the implementation it is checking.
    for band in [2, 6, 10] {
        let (low, high) = SpectrumAnalyser.edges(of: band)
        let centre = (low * high).squareRoot()
        let measured = bands(ofToneAt: centre)
        let loudest = measured.firstIndex(of: measured.max() ?? 0) ?? -1
        runner.expectEqual(
            loudest, band,
            "a \(Int(centre)) Hz tone lit band \(loudest), not \(band)")
    }
}

await runner.test("bands cover speech and rise in frequency") {
    let first = SpectrumAnalyser.edges(of: 0)
    let last = SpectrumAnalyser.edges(of: SpectrumAnalyser.bandCount - 1)
    runner.expectEqual(first.low, 80)
    runner.expectEqual(Int(last.high.rounded()), 8000)

    var previous = 0.0
    for band in 0..<SpectrumAnalyser.bandCount {
        let (low, high) = SpectrumAnalyser.edges(of: band)
        runner.expectEqual(low > previous, true, "band \(band) does not start above the last")
        runner.expectEqual(high > low, true, "band \(band) has no width")
        previous = low
    }
}

await runner.test("silence produces no bands at all") {
    let analyser = SpectrumAnalyser()
    let silence = [Float](repeating: 0, count: 512)
    let bands = silence.withUnsafeBufferPointer {
        analyser.bands(of: $0.baseAddress!, count: 512, sampleRate: 16000)
    }
    runner.expectEqual(bands.count, SpectrumAnalyser.bandCount)
    runner.expectEqual(bands.allSatisfy { $0 == 0 }, true, "silence moved the meter: \(bands)")
}

// MARK: - Whisper invents words on silence

runner.suite("Whisper silence guard")

// Measured with `--testsilence` on Large v3 Turbo: digital silence returns
// "you", and room tone returns ".", while Apple's recognizer returns nothing
// for the same four cases. WhisperKit cannot stop it — its `noSpeechProb` is
// hardcoded to 0 with a TODO, so `noSpeechThreshold` compares 0 against 0.6
// forever — so the guard has to live here.
await runner.test("punctuation-only output carries no words") {
    runner.expectEqual(WhisperEngine.carriesWords("."), false)
    runner.expectEqual(WhisperEngine.carriesWords("..."), false)
    runner.expectEqual(WhisperEngine.carriesWords(" , "), false)
    runner.expectEqual(WhisperEngine.carriesWords("Hi."), true)
    runner.expectEqual(WhisperEngine.carriesWords("2016"), true)
}

await runner.test("stock fillers are dropped only when the audio was too quiet") {
    // Quieter than any voice: invented.
    runner.expectEqual(WhisperEngine.isInventedSilence("Thank you.", peak: -55), true)
    runner.expectEqual(WhisperEngine.isInventedSilence("you", peak: -50), true)
    runner.expectEqual(WhisperEngine.isInventedSilence("Thanks for watching!", peak: -44), true)

    // Loud enough to have been spoken: kept, or thanking someone out loud
    // would be deleted.
    runner.expectEqual(WhisperEngine.isInventedSilence("Thank you.", peak: -25), false)
    runner.expectEqual(WhisperEngine.isInventedSilence("Thank you.", peak: -30), false)

    // Only whole transcripts. These words inside a sentence are somebody
    // actually speaking, at any level.
    runner.expectEqual(
        WhisperEngine.isInventedSilence("Thank you for the review.", peak: -55), false)
    runner.expectEqual(WhisperEngine.isInventedSilence("Can you check this?", peak: -55), false)
}

await runner.test("peak loudness follows the loudest moment, not the average") {
    let sampleRate = 16000.0
    // A second of silence with 100 ms of speech in it is an utterance, and
    // averaging would bury it.
    var samples = [Float](repeating: 0, count: Int(sampleRate))
    for index in 0..<Int(sampleRate * 0.1) {
        samples[index] = index.isMultiple(of: 2) ? 0.1 : -0.1
    }
    let peak = WhisperEngine.peakDecibels(samples, sampleRate: sampleRate)
    runner.expectEqual(peak > -25, true, "a spoken burst measured only \(peak) dBFS")

    let quiet = WhisperEngine.peakDecibels(
        [Float](repeating: 0, count: Int(sampleRate)), sampleRate: sampleRate)
    runner.expectEqual(quiet < -100, true, "digital silence measured \(quiet) dBFS")
}

// MARK: - Whisper over a hold longer than one window

runner.suite("Whisper long holds")

// Whisper decodes a fixed 30-second window, and WhisperKit walks a longer
// recording by seeking to the last timestamp it was given. Asked to decode
// without timestamps, `SegmentSeeker` has nothing to seek by and falls back to
// `seek += segmentSize`, jumping a whole window — so whatever the decoder
// stopped short of inside that window is dropped. Measured on Large v3 Turbo
// over 57 s, 92 s and 171 s of speech: a clause went missing at every boundary,
// and returned the moment timestamps were on. Nothing else in the app reads a
// timestamp, so this flag looks free to turn off and is not.
await runner.test("the decoder is asked for timestamps") {
    runner.expectEqual(WhisperEngine.decodesWithTimestamps, true)
}

// The price of the line above: with timestamps on the model also emits its
// captioning annotations, as ordinary text that `skipSpecialTokens` never sees.
await runner.test("non-speech annotations are removed") {
    for annotation in [
        "[BLANK_AUDIO]", "[ Silence ]", "[MUSIC PLAYING]", "(applause)",
        "[Laughter]", "[inaudible]", "(coughs)", "[BLANK _ AUDIO]",
    ] {
        runner.expectEqual(
            WhisperEngine.stripNonSpeechAnnotations("Hello there. " + annotation).trimmingCharacters(
                in: .whitespaces),
            "Hello there.", "\(annotation) survived")
    }
}

await runner.test("an annotation mid-transcript leaves the words either side") {
    let stripped = WhisperEngine.stripNonSpeechAnnotations(
        "with nothing unusual in it. [BLANK_AUDIO] The second marker word.")
    runner.expectEqual(
        TextNormalizer.finalize(stripped),
        "with nothing unusual in it. The second marker word.")
}

// The brackets alone must never be the test: `SpokenFormatter` has no rule that
// produces one, so a bracket in a transcript is either the model annotating or
// the speaker dictating, and punctuation cannot tell those apart.
await runner.test("bracketed text the speaker dictated is kept") {
    for kept in [
        "Ship it [TODO: check the date] tomorrow.",
        "The array is items[0] and items[1].",
        "Call foo(bar) when ready.",
        "See the note (the one from Tuesday) below.",
        "A stray [ bracket that never closes",
    ] {
        runner.expectEqual(WhisperEngine.stripNonSpeechAnnotations(kept), kept)
    }
}

await runner.test("ordinary transcripts pass through untouched") {
    for sentence in referenceSentences {
        runner.expectEqual(WhisperEngine.stripNonSpeechAnnotations(sentence), sentence)
    }
}

// Whisper fills trailing silence with whatever its captioned training data said
// next — "Thank you.", "you" — appended to a real transcript, where
// `isInventedSilence` cannot touch it because it may only drop a hold entire.
// With timestamps on, the segment's own audio settles it.
await runner.test("a segment decoded from silence is not audible") {
    var samples = [Float](repeating: 0, count: 16000 * 4)
    // A voice in the first second, nothing after it.
    for frame in 0..<16000 { samples[frame] = sin(Float(frame) * 0.1) * 0.2 }

    runner.expectEqual(WhisperEngine.spansAudibleAudio(samples, from: 0, to: 1), true)
    runner.expectEqual(WhisperEngine.spansAudibleAudio(samples, from: 1.5, to: 4), false)
    runner.expectEqual(WhisperEngine.spansAudibleAudio(samples, from: 0.5, to: 2.5), true)
}

// An out-of-range or inverted timestamp is a reason to distrust the timestamp,
// never to throw away words.
await runner.test("an unmeasurable span keeps its words") {
    let samples = [Float](repeating: 0, count: 16000)
    runner.expectEqual(WhisperEngine.spansAudibleAudio(samples, from: 5, to: 9), true)
    runner.expectEqual(WhisperEngine.spansAudibleAudio(samples, from: 2, to: 1), true)
    runner.expectEqual(WhisperEngine.spansAudibleAudio([], from: 0, to: 1), true)
}

// Quiet speech is still speech: the ceiling sits below any voice, not near it.
await runner.test("a quietly spoken segment is kept") {
    var samples = [Float](repeating: 0, count: 16000 * 2)
    // -34 dBFS, well under conversational level and well over the -45 ceiling.
    for frame in 0..<samples.count { samples[frame] = sin(Float(frame) * 0.1) * 0.02 }
    runner.expectEqual(WhisperEngine.spansAudibleAudio(samples, from: 0, to: 2), true)
}

// A hold that produced nothing but an annotation must insert nothing, which is
// the existing guard doing its job once the annotation is gone.
await runner.test("an annotation on its own carries no words") {
    for alone in ["[BLANK_AUDIO]", "[ Silence ]", "(music)"] {
        let stripped = TextNormalizer.finalize(WhisperEngine.stripNonSpeechAnnotations(alone))
        runner.expectEqual(WhisperEngine.carriesWords(stripped), false, alone)
    }
}

// MARK: - Model catalog

runner.suite("Model catalog")

await runner.test("both layers offer the expected number of models") {
    runner.expectEqual(ModelCatalog.models(in: .speechRecognition).count, 13)
    runner.expectEqual(ModelCatalog.models(in: .correction).count, 5)
}

// Whisper's variant folders are not a pattern — large-v3-turbo is published
// under a release date — so a guessed folder resolves to a different
// checkpoint rather than failing, and the catalog would offer a model nobody
// chose.
await runner.test("every Whisper variant is in the catalog exactly once") {
    let catalogued = ModelCatalog.models(in: .speechRecognition).map(\.id)
    for variant in WhisperEngine.Variant.allCases {
        runner.expectEqual(
            catalogued.filter { $0 == variant.modelID }.count, 1,
            "\(variant.modelID) is not listed exactly once")
        runner.expectEqual(
            WhisperEngine.Variant.from(modelID: variant.modelID), variant,
            "\(variant.modelID) does not resolve back to its variant")
    }
}

await runner.test("Whisper caches inside Murmur's own folder, not Documents") {
    // WhisperKit's default download base is ~/Documents/huggingface, which is
    // both a folder nobody asked for and one this app could never find again
    // to delete.
    let base = WhisperEngine.downloadBase.path
    runner.expectEqual(base.contains("/Library/Application Support/Murmur/"), true, base)
    runner.expectEqual(
        WhisperEngine.modelsDirectory(.largeV3Turbo).lastPathComponent,
        "openai_whisper-large-v3-v20240930")
}

await runner.test("each speech model's streaming claim matches its engine") {
    // Murmur used to list streaming models only. Non-streaming ones are now
    // allowed, so the invariant is no longer "everything streams" but "the
    // catalog says which, truthfully" — the flag drives the overlay, and a
    // model wrongly marked live would show an empty box for the whole hold.
    runner.expectEqual(
        SpeechEngineFactory.mislabeledSpeechModelIDs,
        [],
        "speech models whose streams flag contradicts their engine"
    )
}

await runner.test("at least one speech model streams and one does not") {
    let speech = ModelCatalog.models(in: .speechRecognition)
    runner.expect(speech.contains { $0.streams }, "no live model is offered")
    runner.expect(speech.contains { !$0.streams }, "no on-release model is offered")
}

await runner.test("model ids are unique") {
    let ids = ModelCatalog.all.map(\.id)
    runner.expectEqual(Set(ids).count, ids.count, "duplicate model id")
}

await runner.test("only Apple models are built in and free of download size") {
    for model in ModelCatalog.all {
        if model.runtime == .appleBuiltIn {
            runner.expectEqual(model.sizeMB, 0, "\(model.name) is built in but has a size")
        } else {
            runner.expect(model.sizeMB > 0, "\(model.name) needs a download size")
        }
    }
}

await runner.test("every model states a licence and a summary") {
    for model in ModelCatalog.all {
        runner.expect(!model.license.isEmpty, "\(model.name) has no licence")
        runner.expect(!model.summary.isEmpty, "\(model.name) has no summary")
        runner.expect(!model.vendor.isEmpty, "\(model.name) has no vendor")
    }
}

await runner.test("sizes read as built in, megabytes, or gigabytes") {
    let byID = Dictionary(uniqueKeysWithValues: ModelCatalog.all.map { ($0.id, $0) })
    runner.expectEqual(byID[ModelCatalog.appleSpeechID]?.sizeDescription, "Built in")
    runner.expectEqual(byID["nvidia.parakeet-realtime-eou-120m"]?.sizeDescription, "~250 MB")
    runner.expectEqual(byID["mlx.qwen3-4b"]?.sizeDescription, "~2.3 GB")
}

// Nothing may be offered as ready until its engine is actually compiled in.
await runner.test("unwired runtimes report a blocker instead of appearing installable") {
    ModelCatalog.mlxSupported = false
    ModelCatalog.coreMLEngineWired = false
    ModelCatalog.onnxEngineWired = false
    for model in ModelCatalog.all where model.runtime != .appleBuiltIn {
        let state = ModelCatalog.state(
            for: model,
            appleSpeechAvailable: true,
            appleCorrectionUnavailableReason: nil,
            installedIDs: []
        )
        guard case .unavailable = state else {
            runner.expect(false, "\(model.name) claims to be installable with no engine")
            continue
        }
    }
}

await runner.test("a model that cannot punctuate is flagged as such") {
    let eou = ModelCatalog.model(id: "nvidia.parakeet-realtime-eou-120m")
    runner.expectEqual(eou?.punctuates, false, "EOU must be flagged as unpunctuated")
    runner.expectEqual(
        ModelCatalog.model(id: ModelCatalog.appleSpeechID)?.punctuates, true
    )
}

await runner.test("downloadable speech engines map to a FluidAudio variant") {
    runner.expectEqual(
        FluidAudioEngine.Variant.from(modelID: "nvidia.parakeet-realtime-eou-120m"),
        .parakeetEou
    )
    runner.expectEqual(
        FluidAudioEngine.Variant.from(modelID: "nvidia.nemotron-streaming-en-0.6b"),
        .nemotron
    )
    runner.expect(
        FluidAudioEngine.Variant.from(modelID: ModelCatalog.appleSpeechID) == nil,
        "the built-in engine must not map to a download"
    )
}

// Each variant must own a distinct cache folder, or deleting one would remove
// the other's weights.
await runner.test("model cache folders are distinct") {
    let folders = FluidAudioEngine.Variant.allCases.map(\.cacheFolderName)
    runner.expectEqual(Set(folders).count, folders.count)
    runner.expect(
        !folders.contains("parakeet-unified-en-0.6b"),
        "must not claim a cache folder belonging to another model"
    )
}

await runner.test("downloadable cleanup models map to an MLX variant") {
    runner.expectEqual(MLXCleaner.Variant.from(modelID: "mlx.qwen3-4b"), .qwen3_4b)
    runner.expectEqual(MLXCleaner.Variant.from(modelID: "mlx.qwen3-1.7b"), .qwen3_1_7b)
    runner.expectEqual(MLXCleaner.Variant.from(modelID: "mlx.gemma3-4b"), .gemma3_4b)
    runner.expectEqual(MLXCleaner.Variant.from(modelID: "mlx.gemma3-1b"), .gemma3_1b)
    runner.expect(
        MLXCleaner.Variant.from(modelID: ModelCatalog.appleCorrectionID) == nil,
        "the built-in cleaner must not map to a download"
    )
}

// Every catalog entry that claims a runtime must have an implementation behind
// it, or the UI would offer a download that goes nowhere.
await runner.test("every non-Apple catalog model maps to a real engine") {
    for model in ModelCatalog.all where model.runtime == .coreML {
        // Core ML covers both the streaming FluidAudio variants and the batch
        // Parakeet checkpoint, so the factory is the authority here.
        runner.expect(
            SpeechEngineFactory.engine(for: model.id) != nil,
            "\(model.name) claims Core ML but has no engine"
        )
    }
    for model in ModelCatalog.all where model.runtime == .moonshine {
        runner.expect(
            MoonshineEngine.Variant.from(modelID: model.id) != nil,
            "\(model.name) claims Moonshine but has no engine"
        )
    }
    for model in ModelCatalog.all where model.runtime == .mlx {
        runner.expect(
            MLXCleaner.Variant.from(modelID: model.id) != nil,
            "\(model.name) claims MLX but has no engine"
        )
    }
}

// The catalog mapping above was correct while dictation still ran Apple's
// recognizer for Moonshine, because the app resolved engines with its own
// private branch. Selection has to be checked where dictation actually reads
// it, or a model can be offered, marked active, and never loaded.
await runner.test("every speech model in the catalog resolves to an engine") {
    runner.expectEqual(
        SpeechEngineFactory.unimplementedSpeechModelIDs,
        [],
        "offered speech models with no engine behind them"
    )
}

await runner.test("each speech model resolves to its own distinct engine") {
    let apple = SpeechEngineFactory.engine(for: ModelCatalog.appleSpeechID)
    runner.expect(apple is AppleSpeechEngine, "Apple ID did not resolve to Apple's engine")

    for model in ModelCatalog.models(in: .speechRecognition)
    where model.id != ModelCatalog.appleSpeechID {
        // Falling back to Apple is exactly the failure this guards against:
        // it transcribes fine, so nothing looks broken.
        runner.expect(
            !(SpeechEngineFactory.engine(for: model.id) is AppleSpeechEngine),
            "\(model.name) silently resolves to Apple SpeechAnalyzer"
        )
    }

    runner.expect(
        SpeechEngineFactory.engine(for: "not.a.real.model") == nil,
        "an unknown ID must not resolve to an engine"
    )
}

// Reasoning models emit a thinking block that must never reach the clipboard.
await runner.test("reasoning blocks are stripped from cleanup output") {
    runner.expectEqual(
        MLXCleaner.stripReasoning("<think>Let me consider.</think>Move the meeting."),
        "Move the meeting."
    )
    // Truncated mid-thought: everything from the open tag is dropped.
    runner.expectEqual(
        MLXCleaner.stripReasoning("<think>Let me consider the sentence"),
        ""
    )
    runner.expectEqual(
        MLXCleaner.stripReasoning("<think>a</think>One.<think>b</think> Two."),
        "One. Two."
    )
    // Ordinary text is untouched.
    runner.expectEqual(
        MLXCleaner.stripReasoning("Hello, I'm testing this feature."),
        "Hello, I'm testing this feature."
    )
}

await runner.test("only reasoning models get the larger token budget") {
    runner.expect(
        MLXCleaner.Variant.qwen3_4b.maximumTokens
            > MLXCleaner.Variant.gemma3_1b.maximumTokens,
        "a reasoning model needs more headroom than a direct one"
    )
}

// Gemma 3 above 1B ships only as a vision-language model; loading it through
// the text-only factory fails with a tensor shape mismatch.
await runner.test("multimodal models are routed to the VLM loader") {
    runner.expectEqual(MLXCleaner.Variant.gemma3_4b.isVisionLanguageModel, true)
    runner.expectEqual(MLXCleaner.Variant.gemma3_1b.isVisionLanguageModel, false)
    runner.expectEqual(MLXCleaner.Variant.qwen3_4b.isVisionLanguageModel, false)
    runner.expectEqual(MLXCleaner.Variant.qwen3_1_7b.isVisionLanguageModel, false)
}

await runner.test("MLX repositories are distinct and non-empty") {
    let repos = MLXCleaner.Variant.allCases.map(\.repositoryID)
    runner.expectEqual(Set(repos).count, repos.count, "duplicate repository")
    for repo in repos {
        runner.expect(repo.contains("/"), "\(repo) is not a valid repository id")
    }
}

await runner.test("Apple models are usable when the system supports them") {
    let speech = ModelCatalog.state(
        for: ModelCatalog.model(id: ModelCatalog.appleSpeechID)!,
        appleSpeechAvailable: true,
        appleCorrectionUnavailableReason: nil,
        installedIDs: []
    )
    runner.expect(speech.isUsable, "Apple speech model reported unusable")

    let blocked = ModelCatalog.state(
        for: ModelCatalog.model(id: ModelCatalog.appleCorrectionID)!,
        appleSpeechAvailable: true,
        appleCorrectionUnavailableReason: "Turn on Apple Intelligence.",
        installedIDs: []
    )
    runner.expect(!blocked.isUsable, "unavailable cleanup model reported usable")
}

// MARK: - Latency instrumentation

runner.suite("Latency instrumentation")

await runner.test("marks are recorded in order") {
    let tracker = LatencyTracker()
    tracker.begin()
    tracker.mark(.hotkeyDown)
    tracker.mark(.microphoneRunning)
    tracker.mark(.inserted)

    let rows = tracker.elapsedMilliseconds()
    runner.expectEqual(rows.map(\.0), ["hotkey down", "microphone running", "text inserted"])
    runner.expect(rows.allSatisfy { $0.1 >= 0 }, "negative elapsed time")
}

// Only the first partial should be timed, not every subsequent one.
await runner.test("duplicate marks are ignored") {
    let tracker = LatencyTracker()
    tracker.begin()
    tracker.mark(.firstPartial)
    tracker.mark(.firstPartial)
    runner.expectEqual(tracker.elapsedMilliseconds().count, 1)
}

await runner.test("intervals are reported only when both marks exist") {
    let tracker = LatencyTracker()
    tracker.begin()
    tracker.mark(.hotkeyDown)
    tracker.mark(.microphoneRunning)
    runner.expect(
        tracker.interval(from: .hotkeyDown, to: .microphoneRunning) != nil,
        "missing interval for two recorded marks"
    )
    runner.expect(
        tracker.interval(from: .hotkeyDown, to: .cleanupComplete) == nil,
        "reported an interval for a mark that was never recorded"
    )
}

await runner.test("marks made before begin are dropped") {
    let tracker = LatencyTracker()
    tracker.mark(.hotkeyDown)
    runner.expect(tracker.elapsedMilliseconds().isEmpty, "recorded a mark before begin()")
}

// MARK: - Hands-free pre-roll

// Silero confirms speech up to 300 ms after it began (measured by --testvad).
// Without replaying that audio the first word of every utterance is lost, which
// is the same class of bug as Moonshine dropping the last word.
func makeBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    return buffer
}

await runner.test("pre-roll keeps at least the detector's confirmation lag") {
    var preRoll = PreRollBuffer(seconds: 0.5, sampleRate: 16000)
    // 100 ms buffers, the granularity the microphone tap delivers.
    for _ in 0..<20 { preRoll.append(makeBuffer(frames: 1600)) }

    let heldSeconds = Double(preRoll.frameCount) / 16000
    runner.expect(
        heldSeconds >= 0.3,
        "kept \(heldSeconds)s, less than the 300 ms worst-case start lag"
    )
    runner.expect(heldSeconds <= 0.7, "kept \(heldSeconds)s, far beyond the half second asked for")
}

await runner.test("pre-roll replays oldest audio first") {
    var preRoll = PreRollBuffer(capacityFrames: 4800)
    let first = makeBuffer(frames: 1600)
    let second = makeBuffer(frames: 1600)
    preRoll.append(first)
    preRoll.append(second)

    let drained = preRoll.drain()
    runner.expectEqual(drained.count, 2)
    runner.expect(drained.first === first, "replayed out of order")
    runner.expect(preRoll.frameCount == 0, "drain left audio behind")
}

await runner.test("pre-roll never grows without bound") {
    var preRoll = PreRollBuffer(seconds: 0.5, sampleRate: 16000)
    for _ in 0..<500 { preRoll.append(makeBuffer(frames: 1600)) }
    runner.expect(
        preRoll.frameCount <= 8000 + 1600,
        "held \(preRoll.frameCount) frames after 50 s of audio"
    )
}

await runner.test("hands-free silence default matches the measured tuning") {
    // 500 ms is two 256 ms chunks; 250 ms is one. Values between behave
    // identically, so the defaults must sit on a boundary that means something.
    let tuning = VoiceActivityDetector.Tuning()
    runner.expectEqual(tuning.silenceDuration, 0.5)
    runner.expect(
        tuning.minSpeechDuration >= 0.3,
        "a shorter minimum would let a cough insert text"
    )
}

// MARK: - Joining consecutive utterances

// Pausing mid-sentence ends one utterance and starts another, so the text
// arrives as two pastes. Reported from real use: they landed with no gap.
await runner.test("consecutive utterances are separated by one space") {
    var joiner = UtteranceJoiner()
    runner.expectEqual(joiner.separator(before: "the meeting", target: "app"), "")
    runner.expectEqual(joiner.separator(before: "is on Thursday", target: "app"), " ")
}

await runner.test("joining never doubles an existing space") {
    var joiner = UtteranceJoiner()
    _ = joiner.separator(before: "the meeting ", target: "app")
    runner.expectEqual(
        joiner.separator(before: "is on Thursday", target: "app"), "",
        "added a space after text that already ended with one")

    var other = UtteranceJoiner()
    _ = other.separator(before: "the meeting", target: "app")
    runner.expectEqual(
        other.separator(before: " is on Thursday", target: "app"), "",
        "added a space before text that already began with one")
}

await runner.test("punctuation stays tight against the previous word") {
    for continuation in [", and then", ". Then", "? Really", "! Yes", "; next"] {
        var joiner = UtteranceJoiner()
        _ = joiner.separator(before: "the meeting", target: "app")
        runner.expectEqual(
            joiner.separator(before: continuation, target: "app"), "",
            "pushed \"\(continuation)\" away from the word it belongs to")
    }
}

await runner.test("a different field starts fresh") {
    var joiner = UtteranceJoiner()
    _ = joiner.separator(before: "the meeting", target: "com.apple.Notes")
    runner.expectEqual(
        joiner.separator(before: "is on Thursday", target: "com.tinyspeck.slack"), "",
        "carried spacing across into a different app")
}

await runner.test("reset makes the next utterance a fresh start") {
    var joiner = UtteranceJoiner()
    _ = joiner.separator(before: "the meeting", target: "app")
    joiner.reset()
    runner.expectEqual(joiner.separator(before: "is on Thursday", target: "app"), "")
}

await runner.test("joining only ever adds a single space, never edits the text") {
    var joiner = UtteranceJoiner()
    _ = joiner.separator(before: "hello", target: "app")
    let separator = joiner.separator(before: "world", target: "app")
    runner.expect(
        separator.isEmpty || separator == " ",
        "produced \"\(separator)\" — only an empty string or one space is allowed")
}

// MARK: - Deterministic formatting

// The rules that rewrite meaning default to off. Ordinary prose must come out
// of the default configuration untouched apart from sentence capitalization.
await runner.test("default formatting leaves reference sentences alone") {
    let options = SpokenFormatter.Options()
    for sentence in referenceSentences {
        runner.expectEqual(
            SpokenFormatter.format(sentence, options: options), sentence,
            "default formatting altered a reference sentence")
    }
}

await runner.test("the master switch turns everything off") {
    var options = SpokenFormatter.Options(enabled: false)
    options.spokenPunctuation = true
    options.removeFillers = true
    runner.expectEqual(
        SpokenFormatter.format("um hello comma world", options: options),
        "um hello comma world")
}

await runner.test("spoken punctuation becomes punctuation") {
    let options = SpokenFormatter.Options()
    runner.expectEqual(
        SpokenFormatter.format("hello comma world period", options: options),
        "Hello, world.")
    runner.expectEqual(
        SpokenFormatter.format("is it ready question mark", options: options),
        "Is it ready?")
    runner.expectEqual(
        SpokenFormatter.format("first line new line second line", options: options),
        "First line\nSecond line")
}

await runner.test("fillers are dropped only when they stand alone") {
    let options = SpokenFormatter.Options()
    runner.expectEqual(
        SpokenFormatter.format("um so uh the report is done", options: options),
        "So the report is done")
    // A filler carrying punctuation would take the punctuation with it.
    runner.expectEqual(
        SpokenFormatter.format("well um, that is done", options: options),
        "Well um, that is done")
}

await runner.test("years and numbers convert only when asked") {
    var options = SpokenFormatter.Options()
    runner.expectEqual(
        SpokenFormatter.format("it was twenty twenty six", options: options),
        "It was twenty twenty six",
        "numbers converted while the rule was off")

    options.numbers = true
    runner.expectEqual(
        SpokenFormatter.format("it was twenty twenty six", options: options),
        "It was 2026")
    runner.expectEqual(
        SpokenFormatter.format("back in nineteen eighty four", options: options),
        "Back in 1984")
    runner.expectEqual(
        SpokenFormatter.format("about twenty five people", options: options),
        "About 25 people")
    // "One" works as a pronoun and stays a word; every other number word is a
    // count when it stands alone and converts.
    runner.expectEqual(
        SpokenFormatter.format("one of the things", options: options),
        "One of the things")
    runner.expectEqual(
        SpokenFormatter.format("just one more time", options: options),
        "Just one more time")
    runner.expectEqual(SpokenFormatter.format("nineteen", options: options), "19")
    runner.expectEqual(
        SpokenFormatter.format("nineteen of them left", options: options),
        "19 of them left")
    // "One" inside a compound is arithmetic, not a pronoun.
    runner.expectEqual(
        SpokenFormatter.format("twenty one people", options: options), "21 people")
    runner.expectEqual(
        SpokenFormatter.format("one hundred people", options: options), "100 people")

    // Reported from real dictation: "0.35 s" read aloud came back as words.
    runner.expectEqual(
        SpokenFormatter.format("three point five seconds", options: options),
        "3.5 seconds")
    // Decimals are spoken digit by digit, so this is 3.14 and not "3.fourteen".
    runner.expectEqual(
        SpokenFormatter.format("pi is about three point one four", options: options),
        "Pi is about 3.14")
    runner.expectEqual(
        SpokenFormatter.format("version two point oh five", options: options),
        "Version 2.05")
    // "point" without a digit after it keeps its ordinary meaning, so the
    // decimal rule cannot damage prose that merely contains the word.
    // The number converts, but "point" stays a word: no digit follows it, so
    // this is a three-point turn and not 3.0 of anything.
    runner.expectEqual(
        SpokenFormatter.format("it was a three point turn", options: options),
        "It was a 3 point turn")
    runner.expectEqual(
        SpokenFormatter.format("at that point I left", options: options),
        "At that point I left")
    // A decimal is a figure however small its whole part, so the guard that
    // keeps "one of the things" as prose must not reject this.
    runner.expectEqual(
        SpokenFormatter.format("one point five times", options: options),
        "1.5 times")

    // A date came out half in digits and half in letters: the year converted,
    // the day did not, because a small standalone number reads as prose.
    runner.expectEqual(
        SpokenFormatter.format("nineteen august twenty twenty six", options: options),
        "19 August 2026")
    runner.expectEqual(
        SpokenFormatter.format("august nineteen", options: options),
        "August 19")
    runner.expectEqual(
        SpokenFormatter.format("nineteen of them left", options: options),
        "19 of them left")

    // Reported from real dictation: this came out as "2000 and sixteen".
    runner.expectEqual(
        SpokenFormatter.format("two thousand and sixteen", options: options), "2016")
    runner.expectEqual(
        SpokenFormatter.format("one hundred and five", options: options), "105")
    runner.expectEqual(
        SpokenFormatter.format("two thousand sixteen", options: options), "2016")
    // "and" is only part of a number after a scale word. Two separate figures
    // joined by a conjunction must stay two figures.
    runner.expectEqual(
        SpokenFormatter.format("I ate twenty and thirty", options: options),
        "I ate 20 and 30")
    runner.expectEqual(
        SpokenFormatter.format("two thousand and I left", options: options),
        "2000 and I left")
}

await runner.test("currency converts only when asked") {
    var options = SpokenFormatter.Options()
    runner.expectEqual(
        SpokenFormatter.format("it cost five dollars", options: options),
        "It cost five dollars")

    options.currency = true
    runner.expectEqual(
        SpokenFormatter.format("it cost five dollars", options: options), "It cost $5")
    runner.expectEqual(
        SpokenFormatter.format("it cost twenty five dollars", options: options),
        "It cost $25")
    runner.expectEqual(
        SpokenFormatter.format("it cost five dollars and fifty cents", options: options),
        "It cost $5.50")
}

await runner.test("lists and markdown convert only when asked") {
    var options = SpokenFormatter.Options()
    runner.expectEqual(
        SpokenFormatter.format("bullet buy milk", options: options), "Bullet buy milk")

    options.lists = true
    runner.expectEqual(SpokenFormatter.format("bullet buy milk", options: options), "- Buy milk")

    options.markdown = true
    runner.expectEqual(SpokenFormatter.format("heading intro", options: options), "# Intro")
    runner.expectEqual(
        SpokenFormatter.format("bold ship it", options: options), "**Ship it**")
    // Emphasis must close inside the sentence terminator.
    runner.expectEqual(
        SpokenFormatter.format("bold ship it.", options: options), "**Ship it**.")
}

await runner.test("a run of number words stays a run of numbers") {
    var options = SpokenFormatter.Options()
    options.numbers = true

    // Reported from real dictation: reading out digits summed them. English
    // compounds numbers in a few shapes and in no others, and a run of bare
    // units is not one of them — it is someone reading digits aloud.
    runner.expectEqual(
        SpokenFormatter.format("one two three", options: options), "1 2 3")
    runner.expectEqual(
        SpokenFormatter.format("five five five", options: options), "5 5 5")
    runner.expectEqual(
        SpokenFormatter.format("call nine one one", options: options), "Call 9 1 1")
    // A teen fills the tens and the units place at once, so nothing may follow
    // it into the same figure.
    runner.expectEqual(
        SpokenFormatter.format("sixteen three", options: options), "16 3")
    // Two tens words are two numbers.
    runner.expectEqual(
        SpokenFormatter.format("thirty forty", options: options), "30 40")
    // Scale words may only descend.
    runner.expectEqual(
        SpokenFormatter.format("one thousand two thousand", options: options),
        "1000 2000")
    // A rejected scale word must give back the words it had already read, or
    // they are counted twice.
    runner.expectEqual(
        SpokenFormatter.format("one hundred two hundred", options: options),
        "100 200")

    // The compounds that are real must survive all of the above.
    runner.expectEqual(
        SpokenFormatter.format("twenty one people", options: options), "21 people")
    runner.expectEqual(
        SpokenFormatter.format("one hundred twenty three", options: options), "123")
    runner.expectEqual(
        SpokenFormatter.format("two thousand and sixteen", options: options), "2016")
    runner.expectEqual(
        SpokenFormatter.format("two thousand three hundred", options: options), "2300")

    // "One" is a pronoun on its own, but not when it sits in a run of digits:
    // "one 2 3" would be absurd. A number word either side settles it, and
    // punctuation between them ends the run.
    runner.expectEqual(
        SpokenFormatter.format("one of the things", options: options),
        "One of the things")
    runner.expectEqual(
        SpokenFormatter.format("just one more time", options: options),
        "Just one more time")
    runner.expectEqual(
        SpokenFormatter.format("two one", options: options), "2 1")
    runner.expectEqual(
        SpokenFormatter.format("I have two, one is broken", options: options),
        "I have 2, one is broken")
    // A year is a compound too, and must not reach across punctuation either.
    runner.expectEqual(
        SpokenFormatter.format("twenty, twenty six", options: options), "20, 26")
    runner.expectEqual(
        SpokenFormatter.format("in twenty twenty six, we ship", options: options),
        "In 2026, we ship")
    runner.expectEqual(
        SpokenFormatter.format("nineteen eighty, four", options: options), "1980, 4")
    // Punctuation on the last word of a figure survives the conversion.
    runner.expectEqual(
        SpokenFormatter.format("there were twenty one.", options: options),
        "There were 21.")
}

await runner.test("formatting never splits a word") {
    var options = SpokenFormatter.Options()
    options.numbers = true
    options.currency = true
    options.lists = true
    options.markdown = true
    for sentence in referenceSentences {
        let formatted = SpokenFormatter.format(sentence, options: options)
        for corruption in ["act ually", "cor rectly", "beca use"] {
            runner.expect(
                !formatted.contains(corruption),
                "formatting split a word in \"\(sentence)\"")
        }
    }
}

// MARK: - Multi-model comparison

runner.suite("Transcript comparison")

await runner.test("identical transcripts are unanimous") {
    let comparison = TranscriptDiff.compare([
        .init(label: "a", text: "I think we should ship it on Thursday."),
        .init(label: "b", text: "I think we should ship it on Thursday."),
    ])
    runner.expect(comparison.unanimous, "identical transcripts reported a disagreement")
    runner.expectEqual(comparison.disagreements, 0)
}

await runner.test("casing and punctuation alone are not disagreements") {
    // Two engines writing "Thursday." and "Thursday" heard the same word, and
    // flagging that would bury the places they really differ.
    let comparison = TranscriptDiff.compare([
        .init(label: "a", text: "ship it on Thursday."),
        .init(label: "b", text: "Ship it on thursday"),
    ])
    runner.expect(comparison.unanimous, "punctuation difference counted as a disagreement")
}

await runner.test("a substituted word is contested in every row") {
    let comparison = TranscriptDiff.compare([
        .init(label: "a", text: "ship it on Thursday"),
        .init(label: "b", text: "ship it on Tuesday"),
    ])
    runner.expect(!comparison.unanimous, "a substitution went unreported")
    for row in comparison.rows {
        let contested = row.tokens.filter { !$0.agrees }.map(\.text)
        runner.expectEqual(contested.count, 1, "\(row.label) flagged \(contested)")
    }
    let flagged = Set(comparison.rows.flatMap { $0.tokens.filter { !$0.agrees }.map(\.text) })
    runner.expectEqual(flagged, ["Thursday", "Tuesday"])
}

await runner.test("agreeing words stay unflagged around a substitution") {
    let comparison = TranscriptDiff.compare([
        .init(label: "a", text: "ship it on Thursday"),
        .init(label: "b", text: "ship it on Tuesday"),
    ])
    let first = comparison.rows[0]
    runner.expectEqual(first.tokens.prefix(3).allSatisfy(\.agrees), true)
}

await runner.test("an inserted word does not knock the rest out of alignment") {
    // Substring alignment, not position-by-position: one engine hearing an
    // extra word must not paint every following word as contested.
    let comparison = TranscriptDiff.compare([
        .init(label: "a", text: "ship it on Thursday"),
        .init(label: "b", text: "ship it on the Thursday"),
    ])
    runner.expectEqual(comparison.disagreements, 1, "an insertion misaligned the tail")
}

await runner.test("an outlier does not become the backbone") {
    // Whichever transcript is aligned against defines what "agreement" means,
    // so it must be the typical one rather than the first or the longest.
    let comparison = TranscriptDiff.compare([
        .init(label: "outlier", text: "completely different words entirely here"),
        .init(label: "a", text: "ship it on Thursday"),
        .init(label: "b", text: "ship it on Thursday"),
    ])
    runner.expectEqual(comparison.backbone, "ship it on Thursday")
}

await runner.test("a single transcript has nothing to disagree with") {
    let comparison = TranscriptDiff.compare([.init(label: "a", text: "ship it")])
    runner.expect(comparison.unanimous, "a lone transcript reported a disagreement")
    runner.expectEqual(comparison.rows.count, 1)
}

await runner.test("no transcripts produce no rows") {
    runner.expectEqual(TranscriptDiff.compare([]).rows.count, 0)
}

await runner.test("comparison preserves the caller's row order") {
    let comparison = TranscriptDiff.compare([
        .init(label: "first", text: "ship it"),
        .init(label: "second", text: "ship it"),
        .init(label: "third", text: "ship it"),
    ])
    runner.expectEqual(comparison.rows.map(\.label), ["first", "second", "third"])
}

await runner.test("a contested word is flagged in the rows that agree too") {
    // The disputed word has to sit in one column down the page. Flagging only
    // the rows that differ makes the majority look unanimous and the minority
    // look broken, when the whole point is that the word is in question.
    let comparison = TranscriptDiff.compare([
        .init(label: "a", text: "we should move the meeting"),
        .init(label: "b", text: "we should move the meeting"),
        .init(label: "c", text: "we should unmove the meeting"),
    ])
    runner.expectEqual(comparison.disagreements, 3, "the contested column was not marked in every row")
    for row in comparison.rows {
        let contested = row.tokens.filter { !$0.agrees }.map(\.text)
        runner.expectEqual(contested.count, 1, "\(row.label) flagged \(contested)")
    }
}

runner.suite("Comparison scheduling")

await runner.test("bubbles sharing a speech model decode the audio once") {
    // Re-decoding would let variation between two decodes read as a
    // difference between the cleanup models being compared.
    let bubbles = [
        ModelComparison.BubbleConfig(
            speechModelID: "apple.speechanalyzer",
            cleanupModelID: "mlx.gemma3-1b", cleanupLevel: .light),
        ModelComparison.BubbleConfig(
            speechModelID: "apple.speechanalyzer",
            cleanupModelID: "mlx.qwen3-1.7b", cleanupLevel: .light),
    ]
    let groups = ModelComparison.speechGroups(bubbles)
    runner.expectEqual(groups.count, 1, "the same speech model was scheduled twice")
    runner.expectEqual(groups[0].bubbles.count, 2)
}

await runner.test("each cleanup model is loaded once for all its bubbles") {
    let bubbles = [
        ModelComparison.BubbleConfig(
            speechModelID: "apple.speechanalyzer",
            cleanupModelID: "mlx.gemma3-1b", cleanupLevel: .light),
        ModelComparison.BubbleConfig(
            speechModelID: "moonshine.streaming-small",
            cleanupModelID: "mlx.gemma3-1b", cleanupLevel: .light),
    ]
    let groups = ModelComparison.cleanupGroups(bubbles)
    runner.expectEqual(groups.count, 1)
    runner.expectEqual(groups[0].bubbles.count, 2)
}

await runner.test("groups keep first-appearance order") {
    let bubbles = [
        ModelComparison.BubbleConfig(speechModelID: "moonshine.streaming-small"),
        ModelComparison.BubbleConfig(speechModelID: "apple.speechanalyzer"),
        ModelComparison.BubbleConfig(speechModelID: "moonshine.streaming-small"),
    ]
    runner.expectEqual(
        ModelComparison.speechGroups(bubbles).map(\.modelID),
        ["moonshine.streaming-small", "apple.speechanalyzer"])
}

await runner.test("cleanup at level off loads no model") {
    // Selecting a cleanup model and leaving the level at Off would otherwise
    // load gigabytes of weights to return the text unchanged.
    let bubbles = [
        ModelComparison.BubbleConfig(
            speechModelID: "apple.speechanalyzer",
            cleanupModelID: "mlx.gemma3-1b", cleanupLevel: .off),
        ModelComparison.BubbleConfig(speechModelID: "apple.speechanalyzer"),
    ]
    runner.expectEqual(ModelComparison.cleanupGroups(bubbles).count, 0)
    runner.expectEqual(bubbles[0].wantsCleanup, false)
    runner.expectEqual(bubbles[1].wantsCleanup, false)
}

await runner.test("an unknown cleanup model resolves to nothing, not to Apple's") {
    // The same rule as SpeechEngineFactory: a silent substitution here would
    // compare a model against itself and report the two as equally good.
    runner.expect(
        ModelComparison.cleaner(for: "mlx.not-a-real-model") == nil,
        "an unknown cleanup model silently fell back to a working cleaner")
    runner.expect(
        ModelComparison.cleaner(for: ModelCatalog.appleCorrectionID) != nil,
        "Apple's cleanup model did not resolve")
}

await runner.test("every catalog cleanup model resolves to a cleaner") {
    // A model offered in a bubble picker that resolves to nil would show an
    // error instead of a comparison.
    for descriptor in ModelCatalog.models(in: .correction) {
        runner.expect(
            ModelComparison.cleaner(for: descriptor.id) != nil,
            "no cleanup engine implements \(descriptor.id)")
    }
}

runner.suite("Cleanup deadline")

await runner.test("work that finishes inside the deadline returns its value") {
    let value = await withDeadline(.seconds(5)) { "cleaned" }
    runner.expectEqual(value, "cleaned")
}

await runner.test("waiting stops at the deadline, not when the work finishes") {
    // The bug this exists for: cleanup has no bound of its own, and insertion
    // is serialized behind it, so one runaway pass held up every utterance
    // after it. Returning nil promptly is the whole fix — 75 s was measured.
    let started = ContinuousClock.now
    let value = await withDeadline(.milliseconds(50)) { () -> String? in
        try? await Task.sleep(for: .seconds(30))
        return "far too late"
    }
    let waited = ContinuousClock.now - started
    runner.expect(value == nil, "an overrunning pass was not abandoned")
    runner.expect(
        waited < .seconds(5),
        "waited \(waited) for a 50 ms deadline — the work was awaited after all")
}

await runner.test("work finishing after it was abandoned resumes nothing") {
    // Both racers resume the same continuation, and resuming one twice is a
    // crash rather than a failed assertion.
    let value = await withDeadline(.milliseconds(20)) { () -> String? in
        try? await Task.sleep(for: .milliseconds(120))
        return "late"
    }
    runner.expect(value == nil, "the deadline did not win")
    // Long enough for the abandoned work to finish and try to resume.
    try? await Task.sleep(for: .milliseconds(300))
}

runner.suite("Turn detection features")

await runner.test("the 8 s window keeps the end of speech at the end") {
    // Short audio is padded at the *front*. The model was trained to judge the
    // trailing edge, so padding the other way would hand it silence to judge.
    let short = [Float](repeating: 0.5, count: 1000)
    let fitted = WhisperFeatures.fit(short)
    runner.expectEqual(fitted.count, WhisperFeatures.sampleCount)
    runner.expectEqual(fitted[0], 0)
    runner.expectEqual(fitted[WhisperFeatures.sampleCount - 1], 0.5)
}

await runner.test("audio longer than the window keeps its tail") {
    var long = [Float](repeating: 0.1, count: WhisperFeatures.sampleCount + 5000)
    long[long.count - 1] = 0.9
    let fitted = WhisperFeatures.fit(long)
    runner.expectEqual(fitted.count, WhisperFeatures.sampleCount)
    runner.expectEqual(fitted[WhisperFeatures.sampleCount - 1], 0.9)
}

await runner.test("log-mel matches the reference feature extractor") {
    // The one failure mode with no symptom: wrong features produce a confident
    // number rather than an error, so the model would simply be wrong. These
    // constants come from WhisperFeatureExtractor(chunk_length: 8) with
    // do_normalize, run on the same signal.
    // Broadband noise from an integer generator, for two reasons. Every value
    // is exactly representable, so this and the reference build the identical
    // input — a sine differs in the last bits between Float32 and float64. And
    // it fills every mel bin: a tone or a square wave leaves ~87% of the
    // spectrogram sitting on the `max - 8` floor, where a tiny difference in
    // the global peak shifts thousands of clamped values at once and the sum
    // moves 0.04% while the port is perfectly correct.
    var signal = [Float](repeating: 0, count: WhisperFeatures.sampleCount)
    var state = 12345
    for index in 0..<WhisperFeatures.sampleCount {
        state = (state &* 1103515245 &+ 12345) & 0x7FFF_FFFF
        signal[index] = Float(state % 5) * 0.25 - 0.5
    }
    let features = WhisperFeatures().extract(signal)
    runner.expectEqual(features.count, WhisperFeatures.melBins * WhisperFeatures.frameCount)

    let sum = features.reduce(0, +)
    let minimum = features.min() ?? 0
    let maximum = features.max() ?? 0
    // Float32 accumulation over 64000 values, so this is a tolerance on the
    // sum rather than an equality.
    runner.expect(abs(sum - 71198.2656) < 1.0, "sum was \(sum), expected 71198.27")
    runner.expect(abs(minimum - 0.258106) < 1e-3, "min was \(minimum)")
    runner.expect(abs(maximum - 1.384561) < 1e-3, "max was \(maximum)")
}

await runner.test("the detector window is the model's input length") {
    // HandsFreeSession caps its rolling buffer with this constant. If the two
    // ever disagree the model is handed the wrong span of audio.
    runner.expectEqual(WhisperFeatures.sampleCount, 8 * 16000)
    runner.expectEqual(WhisperFeatures.frameCount, 800)
    runner.expectEqual(WhisperFeatures.melBins, 80)
}

// MARK: - Startup audio hand-off

// The microphone opens before the recognizer is ready, so the audio captured in
// between is held and replayed. Every one of these failures is silent: the
// level meter is computed upstream in AudioCapture, so the overlay still moves
// and the card still says it is listening while the engine is fed nothing.

runner.suite("Startup audio hand-off")

await runner.test("audio captured before the recognizer is ready is replayed in order") {
    let engine = RecordingEngine()
    let startup = StartupAudioBuffer()

    for frames in [100, 200, 300] as [AVAudioFrameCount] {
        startup.append(makeBuffer(frames: frames))
    }
    startup.attach(engine)

    runner.expectEqual(engine.appendedFrames, [100, 200, 300])
}

await runner.test("audio captured after the hand-off reaches the engine") {
    let engine = RecordingEngine()
    let startup = StartupAudioBuffer()

    startup.append(makeBuffer(frames: 100))
    startup.attach(engine)
    // The whole rest of the utterance takes this path — everything the
    // speaker says after roughly the first 50 ms.
    startup.append(makeBuffer(frames: 200))
    startup.append(makeBuffer(frames: 300))

    runner.expectEqual(engine.appendedFrames, [100, 200, 300])
}

await runner.test("replayed audio is not delivered twice") {
    let engine = RecordingEngine()
    let startup = StartupAudioBuffer()

    startup.append(makeBuffer(frames: 100))
    startup.attach(engine)
    startup.append(makeBuffer(frames: 200))

    runner.expectEqual(engine.appendedFrames, [100, 200])
}

// The regression. `startPipeline` creates the hand-off, installs it in the
// audio tap, attaches the engine and returns; from then on the tap is its only
// owner. Capturing it weakly there deallocated it the moment that function
// returned, so every buffer after the recognizer was ready went nowhere and
// every transcript came back empty.
await runner.test("the tap keeps the hand-off alive after the caller returns") {
    let engine = RecordingEngine()
    let tap = TapHolder()

    func startPipeline() {
        let startup = StartupAudioBuffer()
        tap.install { buffer in startup.append(buffer) }
        startup.attach(engine)
    }
    startPipeline()

    tap.deliver(makeBuffer(frames: 512))
    tap.deliver(makeBuffer(frames: 512))

    runner.expectEqual(
        engine.appendedFrames, [512, 512],
        "the hand-off did not survive the function that installed it")
}

await runner.test("removing the tap releases the hand-off") {
    // The other side of holding it strongly: the session must not leave the
    // engine reachable forever. `AudioCapture.stop()` removes the tap, and
    // that has to be the last reference.
    weak var observed: StartupAudioBuffer?
    let tap = TapHolder()

    do {
        let startup = StartupAudioBuffer()
        observed = startup
        tap.install { buffer in startup.append(buffer) }
    }
    runner.expect(observed != nil, "the tap should hold it for the session")

    tap.remove()
    runner.expect(observed == nil, "removing the tap should release it")
}

// MARK: - Dictation history

// The store itself was never the bug. What was recorded arrived correctly and
// survived a restart; the settings window read it once and then showed that
// same snapshot for the rest of the session, so a dictation made after the
// window had been opened never appeared. Nothing here can see the view, so
// what is tested is the signal the view now hangs off.

runner.suite("Dictation history")

func makeHistoryStore() -> HistoryStore {
    let suite = "murmur.tests.history.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return HistoryStore(defaults: defaults)
}

await runner.test("an inserted transcript is recorded newest first") {
    let store = makeHistoryStore()
    store.record("First one.")
    store.record("Second one.")
    runner.expectEqual(store.entries.map(\.text), ["Second one.", "First one."])
}

await runner.test("blank text is not recorded") {
    let store = makeHistoryStore()
    store.record("   \n  ")
    runner.expectEqual(store.entries.count, 0)
}

await runner.test("history is capped rather than unbounded") {
    let store = makeHistoryStore()
    for index in 0..<(HistoryStore.limit + 5) { store.record("Line \(index).") }
    runner.expectEqual(store.entries.count, HistoryStore.limit)
    runner.expectEqual(store.entries.first?.text, "Line \(HistoryStore.limit + 4).")
}

// The regression: a view that reads the store once shows a list frozen at
// whenever it first appeared. This is what tells it to read again.
await runner.test("recording announces the change") {
    let store = makeHistoryStore()
    var announced = 0
    let observer = NotificationCenter.default.addObserver(
        forName: HistoryStore.didChangeNotification, object: store, queue: nil
    ) { _ in announced += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    store.record("Said something.")
    store.record("Said something else.")
    store.record("   ")

    runner.expectEqual(announced, 2, "one announcement per recorded transcript")
}

// Posting while still holding the store's lock deadlocks any observer that
// reacts by reading the list — which is exactly what the settings view does.
await runner.test("an observer may read the history from the notification") {
    let store = makeHistoryStore()
    var seen: [String] = []
    let observer = NotificationCenter.default.addObserver(
        forName: HistoryStore.didChangeNotification, object: store, queue: nil
    ) { notification in
        guard let store = notification.object as? HistoryStore else { return }
        seen = store.entries.map(\.text)
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    store.record("Said something.")

    runner.expectEqual(seen, ["Said something."])
}

// MARK: - The microphone held open between dictations

// `isArmed` decides whether anything reopens the device, and macOS stops the
// engine out from under this class on a configuration change — a device
// appearing, waking from sleep. Believing our own flag over the engine left
// the microphone shut while every switch in the app said it was open, and a
// dictation in that state records silence: nothing reinstalls the tap and
// nothing starts the engine. The real device is exercised by `--testmic`.

runner.suite("Microphone arming")

await runner.test("a capture that was never armed reports itself closed") {
    let capture = AudioCapture()
    runner.expect(!capture.isArmed, "nothing has opened the device yet")
}

await runner.test("stop leaves it closed and safe to repeat") {
    let capture = AudioCapture()
    capture.stop()
    capture.stop()
    runner.expect(!capture.isArmed, "stopping an unopened device must not claim it is open")
}

exit(runner.finish())
