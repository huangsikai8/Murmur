<div align="center">

<img src="Resources/murmur-logo.png" width="128" alt="Murmur">

# Murmur

**Push-to-talk dictation for macOS that never mangles your text.**

Hold a key, speak, release — the sentence appears in whatever field had focus.
Menu bar only. Everything runs on your Mac. No API keys, no accounts, no
per-minute cost.

<sub>
macOS 26 (Tahoe) · Apple Silicon · Swift 6 · 135 passing tests
</sub>

</div>

---

## Why another dictation app

Most dictation tools type your words in keystroke by keystroke, or splice
revised guesses into text they already delivered. That is where `act ually` and
`feature .` come from. Murmur treats the transcript as something that can never
be corrupted: nothing speculative reaches your application, and the final text
crosses over as a **single** paste.

Around that guarantee it adds the things that make dictation actually fast — the
microphone is already open when you press the key, the trailing audio is waited
for exactly as long as it takes, and an optional on-device language model tidies
the result before it lands.

| | |
| --- | --- |
| 🔒 **On-device** | Speech and cleanup both run locally. Nothing is uploaded, nothing is logged to disk. |
| ⚡ **Fast off the mark** | Key-to-microphone is 0.0–7.3 ms. Opening the device on demand cost up to half a second, all of it taken off your first word. |
| 🗣️ **Three ways to talk** | Hold a key, tap to start and tap to stop, or hands-free with turn detection. |
| 🧠 **13 speech models** | Apple's built-in recognizer plus Parakeet, Nemotron, Moonshine and Whisper — swappable from the menu bar. |
| ✨ **Optional AI cleanup** | Three strengths, from tidying punctuation to reshaping a ramble into sentences. Guarded so it can never invent words. |
| 📋 **Your clipboard survives** | Captured before the paste, restored after, and skipped if you copied something in the meantime. |

## Contents

[Install](#install) · [First run](#first-run) · [Using it](#using-it) ·
[Models](#models) · [Custom vocabulary](#custom-vocabulary) ·
[Spoken formatting](#spoken-formatting) · [Privacy](#privacy) ·
[Architecture](#architecture) · [Development](#development) ·
[Troubleshooting](#troubleshooting)

## Install

### Requirements

macOS 26 (Tahoe) on Apple Silicon.

Command Line Tools alone are enough for the built-in Apple engines and every
Core ML speech model. The downloadable **language** models additionally need
full Xcode plus the Metal toolchain, because MLX compiles Metal kernels at build
time:

```sh
xcodebuild -runFirstLaunch
xcodebuild -downloadComponent MetalToolchain
```

### Build

```sh
git clone https://github.com/<you>/Murmur.git
cd Murmur
./scripts/build-app.sh            # debug
./scripts/build-app.sh release    # release
open build/Murmur.app
```

Murmur has no Dock icon. Look for the microphone glyph in the menu bar.

The build signs with a self-signed identity so that macOS keeps your Microphone
and Accessibility grants across rebuilds — ad-hoc signing would make you
re-approve both every time. Override it with
`MURMUR_SIGN_IDENTITY="Your Identity" ./scripts/build-app.sh`.

## First run

### Free up the Globe key

Set **System Settings › Keyboard › Press 🌐 key to → Do Nothing**. By default
macOS gives Fn/Globe its own behaviour — emoji picker or input-source switching
— which fights Murmur and steals focus.

If you would rather leave Globe alone, pick another trigger from the menu bar
under **Hold-to-Talk Key**. Right Option is the least contested alternative;
Right Command, Right Control, Control-Space and F13–F19 are also available.

### Grant two permissions

| Permission | Why |
| --- | --- |
| **Microphone** | Capture speech. |
| **Accessibility** | See the hotkey while another app is frontmost, and post the paste keystroke into it. |

Input Monitoring is deliberately **not** requested — `NSEvent` global monitors
cover the hotkey without it.

### About the orange microphone indicator

Murmur holds the input device open while it runs, so pressing the key only
switches where audio goes rather than opening a device. macOS shows the orange
indicator for as long as that device is open.

Nothing is transcribed, inserted or written to disk unless you start a
dictation. While idle, audio is kept for 0.3 s — so a syllable begun just before
the key still arrives — and then discarded.

Turn it off under **Keep Microphone Open** in the menu bar, or in
**Settings › General**, at the cost of the first fraction of a second of each
utterance.

> macOS keeps the indicator lit for several seconds after *any* app releases the
> microphone, so switching this off and watching the menu bar looks like nothing
> happened. The line under the menu item reads the real state from CoreAudio and
> says **Microphone: open** or **Microphone: closed**.

## Using it

### Three modes

| Mode | How it works | Best for |
| --- | --- | --- |
| **Hold to talk** | Hold the key, speak, release. You own both boundaries. | The default. Short and medium utterances. |
| **Tap to start, tap to stop** | Tap once to begin, tap again to finish. No silence threshold at all, so a pause to think costs nothing. | Long passages, or if holding a key is uncomfortable. |
| **Hands-free** | Speaks continuously; a voice-activity detector segments utterances and a turn detector decides when a thought is actually finished. | Drafting out loud, dictating over minutes. |

Hands-free is toggled from the menu bar, or with a global shortcut you assign in
**Settings › General**. It stops itself after an idle period (30 minutes by
default).

### While you speak

A small floating card shows the live transcript and a level meter. It is a
non-activating panel and the app is an accessory, so focus never moves and your
caret stays where it was.

The meter has five styles in **Settings › General** — a scrolling waveform (the
default), a pulse, real frequency bands from a live FFT, bouncing bars, and the
iOS 9 Siri wave. All five draw the same measurement in the same fixed box.

- **Escape** cancels without inserting anything.
- **Return** finalizes immediately, in either mode. It is consumed, because
  Return submits in most apps and would otherwise fire before your text arrived.
- Say **"scratch that"** to retract the last insertion (also "delete that",
  "undo that", "forget that"), within 60 seconds. The phrase has to be the whole
  utterance — saying it inside a sentence is you talking about scratching
  something, not asking for it.
- A press shorter than 250 ms is treated as an incidental tap and inserts
  nothing, so brushing Fn never pastes.

### AI cleanup

Off by default. Three strengths, chosen from the menu bar or **Settings › Cleanup**:

| Level | What it does |
| --- | --- |
| **Off** | Insert the raw transcript. Fastest. |
| **Light** | Remove fillers, fix punctuation and capitalization. |
| **Medium** | Also fix grammar, drop false starts and repetitions. |
| **High** | Also reshape rambling into clear sentences. |

Cleanup output is never trusted. `CleanupGuard` rejects assistant phrasing,
vocabulary the speaker never used, and implausible length ratios — falling back
to the raw transcript. It is also bounded in time: after 20 s the raw transcript
goes in regardless, because insertion is serialized and one stalled pass would
hold up every sentence behind it.

### History

The last 20 inserted transcripts are kept in **Settings › History**, so you can
recover one if focus moved or a paste landed somewhere unexpected. Capped
deliberately — nobody wants a growing archive of everything they have ever
dictated.

### Compare Models…

The menu bar's **Compare Models…** records you once and replays that single
recording through every model you pick, side by side, with contested words
highlighted. Each row chooses its own speech model, cleanup model and strength,
and "Run again" replays the *held* recording so you can add a row without
speaking twice.

Models run one at a time, so peak memory stays at a single model and no model's
timings are distorted by another competing for the ANE. Rows sharing a speech
model decode once and fan the text out. Nothing is persisted; closing the window
releases every model it loaded.

This is the only way to answer "which model is best **for my voice**" — every
other measurement in this project uses synthesized speech.

## Models

Nothing is bundled. Everything not built into macOS is downloaded only when you
ask for it in **Settings › Models**, and that first download is the only step
that needs a network.

### Speech

| Model | Size | Runtime | Live text | Punctuates |
| --- | --- | --- | --- | --- |
| **Apple SpeechAnalyzer** | built in | macOS | ✅ | ✅ |
| NVIDIA Parakeet Realtime EOU 120M | 250 MB | Core ML | ✅ | ❌ |
| NVIDIA Nemotron Streaming 0.6B (English) | 599 MB | Core ML | ✅ | ✅ |
| NVIDIA Nemotron Streaming 0.6B (1.12 s) | 613 MB | Core ML | ✅ | ✅ |
| NVIDIA Nemotron Streaming 0.6B (0.56 s) | 613 MB | Core ML | ✅ | ✅ |
| Moonshine Small Streaming | 400 MB | Moonshine C++ | ✅ | ✅ |
| Moonshine Medium Streaming | 1.1 GB | Moonshine C++ | ✅ | ✅ |
| NVIDIA Parakeet TDT 0.6B v2 | 452 MB | Core ML | ❌ | ✅ |
| OpenAI Whisper Tiny (English) | 153 MB | Core ML | ❌ | ✅ |
| OpenAI Whisper Base (English) | 146 MB | Core ML | ❌ | ✅ |
| OpenAI Whisper Small (English) | 487 MB | Core ML | ❌ | ✅ |
| OpenAI Whisper Medium (English) | 1.5 GB | Core ML | ❌ | ✅ |
| OpenAI Whisper Large v3 Turbo | 1.6 GB | Core ML | ❌ | ✅ |

Sizes are measured on disk after a real download, not read off Hugging Face —
the Parakeet TDT repository totals ~2.6 GB because it carries several
precisions, but only one set is fetched.

**Live text** means the model produces a transcript while you are still
speaking. Models without it decode on release, so nothing appears until you let
go. Each model declares this, and a test enforces that the claim matches the
engine behind it — a model wrongly marked live would show an empty overlay for
the whole hold and read as broken.

Notes worth knowing:

- **Parakeet EOU** emits lowercase text with no punctuation, so it needs cleanup
  switched on to be readable.
- **Nemotron** comes in three latency tiers — 2.24 s (listed as "English"),
  1.12 s and 0.56 s — which are separate downloads and coexist on disk. All
  three are equally accurate; the tier only changes how often the overlay
  updates while you speak.
- **Moonshine's** English models are MIT licensed and its other languages are
  non-commercial, so only English is offered.
- **Whisper** ships as OpenAI's English-only checkpoints, except Large v3 Turbo,
  which has no English release and is pinned to English instead. Whisper also
  invents words in silence — it was trained on captioned audio — so Murmur wraps
  it in a three-layer guard that drops near-silent audio, letterless output, and
  the stock filler phrases.

### Cleanup

| Model | Size | Runtime |
| --- | --- | --- |
| **Apple Foundation Model** | built in | macOS |
| Qwen3 4B | 2.3 GB | MLX |
| Gemma 3 4B | 2.5 GB | MLX |
| Qwen3 1.7B | 1.0 GB | MLX |
| Gemma 3 1B | 700 MB | MLX |

Apple's built-in model is both the best and by far the fastest here — roughly
290 ms against seconds for the MLX models. The downloadable ones exist for when
Apple Intelligence is unavailable.

> **On a 16 GB Mac**, the 4B MLX models are only comfortable when little else is
> running. They need ~2.3 GB resident; if anything evicts them, every token
> re-faults and a one-second cleanup becomes tens of seconds.

## Custom vocabulary

**Settings › Words** holds names and terms that matter to you. Each one is
applied at three points, because no single mechanism is sufficient:

1. **Recognition bias** — terms are passed to `AnalysisContext`, making the
   recognizer likelier to hear "Claude" than "cloud" in the first place.
2. **Context-aware repair** — the cleanup model is told which words are confused
   for which and decides from the surrounding sentence. "I asked cloud to review
   my code" becomes Claude; "I stored the file in the cloud" does not.
3. **Deterministic spelling** — canonical casing is enforced last, after
   cleanup, so neither model can undo it. "vscode" becomes "VS Code".

Blind find-and-replace is opt-in per term, and the UI warns that it will rewrite
ordinary uses of the everyday word.

## Spoken formatting

A deterministic pass runs *before* any model sees the text, so spoken commands
are already punctuation by the time cleanup happens. It costs 0.3 ms with every
rule enabled.

| Rule | Example | Default |
| --- | --- | --- |
| Spoken punctuation | "comma" → `,`, "new line" → a line break | **on** |
| Filler removal | drops standalone "um" and "uh" | **on** |
| Numbers | "twenty twenty six" → `2026` | off |
| Currency | "five dollars" → `$5` | off |
| Lists | "bullet buy milk" → `- buy milk` | off |
| Markdown | "heading intro" → `# intro` | off |

Every rule that can change *meaning* is off by default. Punctuation, fillers,
capitalization and spacing are on, because none of them can alter what a
sentence says.

## Privacy

- Speech recognition and cleanup both run on this Mac. No audio or text leaves
  it, at any point, in any mode.
- The only network access is downloading a model you explicitly asked for.
- Audio is never written to disk. The idle pre-roll is 0.3 s held in memory and
  discarded.
- `~/Library/Logs/Murmur.log` records timings and status, not your transcripts.
  It is rewritten on every launch.
- History keeps the last 20 insertions in your user defaults, and can be cleared
  from Settings.

## Architecture

```
microphone → AudioCapture → SpeechRecognitionEngine → TranscriptBuffer
                  │                                        │
            level meter                         SpokenFormatter (deterministic)
                  ↓                                        ↓
            OverlayPanel                        TranscriptCleaner (optional, guarded)
                                                           ↓
                                                Vocabulary → TextInserter
```

| Piece | File | Role |
| --- | --- | --- |
| Hotkey | [`HotkeyMonitor.swift`](Sources/MurmurApp/HotkeyMonitor.swift) | Hold and latch modes, no permission beyond Accessibility |
| Toggle shortcut | [`ToggleShortcut.swift`](Sources/MurmurApp/ToggleShortcut.swift) | Carbon hotkey for hands-free, consumes the chord |
| Capture | [`AudioCapture.swift`](Sources/MurmurCore/AudioCapture.swift) | Holds the device open, swaps the sink per session |
| Recognition | [`SpeechRecognitionEngine.swift`](Sources/MurmurCore/SpeechRecognitionEngine.swift) | One protocol, five engine implementations |
| Segmentation | [`VoiceActivityDetector.swift`](Sources/MurmurCore/VoiceActivityDetector.swift) | Silero VAD, with a pre-roll so no first word is lost |
| Turn detection | [`TurnDetector.swift`](Sources/MurmurCore/TurnDetector.swift) | smart-turn v3: is the *thought* finished? |
| Assembly | [`TranscriptBuffer.swift`](Sources/MurmurCore/TranscriptBuffer.swift) | Merges volatile and final results |
| Spacing | [`TextNormalizer.swift`](Sources/MurmurCore/TextNormalizer.swift) | Punctuation-safe joining |
| Formatting | [`SpokenFormatter.swift`](Sources/MurmurCore/SpokenFormatter.swift) | Spoken commands into real punctuation |
| Cleanup | [`TranscriptCleaner.swift`](Sources/MurmurCore/TranscriptCleaner.swift) | Apple Foundation or MLX, behind a guard |
| Insertion | [`TextInserter.swift`](Sources/MurmurCore/TextInserter.swift) | One atomic paste, clipboard restored |
| Overlay | [`OverlayPanel.swift`](Sources/MurmurApp/OverlayPanel.swift) | Non-activating floating panel, five meter styles |

### Why text cannot be corrupted

These are invariants, not intentions, and the test suite enforces each one:

- Volatile results go **only** to the overlay. Nothing speculative is ever
  inserted.
- The final transcript crosses into the target app as **one** pasteboard value
  and one Command-V, so it cannot arrive in fragments.
- `TextNormalizer.finalize` may only ever **remove** whitespace. Joining may
  insert a space only *between* two recognizer chunks. No rule can put a space
  inside a word or a decimal number.
- Cleanup output is validated before it is trusted, and falls back to the raw
  transcript when it is not.

A test streams every reference sentence one word at a time, and again at every
whitespace split point, requiring byte-exact reconstruction each time.

### Why turn detection instead of a silence timer

Silence duration is a poor proxy for "they are finished" — people pause
mid-sentence several times a minute, and endpointing on silence alone commits at
every one. That is what makes most hands-free dictation feel time-pressured,
since insertion cannot be taken back.

Murmur asks [smart-turn v3](https://huggingface.co/pipecat-ai/smart-turn-v3) whether
the *thought* is complete, which lets the silence threshold drop rather than
rise. One decision costs 28.9 ms next to a ~980 ms endpoint. A held turn has a
3-second ceiling, so a wrong hold is a slow sentence rather than one that never
arrives.

### Two build systems, on purpose

Both are needed and neither can be dropped:

- **SwiftPM builds the app.** `xcodebuild` cannot: FluidAudio's
  `NemoTextProcessing.xcframework` and Moonshine's `Moonshine.xcframework` both
  emit `include/module.modulemap`, and Xcode fails with "Multiple commands
  produce".
- **xcodebuild builds the MLX Metal library**, via `tools/MetallibBuilder`.
  SwiftPM cannot compile `.metal` sources, so an MLX binary it builds dies at
  runtime with "Failed to load the default metallib".

`scripts/build-app.sh` runs both and caches the metallib between builds.

## Development

```sh
swift run MurmurTests                    # 135 tests, no Xcode needed
./scripts/build-app.sh debug             # build, sign, assemble
swift scripts/make-icon.swift            # regenerate the app icon (rarely needed)
```

The built binary doubles as a test harness. Each command drives the real
pipeline rather than a mock:

```sh
M=./build/Murmur.app/Contents/MacOS/Murmur

$M --diagnose                    # permissions, installed models, audio formats
$M --selftest [modelID]          # real recognizer, end to end, via `say`
$M --testhandsfree [modelID]     # continuous dictation and segmentation
$M --testcompare [seconds]       # one recording through every installed model
$M --testmic [iterations]        # capture timing, pre-roll, format switching
$M --testtail [modelID]          # last-word survival on an abrupt cut
$M --testvad [silenceSeconds]    # detector start and end lag
$M --testturn [modelID]          # turn detection against a real voice
$M --testsilence [modelID]       # holding the key with nobody speaking
$M --testcleanup                 # cleanup at all three strengths
$M --testcleanup-mlx [modelID]   # the same, on a downloaded MLX model
$M --testformatting              # spoken punctuation and number rules
$M --testhomophones              # "cloud" vs "Claude" disambiguation
$M --testfocus                   # which accessibility query answered
$M --download [modelID]          # fetch a model; omit the id to list them
```

A few of these are worth singling out:

- **`--selftest`** renders sentences with `say`, streams them through the live
  recognizer, and checks what comes out. It fails only on assembly corruption —
  a misheard word from synthesized speech is reported but tolerated.
- **`--testsilence`** holds the key with nobody speaking, in four flavours of
  room tone, and requires every result to be empty. Words there are words nobody
  said. It exists because Whisper produces them.
- **`--testtail`** cuts audio at the last sample of speech; `--testtail --clip
  500` removes real speech and must *fail*, because a tail test that cannot fail
  says nothing.
- **`--testturn`** is the one test that needs a real voice: synthesized speech
  ends every utterance on the same falling contour, so `say` rates even "the
  meeting is on" as a complete thought.

### Measured results

Speech accuracy, `--selftest`, 4 sentences: Apple SpeechAnalyzer 4/4, Nemotron
4/4, Moonshine Small and Medium 4/4, Parakeet TDT v2 4/4, Whisper Base and Large
v3 Turbo 4/4, Parakeet EOU 2/4 and unpunctuated.

Latency from the end of speech to text on screen:

| Stage | Cost |
| --- | --- |
| Hotkey to microphone armed | **0.0–7.3 ms** (was 155–466 ms) |
| Release to last buffer, push-to-talk | **9–110 ms, median 78** (was a flat 160 ms) |
| Detector endpoint, hands-free at 500 ms | ~980 ms |
| Engine finalize — Parakeet TDT | 103 ms |
| Engine finalize — Apple SpeechAnalyzer | 115 ms |
| Engine finalize — Nemotron 560 ms | 152 ms |
| Engine finalize — Moonshine Small | 636 ms average, 975 ms worst |
| AI cleanup, Apple Foundation at Medium | ~290 ms |
| Spoken formatting, every rule on | 0.3 ms |

In hands-free the detector dominates at roughly two thirds of the total;
dropping its threshold to 250 ms removes ~300 ms.

## Troubleshooting

<details>
<summary><strong>Murmur is missing from Privacy &amp; Security › Microphone</strong></summary>

The app is signed with the hardened runtime, which denies the microphone
outright — without prompting, and without listing the app — unless
`com.apple.security.device.audio-input` is present in `Murmur.entitlements`. A
real prompt takes seconds; an instant denial means the entitlement is missing.

```sh
./scripts/build-app.sh
tccutil reset Microphone com.sikaihuang.murmur
```

Then relaunch.
</details>

<details>
<summary><strong>The app launches but nothing happens</strong></summary>

Check `~/Library/Logs/Murmur.log`, rewritten on every launch. A healthy start
looks like:

```
applicationDidFinishLaunching
status item created
bootstrap started
requesting microphone access
microphone granted=true
accessibility trusted=true
hotkey monitor started
warmUp finished, status=idle
```

If the log is empty or stops before `applicationDidFinishLaunching`, the main
thread is not owned by AppKit. `main.swift` must stay synchronous: a top-level
`await` hands the main thread to the concurrency runtime, and an app started by
LaunchServices then never receives `applicationDidFinishLaunching`. Running the
binary from a terminal hides this, because there is no launch event to wait for.
</details>

<details>
<summary><strong>The build hangs</strong></summary>

Almost always the keychain dialog waiting behind another window for "Always
Allow" on the signing identity.
</details>

<details>
<summary><strong>The app icon looks stale after a rebuild</strong></summary>

macOS caches icons by bundle path, so Privacy &amp; Security and the permission
prompt can keep showing an old icon while the bundle on disk is correct. Do not
debug this from the settings pane — logging out clears the cache.
</details>

<details>
<summary><strong><code>E5RT encountered an STL exception … zero shape error</code></strong></summary>

Emitted by Core ML itself during Parakeet TDT load. The models load anyway and
the results are exact.
</details>

<details>
<summary><strong>Changes to the app do not take effect</strong></summary>

A rebuilt bundle changes nothing until the resident menu-bar app is quit and
relaunched. Quit from the menu bar, then `open build/Murmur.app`.
</details>

## Built with

[FluidAudio](https://github.com/FluidInference/FluidAudio) ·
[moonshine-swift](https://github.com/moonshine-ai/moonshine-swift) ·
[WhisperKit](https://github.com/argmaxinc/WhisperKit) ·
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) ·
[swift-transformers](https://github.com/huggingface/swift-transformers) ·
Apple `SpeechAnalyzer` and Foundation Models

## License

No license has been chosen yet — all rights reserved by default. Get in touch
before reusing this code.

Model weights carry their own terms regardless. Moonshine's English models are
MIT and its other languages are non-commercial, which is why only English is
offered here.
