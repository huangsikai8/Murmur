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

    let inserter = ClipboardPasteInserter(pasteboard: pasteboard, restoreDelay: 0.05, paste: {})
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

    let inserter = ClipboardPasteInserter(pasteboard: pasteboard, restoreDelay: 0.2, paste: {})
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

    let inserter = ClipboardPasteInserter(pasteboard: pasteboard, restoreDelay: 0.05, paste: {})
    try inserter.insert("dictated sentence")

    try await Task.sleep(for: .milliseconds(400))
    runner.expectEqual(pasteboard.string(forType: .string), "plain text")
    runner.expectEqual(pasteboard.string(forType: .html), "<b>rich</b>")
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

// MARK: - Model catalog

runner.suite("Model catalog")

await runner.test("both layers offer the expected number of models") {
    runner.expectEqual(ModelCatalog.models(in: .speechRecognition).count, 6)
    runner.expectEqual(ModelCatalog.models(in: .correction).count, 5)
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

exit(runner.finish())
