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
