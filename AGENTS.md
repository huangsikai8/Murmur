# Murmur — working notes

Push-to-talk dictation for macOS 26. Hold a key, speak, release, and the text
lands in whatever field had focus. Menu bar only, everything on-device.

Read `README.md` for what the app does. This file is the things that cost time
to discover and are not visible in the code.

## Build: two build systems, on purpose

`scripts/build-app.sh` uses **both**, and neither can be dropped:

* **SwiftPM builds the app.** `xcodebuild` cannot: FluidAudio's
  `NemoTextProcessing.xcframework` and Moonshine's `Moonshine.xcframework` both
  emit `include/module.modulemap`, and Xcode fails with "Multiple commands
  produce".
* **xcodebuild builds the MLX Metal library**, via `tools/MetallibBuilder`,
  which depends on mlx-swift alone. SwiftPM cannot compile `.metal` sources, so
  an MLX binary it builds dies at runtime with "Failed to load the default
  metallib". The resulting `mlx-swift_Cmlx.bundle` is copied into
  `Contents/Resources` and cached between builds.

Xcode also needs its Metal component: `xcodebuild -downloadComponent
MetalToolchain` (and `xcodebuild -runFirstLaunch` first, or that fails).

Signing uses the self-signed "WindowDeck Dev" identity so TCC grants survive
rebuilds; ad-hoc signing would force re-approval of Microphone and Accessibility
every time. If a build hangs, it is usually the keychain dialog waiting for
"Always Allow".

## Traps that will waste an afternoon

**`main.swift` must stay synchronous.** A top-level `await` hands the main
thread to the concurrency runtime, and `NSApplication.run()` must own it.
Symptom: launched from a terminal it works fine, but launched by LaunchServices
(`open Murmur.app`) it never receives `applicationDidFinishLaunching`, so it
never requests the microphone and never appears in Privacy settings at all.

**`runBlocking` pumps the run loop, it does not block.** Blocking on a semaphore
deadlocks anything that needs the main actor — model loading does — and the
process sits alive at 0% CPU looking exactly like a slow download.

**The hardened runtime needs `Murmur.entitlements`.** Without
`com.apple.security.device.audio-input`, macOS denies the microphone outright,
in about 5 ms, without prompting, and the app never appears in Privacy settings.
A real prompt takes seconds; an instant `false` means the entitlement is missing.

**Audio must reach an engine in order.** `append` yields into a `StreamPipe`
synchronously. Spawning a `Task` per buffer is not FIFO on an actor, so buffers
arrive out of sequence or get dropped when a session ends. Fixing this improved
Apple's accuracy from 2 misses to 4/4 exact — it was degrading the default
engine silently.

**Streaming decoders need trailing audio.** Releasing the hotkey stops speech
abruptly, and the final window never closes: "afternoon" arrives as "after".
`MoonshineEngine` feeds 500 ms of silence before finalizing. Check this first if
a new engine truncates last words.

**Chunk-based engines only decode when asked.** `finish()` on FluidAudio's EOU
manager returns an empty string unless `processBufferedAudio()` ran first.

**A silent fallback in engine selection hides for weeks.** An unknown model ID
resolving to `AppleSpeechEngine()` still transcribes perfectly, so nothing looks
wrong. `SpeechEngineFactory.engine(for:)` returns `nil` instead, and the caller
logs before falling back. The switch is logged with its duration for the same
reason: a swap that did not happen is instant.

**Catalog sizes must be measured, not read off Hugging Face.** The Parakeet TDT
v2 repo totals ~2.6 GB because it carries several precisions; FluidAudio fetches
one set and lands at 452 MB on disk.

## Model-specific gotchas

* **Qwen3 reasons.** It emits `<think>…</think>`; strip it, and budget 1024
  tokens so the answer survives. Its documented `/no_think` switch makes it lazy
  — it echoes the input back — so leave reasoning on.
* **Gemma 3 above 1B is multimodal** (`Gemma3ForConditionalGeneration`). It must
  load through `VLMModelFactory`, not the text-only one, which fails with a
  tensor shape mismatch. There is no macro for the VLM path; compose
  `#hubDownloader()` and `#huggingFaceTokenizerLoader()` by hand.
* **Parakeet EOU emits lowercase, unpunctuated text.** It is only usable with
  cleanup on. `punctuates` in the catalog exists to warn about this.
* **Install detection must match exact cache folders.** Matching loosely on
  "parakeet" once reported an unrelated model as installed.

## Invariants — do not break these

The whole point of the app is that text is never corrupted, so:

* Volatile results go **only** to the overlay. Nothing speculative is inserted.
* The transcript crosses into the target app as **one** pasteboard value and one
  Command-V, so it cannot arrive in fragments.
* `TextNormalizer.finalize` may only **remove** whitespace. Joining may insert a
  space only *between* recognizer chunks. Nothing may put a space inside a word.
* Cleanup output is never trusted: `CleanupGuard` rejects assistant phrasing,
  vocabulary the speaker never used, and implausible length ratios, falling back
  to the raw transcript.
* A speech model's `streams` flag must match the engine behind it. Non-streaming
  models are allowed now, but a model wrongly marked live shows an empty overlay
  for the whole hold and reads as broken; a test enforces the agreement.
* Engine selection lives only in `SpeechEngineFactory`. The app and `--selftest`
  each used to branch on the model ID themselves, drifted apart, and Moonshine
  ran under the self-test while the app silently used Apple's recognizer.

`Sources/MurmurTests/` covers all of the above. Run it after any change to the
text path.

## Commands

```sh
./scripts/build-app.sh debug            # build + sign + assemble
swift run MurmurTests                   # 69 tests, no Xcode needed
./build/Murmur.app/Contents/MacOS/Murmur --diagnose
./build/Murmur.app/Contents/MacOS/Murmur --selftest [modelID]
./build/Murmur.app/Contents/MacOS/Murmur --testcleanup
./build/Murmur.app/Contents/MacOS/Murmur --testcleanup-mlx [modelID]
./build/Murmur.app/Contents/MacOS/Murmur --testhomophones
./build/Murmur.app/Contents/MacOS/Murmur --download [modelID]
```

`--selftest` drives the real recognizer with `say`-synthesized speech, so it
verifies the pipeline without a microphone. Synthesized audio is harsher than a
real voice: a wrong word there is not necessarily a defect, but corrupted
spacing is.

`~/Library/Logs/Murmur.log` is rewritten each launch. A healthy start ends with
`warmUp finished, status=idle`.

## Measured results, so regressions are visible

Speech, `--selftest`, 4 sentences: Apple SpeechAnalyzer 4/4 (20–24 ms to first
partial), Nemotron 4/4, Moonshine Small 4/4, Moonshine Medium 4/4, Parakeet TDT
0.6B v2 4/4, Parakeet EOU 2/4 and unpunctuated.

Parakeet TDT v2 is the one non-streaming entry: it emits nothing while you speak
and decodes on release, in 81–104 ms for a short sentence, after a 253 ms load.
Model loads are fast because the weights are memory-mapped and Core ML's
compiled artifacts are already on disk — Nemotron 240 ms, Moonshine Medium
287 ms. Only the first load of a model, which downloads and compiles, is slow.

`E5RT encountered an STL exception … zero shape error` during Parakeet TDT load
is emitted by Core ML itself, the models load anyway, and the results are exact.

Cleanup, on a rambling sample at Light: Apple Foundation and Gemma 3 4B both
clean it properly; Qwen3 4B leaves "the the" and "i i"; Gemma 3 1B leaves "i i"
and "um"; Qwen3 1.7B echoes the input unchanged.

The two models built into macOS are the best of the ten. The downloadable ones
exist for when Apple Intelligence is unavailable.
