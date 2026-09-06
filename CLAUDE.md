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
indicator staying lit, so `Preferences.keepMicrophoneArmed` can turn it off,
and `Preferences.microphoneIdleMinutes` (default 15, 0 = never) closes it again
once it has gone that long unused — an indicator lit all evening for a
dictation nobody is going to make is a claim on attention the app has not
earned, and the next press pays the reopen once. That close is deliberate, so
`DictationController.microphoneClosedWhileIdle` marks it and the self-healing
below refuses to undo it; the menu says "Microphone: closed (idle)" rather than
plain "closed", because the ticked switch over a shut device otherwise reads as
the bug immediately below. The close is not punctual and does not need to be:
measured at a 1-minute setting it fired at 63.7 s and 65.1 s, which is macOS
coalescing the timer of a background `LSUIElement` process. Do not tighten this
into a poll — nothing downstream cares about the exact second, and the whole
point of the entry is to stop *wasting* the device.
While idle the buffers go into a 300 ms rolling pre-roll and are discarded, and
that pre-roll is replayed when a session starts — so a syllable begun just
before the key still reaches the recognizer.

**macOS keeps the microphone indicator lit after the device is released.** So
switching `keepMicrophoneArmed` off and watching the menu bar looks exactly
like the setting doing nothing — which is what it looked like, and it was
working. Do not debug this from the indicator. `AudioCapture.isArmed` is this
app's bookkeeping *reconciled with* `AVAudioEngine.isRunning`, for the reason
in the next entry; `AudioCapture.systemReportsInputRunning` asks CoreAudio
for `kAudioProcessPropertyIsRunningInput` on our own process, which is the
signal the indicator itself follows. It is what the menu bar's "Microphone:
open / closed" line reads, what `armMicrophone` and the preference log, and
what `--testmic` asserts on — measured, `stop()` really does release the device
and the property goes false. The property does not update synchronously with
the stop, so every reader waits a moment first.

**`AVAudioEngine` stops itself on a configuration change and never starts
again.** A device appearing or disappearing, a sample rate changing, waking
from sleep — macOS tears the graph down, removes the tap, and posts
`AVAudioEngineConfigurationChange`. Nothing observed it, so `isRunning` and
`tapInstalled` went on saying "open" forever. Two failures, and the quiet one
is the worse: `armMicrophone`'s `guard !capture.isArmed` returned early, so the
switch stayed ticked over a shut microphone (which is exactly what it looked
like from the menu bar, since that line reads CoreAudio and CoreAudio was
right); and `startLocked` skipped both the tap install and `engine.start()`, so
a dictation in that state showed an overlay, moved the meter, and **recorded
silence**. `AudioCapture` now observes the notification and rebuilds — new
converter, since the input format may differ, and the pre-roll dropped for the
same reason `prearm` drops it — while `isArmed` and `startLocked` treat the
engine, not the flag, as the authority. `capture.diagnosticLog` is what puts
any of this in `Murmur.log`; without it the only trace was the microphone
behaving oddly some minutes later. `rearmMicrophoneIfNeeded` is the second
half: `applyPreferences` only reacts to a *changed* preference, so a device
closed by something else stayed closed, and it is now also called when the menu
opens and after `fail()` — which closes the device to recover and never used to
reopen it.

**Never react to `AVAudioEngineConfigurationChange` on the thread it arrives
on.** The observer was registered with `queue: nil`, which delivers the
notification *synchronously on whatever thread posted it* — and AVAudioEngine
posts this one from its own internal audio thread while it is part-way through
reconfiguring itself. `handleConfigurationChange` then took `lock` and called
`startLocked()`, so `engine.start()` and `installTap` were reentrant calls into
an engine still holding its own state down. That blocks, with `lock` held, and
the next press on the main thread blocks behind it — permanently. The app has to
be force-quit.

The recipe is exact and it is somebody's ordinary afternoon: dictate on
Bluetooth (refused, see the entry below), unplug the headset, switch output back
to the built-in speaker, press again. Switching device produces a *burst* of
configuration changes, not one. Captured in `Murmur.log`:

    13:59:21.750  dictation press ignored: default input is Bluetooth
    13:59:24.887  audio configuration changed while the microphone was closed
    13:59:29.634  main thread stalled past 1.0 s

with no `main thread answering again` line ever written. The reaction now hops
to `configurationQueue`; it is the same work done anywhere else.

**And the main thread must never wait on `lock` without a limit.** That is the
second half, and it is what makes the failure survivable rather than merely less
likely: `lock` is held across `engine.start()`, which is 15-472 ms normally and
seconds on a device CoreAudio is still tearing down. Every caller — a press, the
menu opening, a preference changing, `isArmed` — is on the main thread, so an
unbounded wait is not a slow microphone. It is an app that has stopped
answering, and with the finalize tap on the main run loop it is a keyboard that
has stopped working in every application. `acquireLock` gives up after 500 ms
and throws `deviceBusy`; a refused press is recoverable by pressing again, and a
wedged main thread is recoverable only by force-quitting. `startLocked` also
logs any open past 250 ms, because nothing else is written between the press and
the audio and a slow open was invisible.

`AudioCapture.holdDeviceLockForTesting` manufactures the condition, since the
only other recipe is to physically disconnect a headset — same reasoning as
`WhisperEngine.forcedSampleLength`. Two tests in `Sources/MurmurTests/` assert
the press is refused rather than queued.

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

**A view that reads a store once shows a list frozen at whenever it appeared.**
`HistorySettings` loaded in `.onAppear`, and the settings window is built once
and kept (`isReleasedWhenClosed = false`) — so it fired the first time that tab
was shown and never again. Dictate, reopen settings, and the history is exactly
as it was, which reads as transcripts not being recorded at all when in fact
every one of them was stored correctly and survived restarts. `HistoryStore`
now posts `didChangeNotification` and `HistoryModel` observes it. The post
happens *outside* the store's lock: the observer reacts by reading `entries`,
which takes that same lock.

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

**`SMAppService.Status.notFound` does not mean the bundle is broken.** It is
what a copy that has *never* been registered reports, and it registers from
there perfectly well. Measured on the build-directory copy: status 3
(`.notFound`) → `register()` → 1 (`.enabled`), with the record visible in
`sfltool dumpbtm` pointing at that path; `unregister()` → 0
(`.notRegistered`), leaving a disabled record behind. So the three "off" states
are not interchangeable, and only `.requiresApproval` — registered, switched
off by hand in System Settings, where registering again does nothing — is worth
telling anyone about. `LoginItem` reads the service rather than storing a bool,
for the same reason the microphone switch reads the engine: System Settings can
revoke the registration without telling the app, and a stored bool would tick a
switch over nothing. It is refreshed in `SettingsWindowController.show()`, not
`.onAppear`, because that window is built once and kept.

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

**Saving the clipboard before a paste is free, and looks expensive.**
`ClipboardPasteInserter` deep-copies every representation of every pasteboard
item before it clears the board, which reads like tens of megabytes copied
between the final transcript and the paste whenever a screenshot is on the
clipboard. It is not: `NSPasteboardItem` data is copy-on-write, so the copy
never touches the bytes. Measured — short text 0.013 ms, a 2880x1800 screenshot
as TIFF alone (166 MB) 0.012 ms, the same as TIFF + PNG (167 MB) 0.059 ms. Do
not "fix" this by snapshotting earlier and reusing it under a `changeCount`
guard: it buys 0.06 ms and puts new logic in the one path that can destroy the
user's clipboard. The snapshot is now skipped entirely unless the verdict is
`.acceptsText`, which is the only path that restores.

**Putting the clipboard back on a timer pastes the *previous* transcript.**
The restore was `asyncAfter(0.35 s)`, which is a guess about another process's
schedule, and Chromium — Chrome, VS Code, Electron, so most of what anyone
dictates into — reads the pasteboard *asynchronously* after the ⌘V is
delivered. A busy renderer reads it after the restore and pastes whatever was
put back. What gets put back is the sharp end: two outcomes deliberately leave
the transcript on the clipboard and never restore (`leftOnClipboard`,
`pastedUnverified` — 9 and 5 of them in one real log), and the `changeCount`
guard skips the restore on a third, so the value sitting there when the next
dictation starts is very often *the last transcript*. The next insertion then
snapshots it as "the user's clipboard" and hands it back mid-paste. The
symptom is a hold that pastes the sentence before it, occasionally, in web
apps, and it is invisible from every log line the app writes — the transcript
is correct, the insertion is correct, the paste lands.
Both halves are fixed and both are needed. `isOurs` compares the pasteboard's
`changeCount` against the one Murmur last wrote, and a board that is still
exactly Murmur's own is never restored — so a late read can now only ever
paste the *current* transcript twice, never a stale one. The change count, not
the text: a speaker who copies the sentence they just dictated has a clipboard
of their own that reads identically. And `scheduleRestore` waits for the paste
to be *seen* — `focusedElementWatcher` reads `AXNumberOfCharacters` and
`AXSelectedTextRange` on the focused element before the ⌘V and polls them every
20 ms, restoring as soon as either moves, with 1.5 s as a ceiling rather than
a schedule. Never the element's value: a paste moves the length and the caret,
and reading the text of a large document to compare it would cost more than
the wait it is shortening. `--testpaste` is what says the watcher can watch at
all — an element that reports neither attribute cannot be watched, and every
insertion then falls back to the ceiling, which would make this change a
*slower* restore and nothing else.
Measured with `--testpaste`, idle: TextEdit 22–24 ms, Chrome 23–60 ms, VS Code
23–67 ms, against the flat 350 ms it used to wait. That is the shape of the
bug — the old delay is *usually* generous, which is why this failed a few
times a day rather than every time, and why nothing in the log ever pointed at
it. The confirmation also costs something on the way in: `insert` itself takes
51–66 ms the first time it touches an application and 2–5 ms after, because
`focusedElementWatcher` asks `describeFocus` a second time and the first ask of
a Chromium process builds its accessibility tree.
`--testpaste` reports the extent before and after each paste for a reason: when
a paste is *not* confirmed the two are identical, which says the text went
somewhere else rather than that the watcher is broken. Every unconfirmed run
here turned out to be exactly that — another application had taken keyboard
focus — and the ceiling still restored the clipboard, which is the behaviour
that has to hold when the answer cannot be known.

**`turnAudio` is the turn detector's window and nothing else's.**
`HandsFreeSession` kept an 8-second rolling window for every buffer whether or
not a detector existed — 576 KB resident and a ~512 KB memmove a second, for
audio only `endOfSpeech` reads and only under `if let turnDetector`. It is
maintained under the same condition now. Safe because `setTurnDetector` runs
before `capture.start`, so no buffer can arrive while the answer is unknown;
the ordering is what makes it safe, so do not move that call.

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
* **`withoutTimestamps` is not free, and nothing in the app reads a timestamp.**
  Whisper decodes a fixed 30-second window; WhisperKit walks anything longer by
  seeking to the last timestamp the decoder emitted. Asked to decode without
  them, `SegmentSeeker` has nothing to seek by and falls into
  `seek += segmentSize`, jumping a whole window — so everything the decoder
  stopped short of inside that window is dropped. No error, no warning, and the
  transcript reads perfectly well straight across the hole:

      … with nothing unusual in it at all. in the middle of the audio. I am …
                                          ^ one clause gone

  Measured on Large v3 Turbo over 57 s, 92 s and 171 s of speech: a clause
  vanished at every boundary and came back the moment timestamps were on, at no
  cost in time (4863 ms against 5641 ms). Base and Small survived synthesized
  speech either way, which is why `--selftest` never saw it — every other speech
  test here says one sentence and releases, so the seek loop was exercised by
  nothing at all. `--testlong` is the one that holds past 30 s.
* **Timestamps on means annotations and fillers, and both are answerable.**
  In that mode the model also emits `[BLANK_AUDIO]`, `[ Silence ]` and
  `(applause)` — ordinary text tokens, so `skipSpecialTokens` never touches
  them — and appends "Thank you." or "you" to a real transcript when the hold
  ended in silence. `stripNonSpeechAnnotations` removes the first by matching
  the *whole* bracketed span against a fixed list, never on the brackets alone:
  `SpokenFormatter` has no rule that produces a bracket, so one in a transcript
  is either the model annotating or the speaker dictating, and punctuation
  cannot tell those apart. The second is what `spansAudibleAudio` is for, and it
  is the guard timestamps make possible: a segment is dropped when *its own*
  span of audio is below the -45 dBFS ceiling. That is strictly better than
  matching phrases, which is why `isInventedSilence` may still only drop a hold
  entire — a real sentence elsewhere in the recording cannot vouch for a segment
  decoded out of nothing.
* **The decoder stops when it thinks the utterance is over, not when the audio
  runs out — and timestamps do not save you from that.** WhisperKit's seek loop
  advances to the last timestamp the decoder emitted; where the decoder emitted
  no usable one it does `seek += segmentSize`, a whole window. For a hold under
  30 s that window *is* the recording, so a single early stop ends the
  transcription there and the rest is thrown away. Nothing errors and the text
  reads perfectly across the hole — measured on a real latched hold, 20.4 s of
  speech came back as 39 words cut mid-clause (1.91 words/s against the 2–3
  ordinary dictation runs at), and 34.2 s came back as 26 words. `--testsilence`,
  `--testtail` and `--testlong` all passed throughout: `say` never does this.
  `WhisperEngine.decodeWholeHold` therefore lets the *audio* say how far the
  transcript should reach — any stretch no audible piece accounts for is decoded
  again on its own and slotted into place, head, middle or tail alike.
  Two things have to be right about that, and both were wrong first:
  * **A gap must be judged on how much of it is speech, not on its peak.** The
    peak is the loudest 25 ms, and the gap between two sentences opens on the
    tail of the word before it. Measured on `--testlong`, that alone sent five
    ordinary pauses to Turbo, which answered them with "- Right.", "you" and
    "Thank you." three times over — the invented speech `silenceCeiling` exists
    to keep out, let back in through the side door. `audibleExtent` requires a
    whole second of audio above the ceiling *inside* the gap, and the decode is
    trimmed to that extent plus 0.2 s, so the model is handed as little silence
    as possible. That also took the normal arm from 8 recovery passes and
    12.7 s on Turbo back to 0 passes and 3.9 s.
  * **A gap that is itself a whole window cannot be recovered by asking again.**
    The recovery hands the decoder the gap's own audio, which for an ordinary
    early stop is a short slice it has not seen — a different, easier question.
    For a gap spanning a *whole* 30-second window it is the same 30 seconds
    padded the same way, and the answer is the same nothing. Measured on a real
    55.2 s hold: Whisper Small returned nothing at all for 0.2-30.0 s, the
    recovery returned nothing for the same span, and `floor = gap.end` abandoned
    it for good — 36 words for 55 s of speech, **0.65 words/s** against the 2-3
    ordinary dictation runs at. Half the transcript, thrown away by a retry that
    could not have succeeded. Raising `maxRecoveryPasses` does not touch this
    and the log says so: 4 of 8 passes were used, and each gap is attempted
    exactly once whatever the budget. `decodeGap` now cuts a span that failed
    whole into 12-second pieces with 0.3 s of overlap, which are questions the
    decoder has not already refused; `subdivisionPlan` is pure and tested,
    because a plan that leaves a hole re-creates the defect and the transcript
    reads perfectly well straight across one.
  * **A gap re-decoded from a timestamp starts where the model stopped, not
    where the phrase did**, so the two decodes overlap by a few words at the
    seam ("… The barometer in the" / "The barometer in the hallway has been
    reading …"). `trimmingOverlap` removes it, only at a seam the recovery
    itself created and never for a single word — one repeated word is something
    people say.
* **A hold that produces nothing looks exactly like a hold nobody spoke into.**
  The transcript is empty either way, and `finishPipeline` used to hide the card
  for both — so a failed recognition is silent, nothing reaches the document,
  and the only evidence the words existed is a log file. Measured on a real
  session: three holds in one minute came back empty at -25 dBFS, a level the
  same session transcribed normally either side of them, with decodes 5-10x
  slower than usual. `AudioCapture.speechSeconds` is what separates the two
  cases, and it is the question **a peak cannot answer** — a peak is the loudest
  25 ms of the hold, so one door closing in a silent room reads exactly like
  somebody talking for six seconds. Counted from the slices `updateLevel`
  already measures, so it costs a comparison, and only while a session owns the
  device — idle audio goes into the pre-roll and is thrown away. Past 0.8 s of
  it, the card now says so and `Murmur.log` records it.
* **A slow decode is the only outward sign that Whisper gave up.** A window it
  has no confidence in is retried at rising temperatures — `firstTokenLogProb`,
  `compressionRatio`, `logProb` — and once the retries run out WhisperKit keeps
  whatever the last one gave, which can be nothing at all. Every retry is
  another full decode, so the count is visible in the time and nowhere else;
  `report` now prints it, because 2796 ms for 2.2 s of audio and 250 ms for the
  same audio are the same line otherwise. Not yet reproduced on a fixture:
  broadband noise at -25 dBFS does not trip it (it comes back as
  "(water running)" in 166 ms, no fallbacks), and `say` never does.
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

* A latch ends on **silence**, not on elapsed time. The thing worth ending is a
  *forgotten* latch, and a stopwatch cannot tell one of those from somebody with
  a lot to say — the flat two-minute cap ended both, mid-sentence and without
  warning. `AudioCapture.speechSeconds` counts only slices loud enough to be a
  voice, so a forgotten latch stops advancing it and a long dictation does not.
  `latchSilenceTimeout` is 90 s; `maximumLatchDuration` stays as a 15-minute
  backstop, because decode time scales with the audio and lands all at once when
  the key comes up — 55 s took 3.6 s on Whisper Small, so half an hour is
  roughly two minutes of staring at nothing.
* The recovery budget scales with the recording. Every 30-second window is its
  own chance to come back blank, so a constant sized for a one-minute hold runs
  out part-way through a five-minute one and abandons the rest silently.

`Sources/MurmurTests/` covers all of the above. Run it after any change to the
text path.

## Commands

```sh
./scripts/build-app.sh debug            # build + sign + assemble
swift scripts/make-icon.swift           # regenerate the app icon (rarely needed)
swift run MurmurTests                   # 166 tests, no Xcode needed
./build/Murmur.app/Contents/MacOS/Murmur --diagnose
./build/Murmur.app/Contents/MacOS/Murmur --selftest [modelID]
./build/Murmur.app/Contents/MacOS/Murmur --testcleanup
./build/Murmur.app/Contents/MacOS/Murmur --testcleanup-mlx [modelID]
./build/Murmur.app/Contents/MacOS/Murmur --testformatting
./build/Murmur.app/Contents/MacOS/Murmur --testvad [silenceSeconds]
./build/Murmur.app/Contents/MacOS/Murmur --testmic [iterations]
./build/Murmur.app/Contents/MacOS/Murmur --testpaste [iterations]
./build/Murmur.app/Contents/MacOS/Murmur --teststall [seconds]
./build/Murmur.app/Contents/MacOS/Murmur --testtail [modelID] [--clip ms]
./build/Murmur.app/Contents/MacOS/Murmur --testhandsfree [modelID]
./build/Murmur.app/Contents/MacOS/Murmur --testsilence [modelID]
./build/Murmur.app/Contents/MacOS/Murmur --testlong [modelID]
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

`--testpaste` measures the far end of an insertion, which no other test here
touches: how long the application in front takes to *read* the pasteboard after
the ⌘V is delivered. Click into a real text field first, as with `--testfocus`.
It has to be run against the applications actually dictated into, because the
answer is a property of them and not of Murmur, and it asserts the two things
that fail silently — that the focused element can be watched at all, and that
each paste was seen to land before the clipboard was put back.

`--testsilence` holds the key with nobody speaking, in four flavours of room
tone, and every result must be empty — words there are words nobody said. It
exists because Whisper produces them and nothing upstream stops it.

`--testlong` holds for one utterance of eight sentences with pauses between
them — 48 s, so it crosses a 30-second window boundary that every other speech
test here stops short of. Each sentence carries a distinct marker word, and a
missing marker is a sentence thrown away rather than a word misheard, which is
the only way that failure is visible at all. It also prints the engine's own
report of what it was handed, so the words-per-second figure a real session
writes to `Murmur.log` is exercised by a test. With no model ID it runs every
installed Whisper variant.

It then runs the **same hold a second time with the decoder forced to stop
early**, through `WhisperEngine.forcedSampleLength`. That is the one condition
no `say` fixture here has ever produced on its own and the one real speech
produces by accident, so it is manufactured rather than waited for. The second
arm is judged on the share of its own clean run's words it keeps, not on the
markers: a cap that short chops the decode mid-word and can genuinely destroy
one — "cardigan" survives one run and comes back as two words the next — while
the span is exactly what the recovery is responsible for. Measured, that
separates cleanly: **70–75% without the recovery, 99–101% with it.**

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

Idle cost, measured on the resident menu-bar process with the microphone armed
and nobody dictating: **0.07-0.08 s of CPU per 20 s of wall clock, ~0.4% of one
core**. That is the number to beat before optimizing anything for idle — the
per-buffer work is one conversion into the pre-roll, four `vDSP_measqv` passes
and about a kilobyte of array churn, ten times a second, and it does not show
up. Two rounds of tightening (dropping a dead per-slice array, hoisting the
spectrum band edges out of the per-slice loop) moved this measurement not at
all.

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

Long holds, `--testlong`, one 46.7 s utterance of 8 sentences with 2.5 s pauses:
Base, Small and Large v3 Turbo each keep all 8 marker words, at 2.6–2.7 words/s
against the 2.5 words/s that went in. Decode 930 ms / 1940 ms / 3900 ms, with no
recovery pass fired — on audio this clean the decoder does reach the end.
Forced to stop early, the same three keep 99–101% of those words with one
recovery pass each; without the recovery they keep 70–75%, losing a whole
sentence and reading straight across the hole. Before timestamps were turned on,
Turbo dropped a clause at the boundary in every run and the other two survived
synthesized speech, so a test on Base alone would have reported this fixed while
it was not.

A real session that returns far fewer words than were spoken now says so:
`whisper small: 48.4 s audio, peak -12.4 dBFS, decoded in 1963 ms -> 123 words
(2.54 words/s)` goes into `Murmur.log` on every hold. Ordinary dictation runs at
2–3 words/s; the failure this exists to catch read 0.14 words/s over a
41.7-second hold and was indistinguishable, from the outside, from a hold in
which almost nothing was said.

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

**An event tap on the main run loop makes a hung app a dead keyboard.**
`FinalizeKeyMonitor` installs an *active* `CGEventTap` and adds it to
`CFRunLoopGetMain()`, so every key press on the machine is routed through this
process's main thread and held until the callback returns. While the main
thread answers, that is fine. While it does not, it is not a frozen menu bar
icon — it is a keyboard that has stopped working in every application at once.
Observed on a real session: menu bar unresponsive, no key reaching any app, and
**Spotlight still typing normally**, which is the signature, because Spotlight
is serviced outside the session tap's path. Do not debug this as a keyboard
fault or a stuck modifier.
The app already contains stalls big enough to do it — a 4599 ms speech model
load is in an ordinary launch log, a 3569 ms Whisper decode in an ordinary
hold, and the `cleanup 75560 ms` recorded further down this file would take the
keyboard with it for over a minute.
The repair cannot live in the callback. Code that notices the stall and stops
consuming would itself run on the main thread, which is the thread that is
stuck, so it never executes. `CGEvent.tapEnable` is safe to call from any
thread, so `MainThreadWatchdog` pings the main thread every 100 ms from its own
queue and `KeyboardTapGate.suspend()` switches the tap off after 300 ms of
silence, resuming when the main thread replies. Measured with `--teststall`:
released **23 ms** into a manufactured 2 s stall, resumed on recovery. The cost
is that Return is not swallowed while suspended, which is one mistimed Return
against a keyboard that does not work anywhere.
The second half is that the callback must **not** undo it. macOS disables a tap
that is too slow and delivers `.tapDisabledByTimeout`, and the documented
recovery is to re-enable — but from inside the callback the system's timeout and
the watchdog's deliberate suspension look identical, and re-enabling the second
hands every keystroke straight back to a thread that is still stuck. The handler
checks `KeyboardTapGate.isSuspended` first.

**A hang leaves no evidence, and relaunching used to destroy what there was.**
There is no crash report, no spindump, and no log line saying the app stopped
answering — the only record is whatever it had written before it stopped. And
`Log.startSession()` did `removeItem` on `Murmur.log` at every launch, so the
first thing anyone does with a hung menu bar app, force-quit and start it again,
erased the run that mattered. It now moves the file to `Murmur.log.1` instead.
One generation is enough: the interesting run is always the one immediately
before the relaunch. `MainThreadWatchdog` also writes a stall past 1.0 s into the
log with the duration, so the failure names itself rather than being inferred
from a user saying the machine froze.

**A toggle shortcut cannot use the hold-to-talk mechanism.** `HotkeyMonitor`
uses passive `NSEvent` global monitors, which observe without consuming — fine
for holding a bare modifier, wrong for claiming a chord, because ⌥⌘D would also
reach the app in front and trigger its own. `ShortcutMonitor` uses Carbon
`RegisterEventHotKey` instead, which consumes the event and needs no permission
at all. Carbon reports a *held* chord as repeated presses, so it debounces:
without that, holding the keys flips hands-free back and forth and reads as the
shortcut not working. Toggling is also serialized in `MenuBarController` —
`startHandsFree` takes seconds to load its models, and a press arriving inside
that window would queue up and undo the switch the moment it finished.

**More than one chord means more than one monitor, and the single-shortcut
shape does not stretch.** `ShortcutMonitor` held the live instance in one
static `active` and registered every hotkey under id 1, which is invisible
while there is one shortcut and silently wrong the moment there are two: the
second instance replaces the first in `active`, and the Carbon handler cannot
tell the presses apart anyway. Each instance now takes its own id, the handler
is installed once for the process — `InstallEventHandler` on the dispatcher
target delivers *every* hotkey press to *every* handler installed — and it
dispatches on the id the event carries. Shortcuts are recorded from a real key
press rather than chosen from a list of five presets, so `KeyChord` stores the
key code, the Carbon modifier mask, and the label the key printed *at the time
it was recorded*: asking the current keyboard layout what `kVK_ANSI_D` prints
would relabel somebody's shortcut when they switch layout, while the key they
physically press has not moved. A chord with no ⌘, ⌥ or ⌃ is refused — a global
hotkey on a bare key claims it in every application for as long as Murmur runs,
and ⇧D is a capital D. `ShortcutRecorder` is a singleton for a reason of the
same kind: a local `NSEvent` monitor is not exclusive, so two fields left
recording at once would both claim the same press. `KeyChord` lives in
`MurmurCore` rather than beside the monitor for the same reason
`StartupAudioBuffer` does — the app target cannot be imported, so anything in
it is testable only through the app's own `--test…` commands.

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
