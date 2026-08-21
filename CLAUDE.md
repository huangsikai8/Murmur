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

**Engines do not all accept the same audio format.** Hands-free captures at
16 kHz mono because the detector requires it, but Apple's SpeechAnalyzer traps
*inside the Speech framework* (`SpeechRecognizerWorker.preRunRecognition`) when
handed a format it did not ask for — a SIGTRAP with nothing useful on the main
thread's stack. `HandsFreeSession` converts into each engine's
`preferredInputFormat()` before appending. Never assume an engine resamples.

**The microphone is the slowest thing in the whole press.** Opening the input
device costs 15-472 ms, measured with `--testmic`, and it is wildly variable
run to run. That audio is not late, it does not exist: nothing buffers a device
that is not running, so every millisecond came off the front of the utterance.
Real sessions logged 155-466 ms from `hotkey down` to `microphone running`.
`StartupAudioBuffer` never covered this — it closes the gap between the
microphone running and the *recognizer* being ready, which is ~15 ms, and sits
entirely after it. `AudioCapture` therefore holds the device open between
dictations and a press only swaps the sink, which measures **0.0-0.1 ms**; real
sessions now log 1.3-7.3 ms end to end. The price is the orange microphone
indicator staying lit, so `Preferences.keepMicrophoneArmed` can turn it off.
While idle the buffers go into a 300 ms rolling pre-roll and are discarded, and
that pre-roll is replayed when a session starts — so a syllable begun just
before the key still reaches the recognizer.

**macOS keeps the microphone indicator lit after the device is released.** So
switching `keepMicrophoneArmed` off and watching the menu bar looks exactly
like the setting doing nothing — which is what it looked like, and it was
working. Do not debug this from the indicator. `AudioCapture.isArmed` is only
this app's bookkeeping; `AudioCapture.systemReportsInputRunning` asks CoreAudio
for `kAudioProcessPropertyIsRunningInput` on our own process, which is the
signal the indicator itself follows. It is what the menu bar's "Microphone:
open / closed" line reads, what `armMicrophone` and the preference log, and
what `--testmic` asserts on — measured, `stop()` really does release the device
and the property goes false. The property does not update synchronously with
the stop, so every reader waits a moment first.

**A pre-roll captured in one format must never be replayed into a session that
asked for another.** Hands-free re-points the armed device at 16 kHz mono and
push-to-talk points it back; whatever the roll is holding at that moment is in
the old format, and Apple's SpeechAnalyzer does not reject a format it did not
ask for, it traps inside the Speech framework. `prearm` drops the roll. Covered
by `--testmic`, which is also the only test that exercises the switch at all.

**The tap ignores the buffer size it is asked for.** `installTap` is given 1024
frames and delivers 4800 at 48 kHz — 100 ms. That is what sizes the wait after
the key says stop: the buffer holding the moment of the keystroke is not handed
over until it has *filled*, so a shorter wait throws that fraction of a second
away. The fixed 120 ms this used to be left 20 ms of margin and none at all on
a device that buffers more, so `trailingCaptureWait` is derived from
`AudioCapture.observedBufferSeconds` plus 60 ms.

**But that length is a worst case, and sleeping it spent the difference.** A
release lands uniformly inside a 100 ms buffer, so the wait that is always long
enough is about twice the wait usually needed, and the surplus is dead time
between the last word and the text appearing. `end()` now awaits
`AudioCapture.waitForAudio(recordedThrough:timeout:)`, which resumes when the
tap hands over a buffer whose audio actually reaches the moment of the release,
with `trailingCaptureWait` demoted to the ceiling. Measured with `--testmic`,
8 releases: **9-110 ms, median 78 ms** against the flat 160 ms — ~82 ms off
every push-to-talk release, on every engine. The buffer's own `AVAudioTime` is
what says how far it reaches, not the clock at delivery: the two differ by the
input latency, and reading the clock would credit a buffer with audio recorded
after it was already captured. That is also why a release occasionally waits
past 100 ms — the first buffer to arrive did not yet cover the key, so it
correctly waited for the next one. `--testmic` asserts both halves: every wait
returns with a buffer, and audio that can never arrive still gives up at the
ceiling rather than hanging the dictation.

**A session's teardown outlives its key.** The microphone runs on past `end()`
for the trailing capture while `isActive` is already false, so a second tap
inside that window opens a session whose device the *previous* session's
pending stop then closes — in a latch that is one tap, and the whole utterance
after it is silent. `sessionToken` makes the pending stop a no-op once someone
else has claimed the microphone.

**A meter cannot be smoother than the rate it is fed, and draining is not
pacing.** The tap delivers one buffer per 100 ms holding four 25 ms slices, so
draining the queue every 25 ms and drawing whatever came back moves the meter
four bars at once, ten times a second — finer data, identical stutter. The
slices are queued in `startMeter` and released one per tick, two while catching
up, and dropped beyond 300 ms of backlog, since a late bar is speech that has
already finished. The bars are also drawn without an implicit animation on
purpose: `ForEach` is keyed by position, so a scrolling meter is not bars
moving, it is each bar taking its neighbour's height, and animating that
interpolates every bar towards the one beside it — which smears the waveform and
pays for 28 interpolations every 25 ms to do it.

**Meter styles are five drawings of the same measurement.** `MeterStyle` picks
between the scrolling waveform (default), a centre-weighted pulse, real
frequency bands, bouncing bars, and the iOS 9 Siri wave. All five are handed the
same measured loudness, draw inside the same fixed 165x22 box, and never resize
the card. Only `.spectrum` costs anything extra — a 512-point FFT per slice
through `SpectrumAnalyser` — and `DictationController.meterStyle` switches
`AudioCapture.analysesSpectrum` off for the other four, so nothing is computed
for a meter nobody is drawing. `.lively`'s per-bar drift is the one piece of
invented motion in the app; it multiplies the measured level rather than adding
to it, so it can still only move when there is sound. The band edges are
asserted by a test that plays a tone at each band's own centre frequency and
requires that band to be the loudest — a bin/band mapping that is off by one
still moves with your voice and looks perfectly plausible on screen.

**A level scale has two ends and both can be wrong.** The meter's window ran
-50 dB to 0 dB — full scale, which dictation never reaches, so an ordinary voice
at ~-30 dBFS sat mid-meter and looked no different from an empty room. Opening
the floor to -55 dB overshot the other way: a quiet room is about -50 dBFS, so
the room itself moved the bars and the meter twitched at nothing. -42 to -12 dB
with an S-curve puts a room flat on the floor and speech across the top half.
`overlaySpeechLevel` has to be recalibrated every time that window moves, since
the same number means a different loudness on each curve, and the failure it
guards — the card appearing for room noise — is silent.

**The level meter cannot be more responsive than the tap.** `installTap`
delivers one buffer per 100 ms, so polling `currentLevel` every 50 ms — which is
what the meter did — produced pairs of identical bars and a meter that moved at
10 frames a second however it was drawn. `updateLevel` measures each buffer in
four slices and `drainLevels()` hands over every one, so a bar is 25 ms and a
syllable is a shape. The scale matters as much as the rate: the old mapping ran
-50 dB to 0 dB — full scale, which dictation never reaches — so an ordinary
voice at ~-30 dBFS and an empty room both sat in the middle and looked alike.
The window is -55 to -12 dB with an S-curve, which puts the room on the floor
and speech at the top. All of this is display only: `currentLevel` feeds the
meter, the hands-free card gate and the compare window, and nothing else, so
none of it can affect a transcript. `overlaySpeechLevel` had to be recalibrated
with it — the same 0.35 means -32.5 dB on the old scale and -40 dB on this one,
so leaving the number alone would have made the card appear for room noise.

**A detector confirms speech only after it has started.** Silero needs up to
300 ms (measured, `--testvad`), so continuous dictation keeps a 500 ms pre-roll
and replays it into the engine when speech is confirmed. Without it the first
word of every utterance is lost — the same failure as Moonshine's missing last
word, at the other end.

**`TextNormalizer.finalize` collapses newlines too.** It treats every
whitespace character as collapsible, so running it over text containing a line
break erases it. `SpokenFormatter` finalizes line by line, or "new line" would
produce a space. Its `openingPunctuation` also binds `#` to the next word, which
is right for a hashtag and wrong for a markdown heading — hence
`restoreHeadingSpaces`.

**"and" is part of a number only after a scale word.** "two thousand and
sixteen" is 2016, but "twenty and thirty" is two figures joined by a
conjunction. Without that rule the first came out as "2000 and sixteen".

**A digit opens a sentence too.** Capitalizing only on the first *letter* left
the flag set through "2000", so the following word was capitalized: "2000 And I
left". Markers like `-`, `#` and `*` stay transparent instead, so a list item or
heading still capitalizes its first real word.

**A decimal point is not a sentence terminator.** Capitalizing after every "."
turns "$45.50 for it" into "$45.50 For it". Sentence capitalization has to check
whether digits sit on both sides.

**A weak reference in the audio path is silent in every direction.**
`StartupAudioBuffer` holds microphone buffers while the recognizer loads, and
once `startPipeline` returns the audio tap is its only owner. Capturing it
`[weak]` there deallocated it immediately, so only the ~55 ms replayed by
`attach` ever reached the engine and every transcript came back empty. Nothing
looked broken: the level meter is computed upstream in `AudioCapture`, so the
overlay still moved and the card still said it was listening; `recognizer ready`
was still marked; and `--selftest` still reported 4/4 exact, because it feeds
the engine directly and never calls `capture.start`. The signature is a latency
report carrying `final transcript` but no `first partial transcript` and no
`text inserted` — recognizer fine, audio never arrived.

**No headless test drives the microphone tap.** `--selftest` and
`--testhandsfree` both hand audio to an engine themselves, so the whole capture
path — `capture.start`, the hand-off, the tap's ownership — is exercised only by
`--testcompare`, `--testturn` and a real voice. `StartupAudioBuffer` therefore
lives in `MurmurCore`, not nested in `DictationController`, so
`Sources/MurmurTests/` can at least test the object's ordering and lifetime
directly. The wiring in `startPipeline` remains uncovered: the app target cannot
be imported.

**The system-wide `AXFocusedUIElement` query does not work on macOS 26.** It
returns `cannotComplete` in 0 ms — not a timeout, and regardless of what is
focused; asking the frontmost application directly
(`AXUIElementCreateApplication(pid)`) answers correctly for the same element in
the same instant. `describeFocus` read that failure as "nothing focused", which
made every dictation report "No text field focused — copied to clipboard" while
the paste was landing normally, and silently clobbered the clipboard each time
by skipping the restore. It now asks the application as a fallback, and
separates the three answers: an application that reports no focused element is
still a real "nothing focused" and still announces, while an unreadable tree is
`unknown` — pasted, copy kept, nothing claimed on the card. `--testfocus` prints
which query answered.

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

**A changed app icon can look unchanged.** macOS caches icons keyed by bundle
path, so after a rebuild Privacy & Security and the permission prompt can keep
showing the old one — or the blank page from before there was an icon at all —
while the bundle on disk is correct. Do not debug this from the settings pane.
`NSWorkspace.icon(forFile:)` on the built bundle reports what LaunchServices
actually resolved, which is the signal; logging out clears the cache. The icon
is generated by `swift scripts/make-icon.swift` and only the products are
committed — the build copies `Resources/Murmur.icns` and warns if it is missing,
so a normal build never needs the generator to run.

**The menu bar mark is drawn, not shipped.** `MenuBarGlyph` renders the same
five bars at runtime because the status bar is not one fixed size, and because
a template PNG the build has to copy is one more thing that can vanish from the
bundle silently. It is a template image, so AppKit tints it for light, dark and
the highlighted state. Its slash is deliberately short and steep: the mark is
five thin strokes rather than one solid shape like `mic.slash`, and a slash
spanning the full width fragments every bar at once, which reads as broken
rather than disabled. `barHeights` is duplicated between the glyph and
`scripts/make-icon.swift` and has to be changed in both.

## Model-specific gotchas

* **Whisper is batch, and it invents words rather than returning none.** It
  decodes a fixed 30-second window, so there is nothing to show while you speak
  and `WhisperEngine` decodes on release like `ParakeetBatchEngine`. Trained on
  captioned audio, it fills near-silence with whatever the caption track said
  next. This is not a tail risk, it is every silent hold — measured with
  `--testsilence` on Large v3 Turbo, before the guard:

  | hold | returned |
  | --- | --- |
  | 2 s digital silence | "you" |
  | 2 s room tone at -55 dBFS | "." |
  | 2 s room tone at -45 dBFS | "." |
  | 6 s room tone at -50 dBFS | "." |

  Apple's recognizer returns nothing for all four, so the test is sound and the
  behaviour is Whisper's.

* **`noSpeechThreshold` does nothing in WhisperKit, and setting it looks like a
  fix.** Whisper's own guard for the above is the no-speech probability, and
  `TextDecoder.swift` contains `let noSpeechProb: Float = 0 // TODO: implement
  no speech prob`. The gate is `noSpeechProb > threshold`, so it compares 0
  against 0.6 forever. `WhisperEngine` therefore carries its own three-layer
  replacement, and each layer is deliberately weaker than it could be, because
  dropping a real sentence is worse than letting a stray "." through:
  audio whose loudest 25 ms is below **-45 dBFS** is never decoded at all;
  output containing no letter or digit is dropped unconditionally; and the
  stock fillers ("thank you", "you", "thanks for watching") are dropped only
  as a *whole transcript* and only below **-38 dBFS**, so saying thank you out
  loud keeps it. Peak, not average: a sentence is mostly gaps, and averaging
  pulls a real utterance down towards the room it was spoken in.
* **WhisperKit's variant folders are not a pattern.** `openai_whisper-small.en`
  next to `openai_whisper-large-v3-v20240930`, which is large-v3-turbo under its
  release date, and quantized siblings like `openai_whisper-small.en_217MB` sit
  in the same repository. A folder assembled from the case name would resolve to
  a *different checkpoint* rather than fail, so `Variant.repositoryFolder` spells
  each one out and a test asserts the round trip.
* **WhisperKit downloads to `~/Documents/huggingface` unless told otherwise.**
  Every variant here passes an explicit `downloadBase` of
  `~/Library/Application Support/Murmur/Whisper`, which is also what makes
  install detection and deletion exact. The weights and the tokenizer come from
  *two* repositories — `argmaxinc/whisperkit-coreml` and `openai/whisper-*` —
  and only the first reports progress, so the bar stops just short of the end
  while the last few hundred kilobytes arrive. Both count towards installed: the
  model cannot decode a token without the tokenizer.
* **The `.en` checkpoints have no language tokens**, so `DecodingOptions.language`
  is ignored by them and pins large-v3-turbo, the one multilingual variant
  offered, to English. Sizes are the sum of the files fetched per folder, not
  the repository total: Base (English) measured 146 MB on disk against the
  147 MB the catalog claims, which is what says the method is sound.

* **Qwen3 reasons, and must be told not to.** It emits `<think>…</think>`,
  which is stripped. Letting it think is what the code once did and it is
  strictly worse on every axis. Re-measured 2026-08-19 with
  `--testcleanup-mlx mlx.qwen3-4b`, both arms back to back on the same weights:

  | | reasoning | `/no_think` |
  | --- | --- | --- |
  | Generated | 247–1024 tokens | 13–27 tokens |
  | Time | 7.6–24.7 s | **0.96–1.7 s** |
  | Share of reply inside `<think>` | 96–100% | ~0 |
  | Usable answers | 5 of 6 | 6 of 6 |

  The one failure is the trap: on the longest sample the reasoning arm spent
  its whole 1024-token budget inside `<think>` and never reached an answer, so
  `CleanupGuard` fell back to the raw transcript. That fallback is what earlier
  notes here recorded as Qwen3 being "lazy", "echoing the input back", and
  "leaving the the and i i" — all three were measuring the fallback, not the
  model. `MLXCleaner` defaults to `.suppressed` and the budget drops to 320
  tokens with it, which is what the app has always actually run.
* **Gemma 3 above 1B is multimodal** (`Gemma3ForConditionalGeneration`). It must
  load through `VLMModelFactory`, not the text-only one, which fails with a
  tensor shape mismatch. There is no macro for the VLM path; compose
  `#hubDownloader()` and `#huggingFaceTokenizerLoader()` by hand.
* **Nemotron's latency tiers are separate downloads.** 2240 / 1120 / 560 ms are
  distinct Hugging Face repos cached in sibling folders under
  `nemotron-streaming/`, so install detection must name the tier — checking the
  parent reports every tier installed once any one of them is. Measured on the
  self-test all three tiers are 4/4 exact, so latency costs accuracy nothing
  measurable, including at 560 ms — the tier furthest from the trained chunk.
  Overlay updates across one 25-word sentence: 2240 ms → 4, 1120 ms → 6,
  560 ms → 11, Apple SpeechAnalyzer → 30. Halving the chunk does not double the
  updates, and no Nemotron tier approaches Apple for live text. All three tiers
  are ~600 MB each and coexist on disk.
* **Parakeet EOU emits lowercase, unpunctuated text.** It is only usable with
  cleanup on. `punctuates` in the catalog exists to warn about this.
* **Install detection must match exact cache folders.** Matching loosely on
  "parakeet" once reported an unrelated model as installed.

## Turn detection (smart-turn v3)

Silence duration is a proxy for "they are finished", and a bad one — people
pause mid-sentence several times a minute, so endpointing on silence alone
commits at every one of them. That is what makes hands-free feel
time-pressured: a pause is a commitment, because insertion cannot be taken
back. `TurnDetector` asks smart-turn v3 whether the *thought* is finished,
which lets the silence threshold drop instead of rise.

**There is already an ONNX Runtime in the binary.** `moonshine-swift`'s static
library embeds ORT 1.23.0 and exports its C entry points — `_OrtGetApiBase`
and 357 others — so `Sources/COnnxRuntime` carries the matching headers and
nothing else, and the published 8 MB int8 checkpoint runs as-is. No second
runtime, no Core ML conversion. If moonshine ever stops exporting them this
fails to *link*, which is the safe way to fail.

**`say` cannot evaluate this model.** It judges prosody, not words, and
synthesized speech ends every utterance on the same clean falling contour
regardless of the text: all six `say` fixtures came back COMPLETE, including
"the meeting is on" at 0.82. The model is fine — truncating real audio
mid-word reads 0.01–0.15 — the *fixture* cannot express trailing off.
`--testturn` therefore records a real voice, and is the only test here that
must. Pure silence reads 0.99 COMPLETE, so the model is only meaningful after
speech.

**The features are the silent failure.** A wrong log-mel produces a confident
number, never an error. `WhisperFeatures` is checked against
`WhisperFeatureExtractor(chunk_length=8, do_normalize=True)`: same audio gives
max abs diff 1.5e-5, and feeding reference features through this runtime gives
0.97084 against 0.97084 for ours — the port contributes nothing. The residual
0.006 versus the published number is ORT 1.23 against 1.29 on a quantized
graph.

**A mostly-silent fixture makes the feature test lie.** `log_spec` is floored
8 decades below its global peak, so with a tone or a square wave ~87% of the
spectrogram sits *on* that floor and a 2e-4 difference in the peak shifts
thousands of clamped values at once — the sum moves 0.04% while every element
is within 1e-5. The test uses exactly-representable broadband noise, which
leaves nothing on the floor. A sine is also wrong, for a different reason:
Float32 and float64 disagree in the last bits, so the two sides are not even
scoring the same input.

**A 400-point transform has no vDSP path.** 400 = 2^4 * 25 and Accelerate's
DFT only accepts f * 2^n for f in {1,3,5,15}. A hand-written mixed-radix FFT
measured 34 ms, nearly all of it allocation inside the recursion; a precomputed
201 x 400 DFT matrix through `cblas_sgemm` is exact and runs in 0.57 ms.

Measured: 0.57 ms features + 28.3 ms inference = **28.9 ms** per decision, next
to a ~980 ms endpoint. Model load, including the download, 1049 ms.

**A held turn needs a ceiling.** `HandsFreeSession.holdCeiling` (3 s) finalizes
anyway when the detector keeps saying "unfinished". Without it a wrong hold is
not a slow sentence, it is an utterance that never arrives — the same failure
as an unbounded cleanup pass.

## Invariants — do not break these

The whole point of the app is that text is never corrupted, so:

* Volatile results go **only** to the overlay. Nothing speculative is inserted.
* The microphone opens *before* anything else in `begin()` — before the overlay,
  the status change, the Escape monitor, and before the pipeline task. Those
  used to sit in front of it, and audio recorded during them does not exist.
* Return finalizes whatever is being spoken, in both modes, through the one
  `FinalizeKeyMonitor`. It consumes the key, because Return submits in most
  applications and would fire before the transcript arrived. A latch finished by
  Return takes exactly the same path as a latch finished by a second tap, down
  to the trailing capture, so the last word survives either way.
* In hands-free the overlay is gated on input level
  (`DictationController.overlaySpeechLevel`), because the detector opens an
  utterance for any noise. That gate is cosmetic: audio is captured, recognized
  and inserted regardless of whether the card ever appears.
* The transcript crosses into the target app as **one** pasteboard value and one
  Command-V, so it cannot arrive in fragments.
* `TextNormalizer.finalize` may only **remove** whitespace. Joining may insert a
  space only *between* recognizer chunks, and `UtteranceJoiner` only *between*
  two hands-free utterances. Nothing may put a space inside a word.
* Continuous dictation inserts each utterance separately, so a pause mid-sentence
  produces two pastes. `UtteranceJoiner` adds the single space between them, and
  never before punctuation that belongs to the preceding word.
* `SpokenFormatter` is the free deterministic layer and runs *before* the
  cleanup model, so spoken commands are already punctuation by the time a model
  sees them. Every rule that rewrites meaning — numbers, currency, lists,
  markdown — is off by default; only punctuation, fillers, capitalization and
  spacing are on, because those cannot change what a sentence says.
* Cleanup output is never trusted: `CleanupGuard` rejects assistant phrasing,
  vocabulary the speaker never used, and implausible length ratios, falling back
  to the raw transcript.
* Cleanup is also bounded in *time*: `DictationController.cleanupDeadline` gives
  up waiting after 20 s and inserts the raw transcript. It is the one stage with
  no limit of its own, and every utterance queues behind it.
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
swift scripts/make-icon.swift           # regenerate the app icon (rarely needed)
swift run MurmurTests                   # 123 tests, no Xcode needed
./build/Murmur.app/Contents/MacOS/Murmur --diagnose
./build/Murmur.app/Contents/MacOS/Murmur --selftest [modelID]
./build/Murmur.app/Contents/MacOS/Murmur --testcleanup
./build/Murmur.app/Contents/MacOS/Murmur --testcleanup-mlx [modelID]
./build/Murmur.app/Contents/MacOS/Murmur --testformatting
./build/Murmur.app/Contents/MacOS/Murmur --testvad [silenceSeconds]
./build/Murmur.app/Contents/MacOS/Murmur --testmic [iterations]
./build/Murmur.app/Contents/MacOS/Murmur --testtail [modelID] [--clip ms]
./build/Murmur.app/Contents/MacOS/Murmur --testhandsfree [modelID]
./build/Murmur.app/Contents/MacOS/Murmur --testsilence [modelID]
./build/Murmur.app/Contents/MacOS/Murmur --testhomophones
./build/Murmur.app/Contents/MacOS/Murmur --testcompare [seconds] \
    [--say "sentence"] [--cleanup modelID]
./build/Murmur.app/Contents/MacOS/Murmur --download [modelID]
```

`--selftest` drives the real recognizer with `say`-synthesized speech, so it
verifies the pipeline without a microphone. `--testhandsfree` does the same for
continuous dictation, driving the real `HandsFreeSession` — it caught the Apple
format trap on its first run. `--testvad` reports the two numbers that decide
how hands-free feels: start lag, which the pre-roll must cover, and end lag,
which is the wait before text appears. Synthesized audio is harsher than a
real voice: a wrong word there is not necessarily a defect, but corrupted
spacing is.

`--testmic` measures the gap at the *start* of an utterance, which is the
mirror of the missing trailing silence at the end and was much larger. It
asserts rather than only reporting: the pre-roll must replay at least one
buffer, the reported buffer duration must cover what the tap delivered, and a
format switch must both drop the stale roll and deliver in the new format.
`--testtail` covers the other end — audio cut at the last sample of speech and
finalized with no settle time, which is the latch case. `--testtail --clip 500`
removes real speech as well and must fail; a tail test that cannot fail says
nothing.

`--testsilence` holds the key with nobody speaking, in four flavours of room
tone, and every result must be empty — words there are words nobody said. It
exists because Whisper produces them and nothing upstream stops it.

`--testcompare` records once and replays that one recording through every
installed speech model in turn, then prints them side by side with the contested
words in `⟨⟩`. It is the only command that answers "which model is best *for
me*", since every other measurement here uses `say`. `--say` substitutes
synthesized speech for the microphone, which makes a run repeatable.

The same core drives **Compare Models…** in the menu bar, which is the same
thing with bubbles: each row picks its own speech model, cleanup model, and
level, contested words are highlighted rather than bracketed, and "Run again"
replays the *held* recording so a bubble can be added or reconfigured without
speaking twice. Nothing is persisted and closing the window releases every model
it loaded — it is a bench, not a mode. Its default bubbles are one model per
distinct engine, Apple's first; taking the catalog's first three opens on the
three Nemotron latency tiers, which is the same model three times.

Models are replayed one at a time, not run in parallel: peak memory stays at one
model, so combinations that could never be resident together can still be
compared, and no model's timings are distorted by another contending for the
ANE. Bubbles sharing a speech model decode the audio once and fan the text out,
or variation between two decodes would read as a difference between the cleanup
models being compared.

`~/Library/Logs/Murmur.log` is rewritten each launch. A healthy start ends with
`warmUp finished, status=idle`.

## Measured results, so regressions are visible

Speech, `--selftest`, 4 sentences: Apple SpeechAnalyzer 4/4 (20–24 ms to first
partial), Nemotron 4/4, Moonshine Small 4/4, Moonshine Medium 4/4, Parakeet TDT
0.6B v2 4/4, Whisper Base (English) 4/4, Parakeet EOU 2/4 and unpunctuated.

Whisper Large v3 Turbo is 4/4 as well, and the size is what it costs: 777–884 ms
to decode a short sentence against 106–157 ms for Base, on the same audio. Base
also passes `--testtail` 4/4 and `--testhandsfree` 4/4, finalizing in 124 ms
average / 160 ms worst — comparable to Parakeet TDT, and the two of them are the
only batch engines here. The first decode after a *download* costs ~2.4 s (Base) or
1.16 s (Turbo), which is Core ML compiling and specializing the model. This is
not per session, which is what an earlier note here claimed on the strength of
one run taken minutes after the download: re-measured warm, Turbo gives
834/756/865/849 ms and 808/843/797/744 ms with no first-decode spike at all. A
warm-up pass in `prepare()` would buy nothing. Measured on disk: Base 146 MB,
Turbo 1569 MB, each including a ~3 MB tokenizer from a second repository.

Parakeet TDT v2 is the one non-streaming entry: it emits nothing while you speak
and decodes on release, in 81–104 ms for a short sentence, after a 253 ms load.
Model loads are fast because the weights are memory-mapped and Core ML's
compiled artifacts are already on disk — Nemotron 240 ms, Moonshine Medium
287 ms. Only the first load of a model, which downloads and compiles, is slow.

Latency budget from the end of speech to text on screen, hands-free, measured:

| Stage | Cost |
| --- | --- |
| Hotkey to microphone, device armed | **0.0-7.3 ms** (was 155-466 ms) |
| Release to the last buffer, push-to-talk | **9-110 ms, median 78** (was a flat 160) |
| Detector endpoint (500 ms setting) | ~980 ms |
| Engine finalize — Parakeet TDT batch | 103 ms |
| Engine finalize — Apple SpeechAnalyzer | 115 ms |
| Engine finalize — Nemotron 560 ms | 152 ms |
| Engine finalize — Moonshine Small | **636 ms avg, 975 ms worst** |
| AI cleanup, Apple Foundation at Medium | ~290 ms |
| `SpokenFormatter`, every rule on | 0.3 ms |
| Vocabulary, focus restore, paste | negligible |

The detector dominates at roughly two thirds of the total; dropping the
threshold to 250 ms removes ~300 ms of it. Moonshine is the outlier — its
trailing-silence flush and settle loop cost half a second that no other engine
pays, so it roughly doubles the wait. MLX cleanup models cost seconds, not
milliseconds; Apple's built-in one does not.

Hands-free, `--testhandsfree`, 3 utterances: Apple SpeechAnalyzer, Parakeet TDT
v2, and Moonshine Small each segment and transcribe 3/3 exactly. A batch engine
works here because the detector, not the model, decides where speech ends.

**A stage with no time limit stalls every utterance behind it.** Insertion is
serialized — `deliver` waits on the previous utterance's task — so an unbounded
cleanup pass is not one slow sentence, it is a stopped app. A real session
logged `cleanup 75560 ms` on `mlx.qwen3-4b`, against ~290 ms for Apple's
cleaner: by the time those words arrived the speaker had said several more
sentences and moved to a different application. `withDeadline` abandons the
wait rather than cancelling the work, because MLX generation does not check for
cancellation — bounding the wait is the only thing that can honestly be done.
Thinking mode is **not** the cause, which is the obvious suspect and the wrong
one: `MLXCleaner` defaults to `.suppressed`, so that pass ran with `/no_think`
and a 320-token budget, and re-measuring that arm gives 0.96–1.7 s at 34–45
tok/s. Reaching 75 s at that rate needs ~3000 tokens, which the budget forbids,
so the time was not spent generating. The time was spent **paging**, and that is
measured, not inferred. Sampling `vm_stat` every 2 s through a run that loads
Qwen3 4B:

| | free | compressor | page-ins in that 2 s |
| --- | --- | --- | --- |
| idle | 55–63 MB | 3.57 GB | 0–2 MB |
| loading Parakeet | 61 MB | 3.86 GB | 747 MB |
| **loading Qwen3 4B** | 58 MB | 4.58 GB | **2060 MB** |
| generating | 60 MB | 4.59 GB | 15 MB |

Free memory never rises above ~90 MB on this machine: a normal working set of
Excel, VS Code, Chrome and WebKit already fills 16 GB, with 3.5 GB compressed
and 3.3 GB wired before any model loads. A 4-bit 4B model is ~2.3 GB that has
to be *resident*; there is no room, so loading it faults the whole thing in and
pushes another ~1 GB into the compressor. While it stays resident, generation
is ~1 s. The moment anything evicts it — the log shows Apple Foundation Models
being loaded 11 s into that 75 s window — every token re-faults, and the same
work takes tens of seconds.

So the entry above ("0.96–1.7 s") and the 75 s in the log are both true, and
neither is about the model. The practical consequence: on a 16 GB machine the
MLX cleanup models are only usable when little else is running, which is the
other half of why the two built into macOS are the ones to use.

**Latency instrumentation that nothing can read is not instrumentation.**
`LatencyTracker.report()` printed to stdout, which LaunchServices discards, and
to os_log at `.debug`, which is not persisted — so timings existed and could
never be recovered from a real session. It now also writes through
`LatencyTracker.sink` into `Murmur.log`. Hands-free had no timing at all,
because `LatencyTracker` is driven by the hotkey it never touches; it now logs
cleanup and total per utterance.

**A toggle shortcut cannot use the hold-to-talk mechanism.** `HotkeyMonitor`
uses passive `NSEvent` global monitors, which observe without consuming — fine
for holding a bare modifier, wrong for claiming a chord, because ⌥⌘D would also
reach the app in front and trigger its own. `ToggleShortcutMonitor` uses Carbon
`RegisterEventHotKey` instead, which consumes the event and needs no permission
at all. Carbon reports a *held* chord as repeated presses, so it debounces:
without that, holding the keys flips hands-free back and forth and reads as the
shortcut not working. Toggling is also serialized in `MenuBarController` —
`startHandsFree` takes seconds to load its models, and a press arriving inside
that window would queue up and undo the switch the moment it finished.

**A first-partial number means nothing unless the audio is replayed in real
time.** `--selftest` feeds a whole utterance as fast as the CPU can push it, so
its "20–24 ms to first partial" is the time to process audio already in hand,
not the lag anyone perceives. `--testcompare` paces replay to the speed the
audio was spoken, and Apple's first partial lands at ~1.0 s. Both numbers are
real; only the second is what a user waits. The three Nemotron latency tiers
report 2.35 s / 1.24 s / 0.63 s under real-time replay, matching their designed
2.24/1.12/0.56 s chunks — that agreement is what says the measurement is sound.
A partial arriving *after* the audio ends is not counted at all, or a batch
engine reports live text it never showed.

Silero's silence threshold rounds up to whole 256 ms chunks, so only multiples
matter. Measured wait before text appears: 250 ms → 0.68 s, 500 ms → 0.98 s
(the default), 750 ms → 1.22 s. Start lag is 300 ms worst case.

`E5RT encountered an STL exception … zero shape error` during Parakeet TDT load
is emitted by Core ML itself, the models load anyway, and the results are exact.

Cleanup, on a rambling sample at Light: Apple Foundation and Gemma 3 4B both
clean it properly, and so does Qwen3 4B — it removes "the the" and "i i" in
1.2 s. The earlier note here saying it did not was measuring the reasoning arm
falling back to the raw transcript; see the Qwen3 entry above. Gemma 3 1B
leaves "i i" and "um". Qwen3 1.7B was recorded as echoing the input unchanged,
which is the same signature and has not been re-measured.

The two models built into macOS are the best of the ten. The downloadable ones
exist for when Apple Intelligence is unavailable.
