import AppKit
import AVFoundation
import Foundation
import MurmurCore

/// Orchestrates one dictation: hotkey down through insertion.
@MainActor
final class DictationController {

    enum Status: Equatable {
        case idle
        case preparing
        case listening
        case finishing
        case unavailable(String)
    }

    private(set) var status: Status = .idle {
        didSet { onStatusChange?(status) }
    }
    var onStatusChange: ((Status) -> Void)?

    /// Strength of the optional local cleanup pass.
    ///
    /// Setting it also prepares a session for that level. The cleanup model's
    /// instructions have to be prefilled before it can rewrite anything, and
    /// the level is always chosen long before anyone speaks — so that cost
    /// belongs here, not in the wait after an utterance ends.
    var cleanupLevel: CleanupLevel = .off {
        didSet { prepareCleanupLevel() }
    }

    /// The free deterministic pass. Runs before the model, so spoken commands
    /// are already punctuation by the time a cleanup model sees the text.
    var formatting = SpokenFormatter.Options()

    /// Longest a cleanup pass may be waited on before the raw transcript is
    /// inserted instead.
    ///
    /// Cleanup is the one stage with no bound of its own, and insertion is
    /// serialized, so a single runaway pass holds up every utterance behind it
    /// — a real session logged 75 s on an MLX model, by which time the words
    /// belong to a sentence the speaker finished a minute ago and to whatever
    /// application they have since moved to. Apple's cleaner costs ~290 ms and
    /// MLX ones seconds, so this only ever fires on a pass that has already
    /// stopped being useful.
    var cleanupDeadline: Duration = .seconds(20)

    private var engine: any SpeechRecognitionEngine
    private var cleaner: any TranscriptCleaner
    private let capture = AudioCapture()
    private let inserter: any TextInserting
    private let overlay = OverlayPanel()
    private let latency = LatencyTracker()
    private let vocabulary = VocabularyStore.shared

    /// Holds shorter than this are treated as an incidental key tap rather
    /// than dictation, and insert nothing. Fn in particular is used for other
    /// shortcuts, so a brief press must never paste into the focused field.
    var minimumHoldDuration: Duration = .milliseconds(250)

    private var buffer = TranscriptBuffer()
    private var updatesTask: Task<Void, Never>?
    private var focusTarget: FocusTracker.Target?
    /// Readable so the latch can ask whether a tap should start or finish.
    private(set) var isActive = false
    private var pressedAt: ContinuousClock.Instant?
    private var activeModelID = ModelCatalog.appleSpeechID
    /// False for engines that only produce text when the key is released. The
    /// overlay needs to say so rather than sit empty.
    private var engineStreamsLiveText = true
    private var meterTask: Task<Void, Never>?

    // MARK: Hands-free state

    private var handsFree: HandsFreeSession?
    private(set) var isHandsFree = false
    var onHandsFreeChange: ((Bool) -> Void)?
    /// Ordered path from the audio thread while hands-free is running.
    private let handsFreePipe = StreamPipe<AVAudioPCMBuffer>()
    private var handsFreeTask: Task<Void, Never>?
    /// Mirrors the session's own state so the overlay and meter can be driven
    /// from the main actor without awaiting the actor on every audio buffer.
    private var utteranceOpen = false
    /// Serializes transcript handling so two utterances can never paste at
    /// once. The single-value, single-paste guarantee depends on it.
    private var insertion: Task<Void, Never> = Task {}
    /// Puts a space between consecutive utterances. A pause mid-sentence ends
    /// one and starts another, and without this they arrive joined together.
    private var joiner = UtteranceJoiner()

    /// The last text actually placed in another application, so "scratch that"
    /// knows exactly how much to take back.
    private struct LastInsertion {
        let text: String
        let bundleIdentifier: String?
        let at: ContinuousClock.Instant
    }
    private var lastInsertion: LastInsertion?
    /// How long a retraction stays available. Long enough to notice a bad
    /// sentence and say so, short enough that it cannot fire against text
    /// typed by hand much later.
    var scratchWindow: Duration = .seconds(60)
    /// Whether "scratch that" is honoured at all. Off means the phrase is
    /// dictated as ordinary text, which is what someone who never uses the
    /// command would expect of it.
    var scratchEnabled = true

    /// How the input meter is drawn, and — since only one style needs it —
    /// whether the frequency analysis runs at all.
    var meterStyle: MeterStyle = .waveform {
        didSet {
            overlay.setMeterStyle(meterStyle)
            capture.analysesSpectrum = meterStyle.needsSpectrum
        }
    }
    private var overlayVisible = false
    private var overlayGateTask: Task<Void, Never>?

    /// The detector opens an utterance for any sound above its threshold — a
    /// door, a keyboard, someone two desks away. Flashing "Listening…" for
    /// those is a distraction in the corner of the screen, so the card waits
    /// until the input actually sounds like speech.
    ///
    /// This gates the **overlay only**. Audio is still captured, still fed to
    /// the recognizer, and still transcribed and inserted; nothing about
    /// detection changes.
    /// Roughly -33 dBFS on `AudioCapture`'s curve, which is quiet speech.
    /// Recalibrated with that curve rather than left alone: the same number
    /// means a different loudness every time the curve moves, and the failure
    /// it guards against — the card appearing for room noise — is silent.
    private static let overlaySpeechLevel: Float = 0.2
    private var lastSpeechAt = ContinuousClock.now
    private var idleTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    /// Ends the current utterance early. Installed only while hands-free runs,
    /// and swallows its key only while an utterance is actually open.
    private var finalizeKeyMonitor: FinalizeKeyMonitor?
    /// Switches hands-free off after this long without speech. Zero disables it.
    var handsFreeIdleTimeout: Duration = .seconds(1800)
    private var activeCorrectionModelID = ModelCatalog.appleCorrectionID

    init(
        engine: any SpeechRecognitionEngine = AppleSpeechEngine(),
        cleaner: any TranscriptCleaner = FoundationModelsCleaner(),
        inserter: any TextInserting = ClipboardPasteInserter()
    ) {
        self.engine = engine
        self.cleaner = cleaner
        self.inserter = inserter
        // macOS tears the audio graph down on a configuration change, and
        // `AudioCapture` rebuilds it; without this the only record of either
        // is the microphone behaving oddly some minutes later.
        capture.diagnosticLog = { message in
            Task { @MainActor in Log.write(message) }
        }
    }

    /// Loads models and pre-builds the audio graph so the first dictation is
    /// no slower than the rest.
    func warmUp() async {
        status = .preparing
        do {
            try await engine.prepare()
            let format = await engine.preferredInputFormat()
            capture.prearm(targetFormat: format)
            armMicrophone()
            // Warm the cleanup model too, but never let it block dictation.
            try? await cleaner.prepare()
            await refreshVocabulary()
            status = .idle
        } catch {
            status = .unavailable(error.localizedDescription)
        }
    }

    /// Switches the cleanup model, loading it if needed.
    func applyCorrectionModel(_ modelID: String) async {
        // Asked before anything is built. `applyPreferences` calls this on
        // every preference change, and `FoundationModelsCleaner.init`
        // constructs a `SystemLanguageModel` — so every unrelated toggle in
        // Settings used to build a cleaner and drop it on the next line.
        guard modelID != activeCorrectionModelID else { return }

        let desired: any TranscriptCleaner
        if let variant = MLXCleaner.Variant.from(modelID: modelID) {
            desired = MLXCleaner(variant: variant)
        } else {
            desired = FoundationModelsCleaner()
        }

        let switchStart = ContinuousClock.now
        await cleaner.releaseModels()
        cleaner = desired
        activeCorrectionModelID = modelID
        // Loading a downloaded model can take seconds, so never block dictation
        // on it; the first cleanup will finish the job if this has not.
        try? await cleaner.prepare()
        await refreshVocabulary()
        let elapsed = (ContinuousClock.now - switchStart) / .milliseconds(1)
        Log.write("cleanup model now \(modelID), loaded in \(Int(elapsed)) ms")
    }

    /// Switches the speech engine to the chosen model, loading it if needed.
    func applySpeechModel(_ modelID: String) async {
        let desired: any SpeechRecognitionEngine
        if let built = SpeechEngineFactory.engine(for: modelID) {
            desired = built
        } else {
            // A catalog entry with no engine would otherwise run Apple's
            // recognizer while reporting itself as the selected model.
            Log.write("no engine for speech model \(modelID), using Apple SpeechAnalyzer")
            desired = AppleSpeechEngine()
        }
        // Nothing to do if the active engine already matches.
        if type(of: desired) == type(of: engine), modelID == activeModelID { return }

        status = .preparing
        let switchStart = ContinuousClock.now
        await engine.releaseModels()
        engine = desired
        activeModelID = modelID
        engineStreamsLiveText = SpeechEngineFactory.streamsLiveText(for: modelID) ?? true
        await handsFree?.setEngine(desired)
        do {
            try await engine.prepare()
            let format = await engine.preferredInputFormat()
            capture.prearm(targetFormat: format)
            armMicrophone()
            await refreshVocabulary()
            // The elapsed time is logged because a switch that is suspiciously
            // fast is the symptom of the engine not really being swapped.
            let elapsed = (ContinuousClock.now - switchStart) / .milliseconds(1)
            Log.write(
                "speech model now \(modelID) via \(type(of: engine).engineName), "
                    + "loaded in \(Int(elapsed)) ms"
            )
            status = .idle
        } catch {
            status = .unavailable(error.localizedDescription)
        }
    }

    /// Pushes the current word list into both layers. Call after editing it.
    func refreshVocabulary() async {
        let terms = vocabulary.allTerms
        // Bias recognition toward the canonical spellings only: biasing toward
        // "cloud" would defeat the point.
        await engine.setContextualPhrases(terms.map(\.text))
        if let foundation = cleaner as? FoundationModelsCleaner {
            await foundation.setProtectedVocabulary(terms)
        } else if let mlx = cleaner as? MLXCleaner {
            await mlx.setProtectedVocabulary(terms)
        } else {
            await cleaner.setProtectedTerms(terms.map(\.text))
        }
        // A word list that biases nothing is worth saying out loud: on an
        // engine without contextual support the terms only ever get repaired
        // afterwards by the cleanup model, so with cleanup off they do nothing
        // at all and the setting looks broken.
        if !terms.isEmpty, !engine.biasesTowardPhrases {
            Log.write(
                "\(type(of: engine).engineName) ignores contextual phrases; "
                    + "\(terms.count) vocabulary term(s) rely on cleanup to be corrected")
        }
        // The word list is part of the cleaner's instructions, so editing it
        // invalidates any session prepared against the old one.
        prepareCleanupLevel()
    }

    /// Has the cleaner build and prewarm a session for the current level.
    ///
    /// Only Apple's cleaner can do this — an MLX one holds a single resident
    /// model with no per-request setup to hoist — so the others simply ignore
    /// it, the same way `refreshVocabulary` already branches on the cleaner.
    private func prepareCleanupLevel() {
        guard cleanupLevel != .off, let foundation = cleaner as? FoundationModelsCleaner
        else { return }
        let level = cleanupLevel
        Task { await foundation.prepareLevel(level) }
    }

    func releaseModels() async {
        await engine.releaseModels()
        await cleaner.releaseModels()
        status = .idle
    }

    // MARK: - Hotkey handling

    func begin() {
        guard !isActive, !isHandsFree else { return }
        if case .unavailable = status { return }
        // Opening a Bluetooth input forces the whole link into a low-quality
        // voice profile — audible on anything else playing through it — and
        // that renegotiation is also where a wedged headset has hung this
        // app outright. Refusing to touch it here means neither can happen;
        // dictation stays unavailable until the input switches back.
        guard !AudioCapture.defaultInputIsBluetooth else {
            Log.write("dictation press ignored: default input is Bluetooth")
            announce(.error("Bluetooth microphone not supported — switch input to dictate"))
            return
        }
        isActive = true
        sessionToken &+= 1

        latency.begin()
        latency.mark(.hotkeyDown)
        pressedAt = ContinuousClock.now

        // The microphone opens *before* anything else in this function, and
        // synchronously rather than inside the pipeline task.
        //
        // Nothing buffers the window before the input device is running: that
        // audio is not late, it does not exist. Measured with `--testmic`,
        // `AVAudioEngine.start()` costs 15-360 ms on this machine, and every
        // millisecond of it used to sit behind the overlay, the status change,
        // the Escape monitor and a hop onto the next main-actor turn — real
        // sessions logged 155-466 ms from the key to the first sample. Opening
        // first leaves only the device's own cost, and the rest of the setup
        // now happens while audio is already being recorded.
        let startup = StartupAudioBuffer()
        do {
            try capture.start { buffer in
                startup.append(buffer)
            }
        } catch {
            // The overlay has not been shown yet at this point, and `fail`
            // only sets its state — without this the microphone failing is
            // completely silent.
            overlay.show(showsMeter: false)
            Task { await fail(with: error) }
            return
        }
        latency.mark(.microphoneRunning)
        noteMicrophoneUse()

        buffer.reset()
        focusTarget = FocusTracker.capture()
        overlay.show(showsMeter: !engineStreamsLiveText)
        startMeter()
        status = .listening

        // Escape aborts without inserting. Holding a key is its own reminder
        // that dictation is running; a latch is not, so there has to be a way
        // out that is not "finish and paste whatever you captured".
        installEscapeMonitor()
        // Return finishes a latch from the keyboard, which is the same gesture
        // hands-free already uses. A hold has the key itself and needs none.
        if isLatched { installFinalizeKeyMonitor() }
        startLatchWatch()

        Task { await startPipeline(startup: startup) }
    }

    /// Whether the input device is held open between dictations.
    ///
    /// Opening it is what used to cost 15-360 ms of the front of every
    /// utterance — measured, `--testmic` — and none of that audio was late,
    /// it never existed. Held open, a press only swaps where the buffers go.
    /// The trade is the orange microphone indicator staying lit, so this is a
    /// preference rather than a decision made here.
    var keepMicrophoneArmed = true {
        didSet {
            guard keepMicrophoneArmed != oldValue else { return }
            if keepMicrophoneArmed {
                armMicrophone()
            } else if !isActive, !isHandsFree {
                microphoneIdleTask?.cancel()
                microphoneIdleTask = nil
                capture.stop()
                logMicrophoneState("keep-open switched off, microphone closed")
            }
        }
    }

    /// How long the armed microphone may sit unused before it is closed
    /// anyway. Zero holds it open indefinitely, which is what this used to do.
    ///
    /// Holding the device open costs the front of no utterance and buys a
    /// press that measures 0.0-0.1 ms, so the only reason to give it up is the
    /// orange indicator: a microphone lit all evening for a dictation nobody
    /// is going to make is a claim on the user's attention this app has not
    /// earned. The next press reopens it and pays the device cost once.
    var microphoneIdleTimeout: Duration = .seconds(900) {
        didSet {
            guard microphoneIdleTimeout != oldValue else { return }
            startMicrophoneIdleWatch()
        }
    }

    /// Whether the microphone is shut because it was idle, rather than because
    /// something went wrong.
    ///
    /// The two look identical from outside — preference on, device closed —
    /// and anything that heals the second must not undo the first, or the
    /// timeout closes the device and the next menu open reopens it.
    private(set) var microphoneClosedWhileIdle = false
    private var lastMicrophoneUseAt = ContinuousClock.now
    private var microphoneIdleTask: Task<Void, Never>?

    /// Opens the input device ahead of any key, if that is what the user asked
    /// for. Failing is not fatal: a dictation opens it itself, slowly.
    ///
    /// Refuses on a Bluetooth input: holding it open would force the whole
    /// link into a low-quality voice profile for as long as it stays armed,
    /// audibly degrading anything else playing through it — the wrong trade
    /// for something meant to sit open indefinitely between dictations.
    func armMicrophone() {
        guard keepMicrophoneArmed, !isHandsFree, !AudioCapture.defaultInputIsBluetooth else {
            return
        }
        guard !capture.isArmed else {
            // Already open. The countdown must be running, but it must not be
            // pushed back: this is also reached by a model swap, and swapping
            // a model is not the microphone being used.
            startMicrophoneIdleWatch()
            return
        }
        do {
            try capture.arm()
            noteMicrophoneUse()
            logMicrophoneState("microphone armed; a press now costs a sink swap")
        } catch {
            Log.write("microphone could not be armed: \(error.localizedDescription)")
        }
    }

    /// Reopens a microphone that was closed by something other than the idle
    /// timeout — a configuration change, or a session that failed.
    ///
    /// Idempotent, and deliberately refuses to fight the timeout: a device the
    /// timeout closed stays closed until the user presses the key.
    func rearmMicrophoneIfNeeded() {
        guard keepMicrophoneArmed, !isHandsFree, !isActive else { return }
        guard !microphoneClosedWhileIdle, !capture.isArmed else { return }
        Log.write("microphone was closed with keep-open on; reopening")
        armMicrophone()
    }

    /// Restarts the idle countdown. Called wherever the microphone is used, so
    /// "idle" means what the user would mean by it.
    private func noteMicrophoneUse() {
        lastMicrophoneUseAt = ContinuousClock.now
        microphoneClosedWhileIdle = false
        startMicrophoneIdleWatch()
    }

    /// Closes the armed microphone once it has gone unused for long enough.
    ///
    /// Sleeps the remaining time rather than polling, and re-checks on waking
    /// because a dictation during the sleep moves the deadline instead of
    /// cancelling the task.
    private func startMicrophoneIdleWatch() {
        microphoneIdleTask?.cancel()
        microphoneIdleTask = nil
        guard keepMicrophoneArmed, microphoneIdleTimeout > .zero else { return }
        microphoneIdleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining =
                    self.microphoneIdleTimeout - (ContinuousClock.now - self.lastMicrophoneUseAt)
                if remaining > .zero {
                    try? await Task.sleep(for: remaining)
                    continue
                }
                guard !Task.isCancelled, self.keepMicrophoneArmed else { return }
                // A dictation running now is exactly the opposite of idle, and
                // hands-free owns the device on its own terms.
                guard !self.isActive, !self.isHandsFree, self.capture.isArmed else { return }
                self.microphoneClosedWhileIdle = true
                self.capture.stop()
                self.logMicrophoneState(
                    "microphone idle for \(self.microphoneIdleTimeout), closed")
                return
            }
        }
    }

    /// Logs what CoreAudio says, not what this object believes.
    ///
    /// The orange indicator is driven by
    /// `kAudioProcessPropertyIsRunningInput`, and macOS keeps it lit for
    /// several seconds after a process releases the device — so switching the
    /// preference off and watching the menu bar looks exactly like nothing
    /// having happened. This is the only record that settles it. Delayed,
    /// because the property does not update synchronously with the stop.
    private func logMicrophoneState(_ note: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            let state = AudioCapture.systemReportsInputRunning
                .map { $0 ? "open" : "closed" } ?? "unknown"
            Log.write("\(note); system reports microphone \(state)")
        }
    }

    /// Ends a session's claim on the microphone. Whether the device closes is
    /// the whole difference between the next press costing 0.7 ms and 360 ms.
    private func releaseMicrophone() {
        if keepMicrophoneArmed {
            capture.idle()
            // The countdown to closing an unused device starts here, at the
            // end of a dictation, not when it was opened.
            noteMicrophoneUse()
        } else {
            capture.stop()
        }
    }

    /// Identifies the current session, so work scheduled by the previous one
    /// cannot act on this one.
    ///
    /// The microphone outlives the key by `trailingCaptureDuration`, and
    /// `isActive` is already false through that window — so a second tap
    /// arriving inside it starts a session whose device the *previous*
    /// session's pending `stop()` then closes. In a latch that is one tap, and
    /// the whole utterance after it is silent.
    private var sessionToken: UInt64 = 0

    /// Longest a latched session may run with nothing stopping it. A held key
    /// cannot be forgotten; a latch can, and an open microphone that never
    /// finalizes is the same class of failure as an unbounded cleanup pass.
    var maximumLatchDuration: Duration = .seconds(120)
    private var latchWatch: Task<Void, Never>?

    /// Finalizes rather than discards at the cap: if the speaker really did
    /// talk that long the words are theirs, and throwing them away is the one
    /// outcome that cannot be undone.
    private func startLatchWatch() {
        latchWatch?.cancel()
        guard isLatched, maximumLatchDuration > .zero else { return }
        latchWatch = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.maximumLatchDuration)
            guard !Task.isCancelled, self.isActive else { return }
            Log.write("latch reached \(self.maximumLatchDuration), finalizing")
            self.end()
        }
    }

    /// Set by the caller so the controller knows a session was latched rather
    /// than held.
    var isLatched = false

    /// Discards a push-to-talk session without inserting anything.
    func cancelActiveSession() {
        guard isActive else { return }
        isActive = false
        latchWatch?.cancel()
        latchWatch = nil
        removeEscapeMonitor()
        removeFinalizeKeyMonitor()
        stopMeter()
        releaseMicrophone()
        status = .idle
        overlay.hide()
        Task { await engine.cancelSession() }
        updatesTask?.cancel()
        updatesTask = nil
        Log.write("dictation cancelled, nothing inserted")
    }

    func end() {
        guard isActive else { return }
        isActive = false
        latchWatch?.cancel()
        latchWatch = nil
        removeEscapeMonitor()
        removeFinalizeKeyMonitor()
        latency.mark(.hotkeyUp)
        stopMeter()

        // Discard an incidental tap without inserting anything.
        let held = pressedAt.map { ContinuousClock.now - $0 } ?? .zero
        if held < minimumHoldDuration {
            releaseMicrophone()
            status = .idle
            overlay.hide()
            Task { await engine.cancelSession() }
            updatesTask?.cancel()
            updatesTask = nil
            return
        }

        status = .finishing
        overlay.setState(.transcribing)
        let token = sessionToken
        // Read on this side of the hop, so it is the instant the key said stop
        // rather than whenever the task below happens to be scheduled.
        let spokenThrough = mach_absolute_time()
        Task { [capture] in
            // The tap delivers in buffers, so at the moment the key is struck
            // the last fraction of a second is still in flight. Stopping the
            // microphone right here drops it, which is heard as the final word
            // being clipped — the same defect as a streaming decoder finalizing
            // without trailing audio, at the other end of the utterance.
            //
            // Waited for by asking the buffers rather than by sleeping long
            // enough to be safe. The two are not the same length: a release
            // lands uniformly inside a 100 ms buffer, so the sleep that always
            // covers it is roughly twice the wait that is usually needed, and
            // every millisecond of the difference is dead time between the
            // last word and the text appearing. `trailingCaptureWait` stays as
            // the ceiling — it is now how long to keep believing a buffer is
            // coming, rather than how long to wait regardless.
            await capture.waitForAudio(
                recordedThrough: spokenThrough, timeout: self.trailingCaptureWait)
            // Only if no new session has claimed the microphone in the
            // meantime. `isActive` went false the moment the key said stop, so
            // a second tap inside this window opens a session that this line
            // would otherwise close underneath it.
            if self.sessionToken == token { self.releaseMicrophone() }
            await self.finishPipeline()
        }
    }

    /// Floor for how long the microphone may keep running after the key says
    /// stop.
    ///
    /// The real ceiling is `trailingCaptureWait`, which also honours what the
    /// tap is measured to be doing.
    var trailingCaptureDuration: Duration = .milliseconds(120)

    /// Extra margin on top of one tap buffer. Covers the delivery itself and
    /// the hop back onto this actor, neither of which is instant.
    private static let trailingCaptureMargin = Duration.milliseconds(60)

    /// Longest the microphone keeps running after the key says stop, waiting
    /// for audio the tap has recorded but not yet handed over.
    ///
    /// This is a **ceiling, not a duration**: `end()` waits for the buffer
    /// that covers the release and stops as soon as it arrives, so the wait
    /// actually paid is whatever was left of that buffer — measured, 0-100 ms
    /// against this 160 ms. Sleeping the whole of it, which is what this used
    /// to do, spent the average utterance ~110 ms of silence for nothing.
    ///
    /// It must still exceed **one whole tap buffer**, because that is the
    /// longest a covering buffer can honestly take to arrive: the buffer
    /// holding the moment the key was struck is not handed over until it has
    /// filled. `installTap` is asked for 1024 frames and ignored — measured
    /// with `--testmic`, the tap delivers 4800 frames at 48 kHz, so the fixed
    /// 120 ms this used to be left 20 ms of margin over a 100 ms buffer and
    /// nothing at all on a device that buffers more. Sized from what the tap
    /// actually did rather than from what it was asked for.
    var trailingCaptureWait: Duration {
        let observed = capture.observedBufferSeconds
        guard observed > 0 else { return trailingCaptureDuration }
        let needed = Duration.milliseconds(Int((observed * 1000).rounded(.up)))
            + Self.trailingCaptureMargin
        return max(trailingCaptureDuration, needed)
    }

    // MARK: - Hands-free dictation

    /// Applies the detector's tuning. Takes effect on the next utterance.
    func setHandsFreeSilence(milliseconds: Int) async {
        handsFreeSilence = Double(milliseconds) / 1000
        await handsFree?.setTuning(
            VoiceActivityDetector.Tuning(silenceDuration: handsFreeSilence))
    }

    private var handsFreeSilence: TimeInterval = 0.5

    /// Whether a pause is judged by a model rather than by a stopwatch.
    var handsFreeUsesTurnDetector = true

    /// The silence used when the turn detector is doing the judging, in place
    /// of `handsFreeSilence`. Silero rounds up to whole 256 ms chunks, so one
    /// chunk is the shortest gap it can report at all.
    var turnDetectorSilence: TimeInterval = 0.25

    /// How sure the turn model must be before an utterance is committed.
    var turnDetectorThreshold: Float = 0.5

    /// Turns on continuous dictation: the microphone stays open and the
    /// detector decides where each utterance begins and ends.
    func startHandsFree() async {
        guard !isHandsFree, !isActive else { return }
        if case .unavailable = status { return }
        // Hands-free holds the microphone open continuously — the same
        // Bluetooth-profile and stuck-`engine.start()` exposure as keeping
        // push-to-talk armed, for the whole time it runs rather than briefly.
        // A plain early return rather than `.unavailable`: that status is a
        // hard gate `begin()` also checks, and nothing resets it once set, so
        // it would silently block ordinary dictation even after the
        // Bluetooth device disconnects.
        guard !AudioCapture.defaultInputIsBluetooth else {
            Log.write("hands-free not started: default input is Bluetooth")
            announce(.error("Bluetooth microphone not supported for hands-free"))
            return
        }

        status = .preparing
        let session = HandsFreeSession(
            engine: engine,
            tuning: VoiceActivityDetector.Tuning(silenceDuration: handsFreeSilence))
        await session.setPartialHandler { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                // Partials cross from the session actor to the main actor, so
                // one can arrive after the utterance already ended and the card
                // was hidden. Showing it again here leaves a card on screen
                // that nothing will ever hide.
                guard self.utteranceOpen else { return }
                // Recognized words settle the question of whether that was
                // speech, so the card appears even if the level never peaked.
                self.showOverlay()
                self.overlay.update(transcript: text)
            }
        }
        do {
            try await session.prepare()
        } catch {
            status = .unavailable("Voice detection unavailable: \(error.localizedDescription)")
            return
        }
        // The turn detector decides whether a pause is the end of a thought,
        // which is what lets the silence threshold drop rather than rise: the
        // wait no longer has to carry the decision on its own. If the model
        // cannot load — offline, first run — this falls back to endpointing on
        // silence alone at the configured threshold, which is what it always
        // did.
        if handsFreeUsesTurnDetector {
            let turnDetector = TurnDetector(threshold: turnDetectorThreshold)
            do {
                try await turnDetector.prepare()
                await session.setTurnDetector(turnDetector)
                await session.setTuning(
                    VoiceActivityDetector.Tuning(silenceDuration: turnDetectorSilence))
                Log.write("turn detector ready, silence threshold "
                    + "\(Int(turnDetectorSilence * 1000)) ms, "
                    + "threshold \(turnDetectorThreshold)")
            } catch {
                Log.write("turn detector unavailable, endpointing on silence: \(error)")
            }
        }

        handsFree = session

        // The detector needs 16 kHz mono whatever the engine wants. Every
        // engine either asks for that already or resamples internally.
        capture.prearm(targetFormat: session.inputFormat)

        let (audioStream, audioContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        handsFreePipe.attach(audioContinuation)
        handsFreeTask = Task { [weak self] in
            for await buffer in audioStream {
                await self?.consumeHandsFree(buffer)
            }
        }

        do {
            try capture.start { [weak self] buffer in
                self?.handsFreePipe.yield(buffer)
            }
        } catch {
            await stopHandsFree()
            status = .unavailable(error.localizedDescription)
            return
        }

        isHandsFree = true
        lastSpeechAt = ContinuousClock.now
        installEscapeMonitor()
        installFinalizeKeyMonitor()
        startIdleWatch()
        onHandsFreeChange?(true)
        status = .idle
        Log.write("hands-free on")
    }

    func stopHandsFree() async {
        guard isHandsFree || handsFreeTask != nil else { return }
        isHandsFree = false
        idleTask?.cancel()
        idleTask = nil
        removeEscapeMonitor()
        removeFinalizeKeyMonitor()
        // Closed rather than idled: hands-free captures at 16 kHz mono for the
        // detector, and the next push-to-talk session wants the speech
        // engine's own format. Re-prearmed and re-armed at the end of this
        // function, once that format is known.
        capture.stop()
        handsFreePipe.finish()
        handsFreeTask?.cancel()
        handsFreeTask = nil

        if let handsFree { await handsFree.releaseModels() }
        handsFree = nil
        utteranceOpen = false
        joiner.reset()
        hideOverlay()
        // Restore the format the engine actually prefers for push-to-talk, and
        // reopen the device ahead of the next key.
        let format = await engine.preferredInputFormat()
        capture.prearm(targetFormat: format)
        armMicrophone()
        onHandsFreeChange?(false)
        status = .idle
        Log.write("hands-free off")
    }

    /// Discards the utterance being spoken right now without stopping the
    /// mode. The only escape hatch once text inserts on its own.
    func cancelCurrentUtterance() async {
        guard utteranceOpen, let handsFree else { return }
        utteranceOpen = false
        await handsFree.cancelUtterance()
        hideOverlay()
        Log.write("hands-free utterance discarded")
    }

    /// Escape discards whatever is being spoken right now. With text landing
    /// on its own there is otherwise no way to stop a sentence mid-flight.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        // A global monitor observes without consuming, so Escape still reaches
        // whichever app is frontmost.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                guard let self else { return }
                // The same key, whichever mode is running: hands-free discards
                // the utterance in flight, push-to-talk abandons the session.
                if self.isActive {
                    self.cancelActiveSession()
                } else {
                    await self.cancelCurrentUtterance()
                }
            }
        }
    }

    /// Return finishes what is being spoken rather than waiting for the key or
    /// the detector. Unlike Escape this consumes the key, because Return
    /// submits in most applications and would fire before the transcript
    /// arrived, splitting one sentence across two messages.
    ///
    /// One monitor serves both modes. Hands-free finishes the open utterance
    /// and keeps listening; a latch is finished outright, which is exactly what
    /// tapping the latch key off does — the same gesture, from the keyboard.
    /// A hold needs none of this: the key is already in the speaker's hand.
    private func installFinalizeKeyMonitor() {
        guard finalizeKeyMonitor == nil else { return }
        let monitor = FinalizeKeyMonitor(
            shouldFinalize: { [weak self] in
                guard let self else { return false }
                return self.utteranceOpen || (self.isActive && self.isLatched)
            },
            onFinalize: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if self.isActive && self.isLatched {
                        // Identical to the second tap, down to the trailing
                        // capture, so the last word survives either way.
                        Log.write("latch finished by Return")
                        self.end()
                    } else {
                        await self.finalizeCurrentUtterance()
                    }
                }
            }
        )
        if monitor.start() {
            finalizeKeyMonitor = monitor
        } else {
            Log.write("finalize key unavailable; dictation still finishes on its own")
        }
    }

    /// Torn down only when neither mode still wants it. Hands-free installs it
    /// for the whole mode and a latch for one session; a latch ending inside
    /// hands-free must not take the mode's monitor with it.
    private func removeFinalizeKeyMonitor() {
        guard !isHandsFree else { return }
        finalizeKeyMonitor?.stop()
        finalizeKeyMonitor = nil
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// A microphone left open for hours is the failure this guards against.
    private func startIdleWatch() {
        idleTask?.cancel()
        guard handsFreeIdleTimeout > .zero else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, isHandsFree, !utteranceOpen else { continue }
                if ContinuousClock.now - lastSpeechAt > handsFreeIdleTimeout {
                    Log.write("hands-free idle timeout reached, switching off")
                    await stopHandsFree()
                    return
                }
            }
        }
    }


    private func consumeHandsFree(_ buffer: AVAudioPCMBuffer) async {
        guard let handsFree else { return }
        for event in await handsFree.ingest(buffer) {
            handle(event)
        }
    }

    /// Applies one session event. Shared so that an utterance finished by the
    /// detector and one finished by the key take exactly the same path — the
    /// last time two callers each handled engine events themselves they
    /// drifted, and only one of them was ever tested.
    private func handle(_ event: HandsFreeSession.Event) {
        switch event {
        case .utteranceBegan:
            utteranceOpen = true
            lastSpeechAt = ContinuousClock.now
            focusTarget = FocusTracker.capture()
            presentOverlayWhenAudible()

        case .utteranceDiscarded:
            utteranceOpen = false
            hideOverlay()

        case .turnHeld(let probability):
            // Speech stopped, but the turn detector judged the thought
            // unfinished, so the utterance is still open and nothing has
            // been inserted. The overlay stays up: from the speaker's side
            // this is the app waiting rather than cutting in.
            lastSpeechAt = ContinuousClock.now
            Log.write(String(format: "turn held, p(complete)=%.3f", probability))

        case .transcript(let text):
            utteranceOpen = false
            lastSpeechAt = ContinuousClock.now
            hideOverlay()
            // Queued behind any utterance still being cleaned or pasted, so
            // two transcripts can never reach the pasteboard at once.
            let previous = insertion
            let target = focusTarget
            let readyAt = ContinuousClock.now
            insertion = Task { [weak self] in
                _ = await previous.value
                await self?.deliver(text, to: target, readyAt: readyAt)
            }
        }
    }

    /// Ends the utterance being spoken right now and starts its post-processing
    /// immediately, instead of waiting for the detector to notice the silence.
    ///
    /// This is the fastest path there is to text on screen: it skips the VAD's
    /// silence wait and the turn detector entirely, both of which exist only to
    /// guess what pressing the key states outright.
    func finalizeCurrentUtterance() async {
        guard utteranceOpen, let handsFree else { return }
        // Cleared up front so a second press during finalize does nothing.
        utteranceOpen = false
        hideOverlay()
        guard let event = await handsFree.finalizeNow() else { return }
        handle(event)
        Log.write("utterance finished by key")
    }

    /// Cleans and inserts one finished utterance. Runs strictly one at a time.
    private func deliver(
        _ raw: String, to target: FocusTracker.Target?, readyAt: ContinuousClock.Instant
    ) async {
        // Hands-free had no timing at all: LatencyTracker is driven by the
        // hotkey, which this path never touches. Without these numbers a slow
        // cleanup model and a slow insertion look identical from outside.
        //
        // `readyAt` is when the transcript existed; `started` is when this
        // utterance reached the front of the queue. Timing from `started`
        // alone — which is what this did — makes the wait behind the previous
        // utterance structurally invisible, and that wait is the one thing
        // that would show cleanup falling behind continuous speech.
        let started = ContinuousClock.now
        let queuedMs = Int((started - readyAt) / .milliseconds(1))

        // Checked before formatting and before cleanup, on the recognizer's own
        // words. A cleanup model rewrites "scratch that" into a tidy sentence
        // and would hide the command completely, and there is no point paying
        // for a cleanup pass on something that will never be inserted.
        if scratchEnabled, VoiceCommand.parse(raw) == .scratchThat {
            await scratchLastInsertion(target: target)
            return
        }

        var cleanupMs = 0
        var transcript = SpokenFormatter.format(raw, options: formatting)
        if cleanupLevel != .off {
            let cleanupStart = ContinuousClock.now
            transcript = await cleanUp(transcript, level: cleanupLevel)
            cleanupMs = Int((ContinuousClock.now - cleanupStart) / .milliseconds(1))
        }
        transcript = VocabularyNormalizer.apply(vocabulary.allTerms, to: transcript)

        // Applied after every other stage, so nothing downstream can strip it.
        let separator = joiner.separator(before: transcript, target: target?.bundleIdentifier)

        if let target { await FocusTracker.restore(target) }
        do {
            let inserted = separator + transcript
            let outcome = try inserter.insert(
                inserted, into: target?.application?.processIdentifier)
            if outcome == .leftOnClipboard {
                // Nothing could take the text, so it is on the clipboard rather
                // than lost. Say so: silence here reads as the app having
                // failed, when in fact the words are one ⌘V away.
                joiner.reset()
                lastInsertion = nil
                announceClipboardFallback()
            } else if outcome == .pastedUnverified {
                // The paste almost certainly landed — it just could not be
                // confirmed, so nothing is claimed on the card. Scratch is
                // given up rather than risk deleting text this app did not
                // insert; the joiner carries on, since the words are there.
                lastInsertion = nil
                Log.write("focus unreadable; pasted anyway and kept a clipboard copy")
            } else {
                lastInsertion = LastInsertion(
                    text: inserted, bundleIdentifier: target?.bundleIdentifier,
                    at: ContinuousClock.now)
            }
            HistoryStore.shared.record(transcript)
        } catch {
            Log.write("hands-free insertion failed: \(error.localizedDescription)")
        }
        logUtterance(readyAt: readyAt, queuedMs: queuedMs, cleanupMs: cleanupMs)
    }

    /// Cleans `text`, or returns it untouched if cleanup fails or overruns.
    ///
    /// Cleanup is a convenience: on failure the raw transcript is still
    /// inserted rather than losing what was dictated.
    private func cleanUp(_ text: String, level: CleanupLevel) async -> String {
        let cleaner = self.cleaner
        let cleaned = await withDeadline(cleanupDeadline) { () -> String? in
            do {
                return try await cleaner.clean(text, level: level)
            } catch {
                Log.write("cleanup failed, inserting raw transcript: \(error)")
                return nil
            }
        }
        guard let cleaned else {
            // Two different nils: the model gave up, which is already logged,
            // or it is still running and nobody is waiting for it any more.
            Log.write("cleanup exceeded \(cleanupDeadline), inserting raw transcript")
            return text
        }
        return cleaned ?? text
    }

    /// One line per utterance, measured from the moment its transcript existed.
    ///
    /// Deliberately not called "from end of speech": the detector's endpoint
    /// and the engine's finalize both happen before this point, so the true
    /// wait is longer than any number here. Claiming otherwise is what made
    /// the old line read as though the app were three times faster than it is.
    /// Takes back the last insertion, if it is still safe to do so.
    ///
    /// "Safe" is the whole difficulty. Deleting is destructive and there is no
    /// way to be certain the cursor still sits where the text was left, so the
    /// guards are deliberately strict: same application, inside the window, and
    /// only ever the exact number of characters that were inserted. Anything
    /// unexpected declines and says so rather than guessing — a refusal costs a
    /// manual undo, a wrong guess eats whatever was typed since.
    private func scratchLastInsertion(target: FocusTracker.Target?) async {
        guard let last = lastInsertion else {
            announce(.nothingToScratch)
            return
        }
        guard last.bundleIdentifier == target?.bundleIdentifier else {
            Log.write("scratch declined: focus moved to a different application")
            announce(.nothingToScratch)
            return
        }
        guard ContinuousClock.now - last.at < scratchWindow else {
            Log.write("scratch declined: last insertion is older than \(scratchWindow)")
            announce(.nothingToScratch)
            return
        }

        if let target { await FocusTracker.restore(target) }
        do {
            try inserter.deleteBackward(count: last.text.count)
            Log.write("scratched \(last.text.count) characters")
            announce(.scratched)
        } catch {
            Log.write("scratch failed: \(error.localizedDescription)")
        }
        // Cleared either way: a second "scratch that" must never delete a
        // further utterance's worth of text that nobody asked it to.
        lastInsertion = nil
        // The text it was spacing against is gone, so the next utterance starts
        // fresh rather than being pushed away from a word that no longer exists.
        joiner.reset()
    }

    /// Briefly shows a message on the card, then hides it.
    private func announce(_ state: OverlayModel.State) {
        overlayVisible = true
        overlay.show()
        overlay.setState(state)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            self?.hideOverlay()
        }
    }

    /// Tells the speaker their words are on the clipboard.
    ///
    /// The card is shown even in hands-free, where it is normally gated on
    /// input level: this is the one message that must not be missed, because
    /// nothing appeared in the target application and the only other evidence
    /// is a log file.
    private func announceClipboardFallback() {
        Log.write("no editable field focused; transcript left on the clipboard")
        overlayVisible = true
        overlay.show()
        overlay.setState(.copiedToClipboard)
        // Long enough to read, short enough not to sit in the corner.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.hideOverlay()
        }
    }

    private func logUtterance(readyAt: ContinuousClock.Instant, queuedMs: Int, cleanupMs: Int) {
        let total = Int((ContinuousClock.now - readyAt) / .milliseconds(1))
        Log.write(
            "utterance delivered: queued \(queuedMs) ms, cleanup \(cleanupMs) ms, "
                + "total \(total) ms from transcript ready")
    }

    /// Waits for the input to sound like speech before showing the card.
    private func presentOverlayWhenAudible() {
        overlayGateTask?.cancel()
        overlayGateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, utteranceOpen else { return }
                if capture.currentLevel >= Self.overlaySpeechLevel {
                    showOverlay()
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    /// Shows the card immediately. Also called when the recognizer produces
    /// text, since words are proof enough that someone spoke.
    private func showOverlay() {
        guard !overlayVisible else { return }
        overlayVisible = true
        overlay.show(showsMeter: !engineStreamsLiveText)
        startMeter()
    }

    private func hideOverlay() {
        overlayGateTask?.cancel()
        overlayGateTask = nil
        stopMeter()
        guard overlayVisible else { return }
        overlayVisible = false
        overlay.hide()
    }

    /// Feeds the overlay's meter from real microphone levels while listening.
    /// Only runs for engines that show no text, since it exists to prove the
    /// microphone is live when nothing else would.
    private func startMeter() {
        guard !engineStreamsLiveText else { return }
        meterTask?.cancel()
        // The tap hands over one buffer per 100 ms holding four 25 ms slices,
        // so draining it and drawing whatever came back moves the meter four
        // bars at a time, ten times a second — which is not a fast meter, it is
        // a stuttering one. The slices are queued and released one per tick
        // instead, so the bars scroll at 40 a second the way they were
        // measured. The queue costs up to a tick of delay and never more,
        // because it is drained faster than it fills whenever it runs behind.
        meterTask = Task { [weak self] in
            var pending: [LevelSample] = []
            while !Task.isCancelled {
                guard let self else { return }
                pending.append(contentsOf: capture.drainLevelSamples())

                // A backlog is time, not just bars: 12 slices is 300 ms of
                // meter that would arrive late. Drop the oldest rather than
                // show speech that has already finished.
                if pending.count > 12 { pending.removeFirst(pending.count - 12) }

                if !pending.isEmpty {
                    // Two at a time while catching up, one when level. Any
                    // faster and the catch-up is itself a visible jump.
                    let release = pending.count > 5 ? 2 : 1
                    overlay.push(Array(pending.prefix(release)))
                    pending.removeFirst(min(release, pending.count))
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
    }

    // MARK: - Pipeline

    /// Loads the recognizer while `startup` is already recording.
    ///
    /// The microphone is opened by `begin()`, not here: the tap is the only
    /// owner of `startup` once this returns — both rationales are on the type —
    /// and `capture.stop()` removes the tap, releasing it with the session.
    private func startPipeline(startup: StartupAudioBuffer) async {
        do {
            let updates = try await engine.beginSession()
            latency.mark(.recognizerReady)

            updatesTask = Task { [weak self] in
                for await update in updates {
                    self?.consume(update)
                }
            }

            // Replays what was captured while the recognizer was loading, in
            // order, then hands the tap straight through.
            startup.attach(engine)
        } catch {
            await fail(with: error)
        }
    }

    private func consume(_ update: TranscriptUpdate) {
        latency.mark(.firstPartial)
        buffer.apply(text: update.text, isFinal: update.isFinal)
        overlay.update(transcript: buffer.liveText)
    }

    private func finishPipeline() async {
        defer {
            updatesTask = nil
            status = .idle
        }

        var transcript: String
        do {
            transcript = try await engine.finishSession()
        } catch {
            await fail(with: error)
            return
        }
        updatesTask?.cancel()
        latency.mark(.finalTranscript)

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            overlay.hide()
            latency.report()
            return
        }

        transcript = SpokenFormatter.format(transcript, options: formatting)

        if cleanupLevel != .off {
            overlay.setState(.cleaning)
            overlay.update(transcript: transcript)
            transcript = await cleanUp(transcript, level: cleanupLevel)
        }
        latency.mark(.cleanupComplete)

        // Enforce the user's own spelling last, so neither the recognizer nor
        // the cleanup model can undo it.
        transcript = VocabularyNormalizer.apply(vocabulary.allTerms, to: transcript)

        // Dismiss before pasting so the overlay is never captured mid-insert.
        overlay.hide()

        if let focusTarget { await FocusTracker.restore(focusTarget) }
        do {
            let outcome = try inserter.insert(
                transcript, into: focusTarget?.application?.processIdentifier)
            if outcome == .leftOnClipboard { announceClipboardFallback() }
            if outcome == .pastedUnverified {
                Log.write("focus unreadable; pasted anyway and kept a clipboard copy")
            }
            HistoryStore.shared.record(transcript)
        } catch {
            NSLog("[murmur] insertion failed: \(error.localizedDescription)")
        }
        latency.mark(.inserted)
        latency.report()
    }

    private func fail(with error: Error) async {
        isActive = false
        stopMeter()
        // A consuming event tap left installed by a failed session goes on
        // swallowing Return for as long as the app runs.
        removeEscapeMonitor()
        removeFinalizeKeyMonitor()
        // Closed, not idled: the microphone itself may be what failed, and a
        // clean reopen is the only thing that can recover from that.
        capture.stop()
        await engine.cancelSession()
        updatesTask?.cancel()
        updatesTask = nil
        overlay.setState(.error(error.localizedDescription))
        NSLog("[murmur] dictation failed: \(error.localizedDescription)")
        try? await Task.sleep(for: .milliseconds(1200))
        overlay.hide()
        status = .idle
        // The device was closed to recover, so with keep-open on it has to be
        // reopened — otherwise a single failed session silently costs every
        // later press the reopen this preference exists to avoid.
        rearmMicrophoneIfNeeded()
    }
}
