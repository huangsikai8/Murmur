import AppKit
import MurmurCore

// Diagnostic modes write progress as it happens rather than in blocks, so a
// stall is visible instead of looking like silence.
if CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {
    setvbuf(stdout, nil, _IONBF, 0)
}

// Diagnostic modes complete before any AppKit setup, and stay synchronous on
// purpose — see runBlocking().
if CommandLine.arguments.contains("--diagnose") {
    runBlocking { await Diagnostics.run() }
    exit(0)
}

// `--download <modelID>` fetches a model's weights and reports the result.
if let index = CommandLine.arguments.firstIndex(of: "--download") {
    let modelID = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : ""
    exit(runBlocking { await ModelDownloadCommand.run(modelID: modelID) })
}

// Answers "why did that go to the clipboard?" by naming the element that had
// focus. Counts down first so the window you are asking about can be brought
// to the front, since running this in a terminal focuses the terminal.
if CommandLine.arguments.contains("--testfocus") {
    ClipboardPasteInserter.diagnostics = { print("  \($0)") }
    print("Click into whatever you want to test. Sampling in 5 seconds…\n")
    exit(runBlocking {
        for remaining in stride(from: 5, through: 1, by: -1) {
            print("  \(remaining)…")
            try? await Task.sleep(for: .seconds(1))
        }
        let focus = ClipboardPasteInserter.describeFocus()
        print("\nfocused element: \(focus.description)")
        print(
            focus.acceptsText
                ? "verdict: text would be pasted here"
                : "verdict: nothing can take text — the transcript would stay on the clipboard")
        return 0
    })
}

// `--testmic [iterations]` measures the speech lost before the microphone is
// running — the one gap at the start of an utterance that nothing buffers.
if let index = CommandLine.arguments.firstIndex(of: "--testmic") {
    let iterations =
        CommandLine.arguments.count > index + 1
        ? Int(CommandLine.arguments[index + 1]) ?? 5 : 5
    exit(runBlocking { await MicTest.run(iterations: iterations) })
}

if CommandLine.arguments.contains("--testformatting") {
    exit(runBlocking { await FormattingTest.run() })
}

if let index = CommandLine.arguments.firstIndex(of: "--testhandsfree") {
    let modelID =
        CommandLine.arguments.count > index + 1
        && !CommandLine.arguments[index + 1].hasPrefix("--")
        ? CommandLine.arguments[index + 1] : ModelCatalog.appleSpeechID
    exit(runBlocking { await VadTest.runPipeline(modelID: modelID) })
}

// `--testturn [seconds]` records real speech and reports, at every pause,
// whether the turn detector would commit or wait. Unlike every other test here
// it cannot use `say`: the model reads prosody, and synthesized speech ends
// every utterance the same way regardless of the words.
if let index = CommandLine.arguments.firstIndex(of: "--testturn") {
    let seconds =
        CommandLine.arguments.count > index + 1
        && !CommandLine.arguments[index + 1].hasPrefix("--")
        ? Double(CommandLine.arguments[index + 1]) ?? 15 : 15
    let file =
        CommandLine.arguments.firstIndex(of: "--file").map { CommandLine.arguments[$0 + 1] }
    exit(runBlocking { await TurnTest.run(seconds: seconds, file: file) })
}

if let index = CommandLine.arguments.firstIndex(of: "--testvad") {
    // Defaults to what the app actually ships, so the reported wait is the
    // one a user experiences rather than the library's.
    let shipped = VoiceActivityDetector.Tuning().silenceDuration
    let silence =
        CommandLine.arguments.count > index + 1
        ? Double(CommandLine.arguments[index + 1]) ?? shipped : shipped
    exit(runBlocking { await VadTest.run(silenceDuration: silence) })
}

if let index = CommandLine.arguments.firstIndex(of: "--testtail") {
    let modelID =
        CommandLine.arguments.count > index + 1
        && !CommandLine.arguments[index + 1].hasPrefix("--")
        ? CommandLine.arguments[index + 1] : nil
    // `--clip N` also removes N ms of real speech, which must fail. A tail test
    // that cannot fail says nothing about the tail.
    let clipIndex = CommandLine.arguments.firstIndex(of: "--clip")
    let extraClipMs =
        clipIndex.flatMap { CommandLine.arguments.count > $0 + 1 ? Int(CommandLine.arguments[$0 + 1]) : nil } ?? 0
    exit(runBlocking { await TailTest.run(modelID: modelID, extraClipMs: extraClipMs) })
}

if CommandLine.arguments.contains("--testhomophones") {
    exit(runBlocking { await CleanupTest.runHomophones() })
}

if let index = CommandLine.arguments.firstIndex(of: "--testcleanup-mlx") {
    let modelID = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1] : "mlx.gemma3-1b"
    exit(runBlocking { await CleanupTest.runMLX(modelID: modelID) })
}

if CommandLine.arguments.contains("--testcleanup") {
    exit(runBlocking { await CleanupTest.run() })
}

// `--testcompare [seconds] [--say "sentence"] [--cleanup <modelID>]` replays one
// recording through every installed speech model and shows where they differ.
if let index = CommandLine.arguments.firstIndex(of: "--testcompare") {
    var options = CompareTest.Options()
    if CommandLine.arguments.count > index + 1,
        let seconds = Double(CommandLine.arguments[index + 1])
    {
        options.seconds = seconds
    }
    if let sayIndex = CommandLine.arguments.firstIndex(of: "--say"),
        CommandLine.arguments.count > sayIndex + 1
    {
        options.sentence = CommandLine.arguments[sayIndex + 1]
    }
    if let cleanupIndex = CommandLine.arguments.firstIndex(of: "--cleanup"),
        CommandLine.arguments.count > cleanupIndex + 1
    {
        options.cleanupModelID = CommandLine.arguments[cleanupIndex + 1]
    }
    // Copied so the closure captures a value rather than the mutable local.
    let resolved = options
    exit(runBlocking { await CompareTest.run(options: resolved) })
}

if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
    let modelID =
        CommandLine.arguments.count > index + 1
        && !CommandLine.arguments[index + 1].hasPrefix("--")
        ? CommandLine.arguments[index + 1] : ModelCatalog.appleSpeechID
    exit(runBlocking { await SelfTest.run(modelID: modelID) })
}

// Top-level code is synchronous here, and this is the real main thread, so
// asserting main-actor isolation is accurate.
MainActor.assumeIsolated {
    launchMurmur()
}
