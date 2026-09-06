import AVFoundation
import Accelerate
import Foundation

/// Microphone capture for dictation.
///
/// The input device is opened once and held open; starting a dictation only
/// swaps where its buffers go. That is not a micro-optimization. Nothing
/// buffers the window before the device is running — that audio is not late,
/// it does not exist — and opening it costs 15-360 ms, measured with
/// `--testmic` on this machine. Every one of those milliseconds used to come
/// off the front of an utterance, which is what "it cut off my first word"
/// was.
///
/// While no dictation is running the buffers go into a short pre-roll and are
/// otherwise discarded, so the audio spoken in the moment before the key
/// registers is still there to be replayed. This is the same trick hands-free
/// already uses for the detector's confirmation lag, at the other trigger.
///
/// The cost is honest and visible: macOS shows the orange microphone indicator
/// for as long as the device runs. `arm()` and `idle()` are what hold it open;
/// `stop()` closes it and puts the indicator out.
public final class AudioCapture: @unchecked Sendable {

    public enum CaptureError: LocalizedError {
        case microphoneDenied
        case converterUnavailable
        case deviceBusy

        public var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access was denied."
            case .converterUnavailable: "Could not convert microphone audio to the engine's format."
            case .deviceBusy: "The audio device is still switching — try again in a moment."
            }
        }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isRunning = false
    private var tapInstalled = false
    private let lock = NSLock()

    /// Guards the sink and the pre-roll, which the audio thread touches for
    /// every buffer. Separate from `lock` so that opening or closing the device
    /// never blocks the audio thread, and held across the whole hand-off so a
    /// replayed pre-roll cannot interleave with live buffers — the ordering
    /// requirement `StreamPipe` and `StartupAudioBuffer` exist for.
    private let sinkLock = NSLock()
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var idleRoll = PreRollBuffer(capacityFrames: 0)

    /// How much audio to keep while idle, for replay when a dictation starts.
    ///
    /// Covers the speaker beginning a word fractionally before the key
    /// registers, which is the remaining way to clip a first syllable now that
    /// the device is already open. Kept short: it is also however much of the
    /// room immediately before the press gets prepended to the transcript.
    public var preRollSeconds: Double = 0.3

    private let levelLock = NSLock()
    private var level: Float = 0
    /// Audio in this session loud enough to have been somebody speaking.
    ///
    /// Measured here rather than derived from the meter, because the meter is
    /// not always running — `startMeter` returns early for an engine that
    /// streams live text — and it drops its backlog on purpose. This counts
    /// every slice `updateLevel` measures anyway, so it costs a comparison.
    private var speechSecondsMeasured: Double = 0
    /// Whether a dictation owns the microphone. Idle audio goes into the
    /// pre-roll and is thrown away, and must not be counted as anybody
    /// speaking.
    private var capturing = false
    private let spectrum = SpectrumAnalyser()

    /// Recent input loudness, 0...1, for the overlay's meter.
    ///
    /// Read by polling rather than pushed per buffer: it exists only to drive
    /// an animation, so dropping updates is harmless, and hopping to the main
    /// actor for every buffer is not.
    public var currentLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return level
    }

    /// Every level measured since the last call, oldest first.
    ///
    /// The meter used to poll `currentLevel` every 50 ms, which cannot show
    /// more than the tap delivers: buffers arrive every 100 ms, so half the
    /// bars were duplicates of the one before and the whole meter moved at
    /// 10 frames a second no matter how it was drawn. One buffer is measured in
    /// `levelSliceCount` pieces instead, so a syllable inside it is a shape
    /// rather than a single value.
    ///
    /// Drained rather than read, because a bar that is never collected is a
    /// moment of speech the meter skipped.
    public func drainLevelSamples() -> [LevelSample] {
        levelLock.lock()
        defer { levelLock.unlock() }
        let samples = levelSamples
        levelSamples.removeAll(keepingCapacity: true)
        return samples
    }

    /// Whether each slice is also broken into frequency bands.
    ///
    /// Off by default and switched on only by a meter that draws them: the
    /// analysis is cheap but it is not free, and nothing else in the app has
    /// any use for it.
    public var analysesSpectrum: Bool {
        get {
            levelLock.lock()
            defer { levelLock.unlock() }
            return spectrumWanted
        }
        set {
            levelLock.lock()
            spectrumWanted = newValue
            levelLock.unlock()
        }
    }
    private var spectrumWanted = false
    private var levelSamples: [LevelSample] = []

    /// Pieces each buffer is measured in. Four gives ~25 ms per bar on the
    /// 100 ms buffers this hardware delivers — fine enough to separate
    /// syllables, coarse enough that the work stays trivial on the audio
    /// thread.
    private static let levelSliceCount = 4

    /// Anything quieter than this is silence, anything louder is full scale.
    ///
    /// Set from the two ends that matter, both of them wrong once already. The
    /// original window ran -50 dB to 0 dB — full scale, which dictation never
    /// reaches, so an ordinary voice at ~-30 dBFS sat in the middle of the
    /// meter and looked no different from an empty room. Opening the floor to
    /// -55 to fix that overshot in the other direction: a quiet room is around
    /// -50 dBFS, so the room itself started moving the bars and the meter
    /// twitched at nothing. -42 is below speech and above a room.
    private static let quietDecibels: Float = -42
    private static let loudDecibels: Float = -12

    /// Longest buffer the tap has actually handed over, in seconds.
    ///
    /// `installTap` is asked for 1024 frames and ignored: measured with
    /// `--testmic`, the tap delivers 4800 frames at 48 kHz — 100 ms — and that
    /// is the number that decides the end of an utterance. The buffer holding
    /// the moment the key was struck is not handed over until it has filled, so
    /// anything that stops listening sooner than this throws that fraction of a
    /// second away. Observed rather than assumed, because it is a property of
    /// the device, not of the request.
    public var observedBufferSeconds: Double {
        levelLock.lock()
        defer { levelLock.unlock() }
        return bufferSeconds
    }
    private var bufferSeconds: Double = 0

    /// Whether the input device is open right now.
    ///
    /// Asks the engine as well as this object's own flag. macOS stops the
    /// engine out from under us on a configuration change — a device
    /// appearing, a sample rate changing, waking from sleep — and the flag
    /// alone would go on reporting a microphone that is shut. Everything that
    /// decides whether to reopen reads this, so a lie here is a dictation that
    /// records silence.
    public var isArmed: Bool {
        // Read from the menu on the main thread, so it is bounded like every
        // other main-thread caller. A device mid-change reports itself closed,
        // which is the honest answer while the graph is being rebuilt.
        guard acquireLockOrSkip(for: "reading whether the microphone is open") else { return false }
        defer { lock.unlock() }
        return isRunning && engine.isRunning
    }

    /// Where to report something the app should know about but cannot see.
    /// `MurmurCore` has no logger of its own; the app supplies one.
    public var diagnosticLog: (@Sendable (String) -> Void)?

    private var configurationObserver: NSObjectProtocol?

    /// Where a configuration change is reacted to. Serial, so a burst of them —
    /// which is what changing audio device actually produces — rebuilds the
    /// graph once at a time rather than concurrently.
    private let configurationQueue = DispatchQueue(
        label: "com.sikaihuang.murmur.audio-configuration")

    public init() {
        // AVAudioEngine stops itself when the audio configuration changes and
        // does not start again. Unobserved, that is the microphone silently
        // closing while every switch in the app still says it is open.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // **Never react on this thread.** `queue: nil` delivers the
            // notification *synchronously on whatever thread posted it*, and
            // AVAudioEngine posts this one from its own internal audio thread
            // while it is part-way through reconfiguring itself. Calling
            // `engine.start()` or `installTap` from in here is a reentrant call
            // into an engine that is still holding its own state down, and it
            // blocks — with `lock` held, so the next press on the main thread
            // blocks behind it and the app stops answering entirely.
            //
            // Measured: unplugging Bluetooth and switching to the built-in
            // output produced a burst of these, `main thread stalled past 1.0 s`
            // in the log immediately after, and no recovery — the app had to be
            // force-quit. The reaction is the same work, done anywhere else.
            self?.configurationQueue.async { [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Rebuilds the graph after macOS tore it down, and reopens the device if
    /// it was open before.
    ///
    /// The tap goes with the engine, and the input format may be different on
    /// the other side of this — so the converter is rebuilt rather than
    /// reused, and whatever the pre-roll is holding was recorded in the old
    /// format and is dropped for the same reason `prearm` drops it.
    private func handleConfigurationChange() {
        sinkLock.lock()
        idleRoll.reset()
        sinkLock.unlock()

        lock.lock()
        let wasOpen = isRunning
        isRunning = false
        tapInstalled = false
        converter = nil
        var failure: String?
        // A device switching to Bluetooth mid-session — someone's headset
        // reconnecting — must not be silently followed: opening its mic
        // forces the whole link into a low-quality voice profile, degrading
        // whatever else is playing through it, for as long as it stays open.
        let declineBluetooth = wasOpen && Self.defaultInputIsBluetooth
        if wasOpen, !declineBluetooth {
            do {
                try startLocked()
            } catch {
                failure = error.localizedDescription
            }
        }
        lock.unlock()

        if let failure {
            diagnosticLog?("audio configuration changed; microphone could not reopen: \(failure)")
        } else if declineBluetooth {
            diagnosticLog?(
                "audio configuration changed; default input is now Bluetooth, staying closed")
        } else if wasOpen {
            diagnosticLog?("audio configuration changed; microphone reopened")
        } else {
            diagnosticLog?("audio configuration changed while the microphone was closed")
        }
    }

    /// Requests microphone permission, prompting on first call.
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Pre-builds the audio graph, and re-points it at a new engine's format.
    ///
    /// The tap converts as it delivers, so a changed target format invalidates
    /// the installed tap rather than only the converter — hands-free asks for
    /// 16 kHz mono where push-to-talk asks for whatever the engine wants, and a
    /// stale tap would go on delivering the previous format.
    public func prearm(targetFormat: AVAudioFormat?) {
        guard acquireLockOrSkip(for: "pre-arming") else { return }
        defer { lock.unlock() }
        guard targetFormat != self.targetFormat || !tapInstalled else { return }
        self.targetFormat = targetFormat
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        if let targetFormat, targetFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }
        // Whatever the pre-roll is holding was captured in the *previous*
        // format, and replaying it into a session that asked for this one
        // hands an engine audio it never agreed to take. Apple's
        // SpeechAnalyzer does not reject that, it traps inside the Speech
        // framework — so the roll is dropped rather than converted.
        sinkLock.lock()
        idleRoll.reset()
        sinkLock.unlock()

        if isRunning {
            // Already open: re-tap in place rather than closing the device,
            // which would cost the reopen this class exists to avoid.
            installTapLocked()
        } else {
            tapInstalled = false
            engine.prepare()
        }
    }

    /// Opens the microphone and holds it open, delivering nothing.
    ///
    /// Buffers go into the pre-roll and are discarded as it rolls over. The
    /// point is that the device is *already running* when a dictation starts.
    public func arm() throws {
        try acquireLock(for: "arming the microphone")
        defer { lock.unlock() }
        try startLocked()
    }

    /// Routes buffers to `onBuffer`, replaying the pre-roll first so a syllable
    /// spoken just before the key still reaches the recognizer.
    ///
    /// Safe to call while already delivering: the sink is swapped rather than
    /// the call being ignored. A second dictation starting before the previous
    /// one has finished its trailing capture would otherwise keep the old
    /// session's sink and deliver nothing to the new one.
    public func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        try acquireLock(for: "starting a dictation")
        defer { lock.unlock() }
        try startLocked()

        levelLock.lock()
        speechSecondsMeasured = 0
        capturing = true
        levelLock.unlock()

        sinkLock.lock()
        // Drained and installed under one lock, in order, for the same reason
        // `StartupAudioBuffer` does: a task per buffer is not FIFO.
        for buffer in idleRoll.drain() { onBuffer(buffer) }
        sink = onBuffer
        sinkLock.unlock()
    }

    /// How much of the session just captured sounded like speech.
    ///
    /// Survives the end of the session on purpose: it is read after the
    /// transcript comes back, which is the only moment it answers anything.
    /// The question it answers is the one a peak cannot — a peak is the
    /// loudest 25 ms, so one door closing in a silent room reads the same as
    /// somebody talking for six seconds.
    public var speechSeconds: Double {
        levelLock.lock()
        defer { levelLock.unlock() }
        return speechSecondsMeasured
    }

    /// Loudness at which audio is taken to be somebody speaking, on the curve
    /// `loudness(ofRMS:)` draws — roughly -33 dBFS, which is quiet speech.
    ///
    /// One number, in one place: the curve has moved twice already, and the
    /// same constant means a different loudness on each one.
    public static let speechLevel: Float = 0.2

    /// Stops delivering to the session's sink without closing the device.
    ///
    /// The pre-roll is cleared as well: what it holds at this moment is the end
    /// of the utterance that just finished, and replaying that into the next
    /// one would repeat the last word.
    public func idle() {
        sinkLock.lock()
        sink = nil
        idleRoll.reset()
        sinkLock.unlock()
        levelLock.lock()
        level = 0
        levelSamples.removeAll(keepingCapacity: true)
        // `speechSecondsMeasured` is deliberately kept: the session that just
        // ended is exactly what it describes, and it is read once the
        // transcript is back.
        capturing = false
        levelLock.unlock()
    }

    /// Closes the input device and puts the microphone indicator out.
    public func stop() {
        idle()
        // No further buffer is coming, so anyone waiting for one is waiting
        // for nothing. Released rather than left to time out: the device
        // closing is the answer to their question.
        releaseDeliveryWaiters()
        guard acquireLockOrSkip(for: "closing the microphone") else { return }
        defer { lock.unlock() }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        engine.stop()
        isRunning = false
        // Leave the graph prepared so the next start() stays as fast as it can.
        engine.prepare()
    }

    // MARK: - Device

    /// How long a caller will wait for the device lock before giving up.
    ///
    /// The lock is held across `engine.start()`, and a device that has just been
    /// pulled out from under CoreAudio can make that take seconds. Everything
    /// that takes this lock is on the main thread — a press, the menu opening, a
    /// preference changing — so waiting without a limit is not a slow
    /// microphone, it is an app that has stopped answering, and with the
    /// finalize tap installed it is a keyboard that has stopped working in every
    /// application. A refused press is recoverable by pressing again. A wedged
    /// main thread is recoverable only by force-quitting.
    private static let lockTimeout: TimeInterval = 0.5

    /// **Test-only.** Holds the device lock on another thread for `seconds`,
    /// which is exactly what a configuration change in progress looks like to a
    /// press arriving on the main thread.
    ///
    /// The condition this reproduces cannot be produced on demand any other way:
    /// it needs CoreAudio to be part-way through tearing a real device down, and
    /// the only recipe anyone has for that is to physically disconnect a
    /// Bluetooth headset. Same reasoning as `WhisperEngine.forcedSampleLength` —
    /// manufacture the state rather than wait for the hardware.
    public func holdDeviceLockForTesting(seconds: TimeInterval) {
        let thread = Thread { [lock] in
            lock.lock()
            Thread.sleep(forTimeInterval: seconds)
            lock.unlock()
        }
        thread.start()
        // The caller's next line is the thing under test, so the lock has to be
        // held by the time it runs.
        Thread.sleep(forTimeInterval: 0.05)
    }

    /// Takes `lock`, or gives up rather than blocking the caller forever.
    private func acquireLock(for what: String) throws {
        guard lock.lock(before: Date().addingTimeInterval(Self.lockTimeout)) else {
            diagnosticLog?(
                "audio device busy, \(what) refused: the device lock is still held, "
                    + "most likely by a configuration change in progress")
            throw CaptureError.deviceBusy
        }
    }

    /// `acquireLock` for the callers that have no way to report a failure.
    private func acquireLockOrSkip(for what: String) -> Bool {
        guard lock.lock(before: Date().addingTimeInterval(Self.lockTimeout)) else {
            diagnosticLog?("audio device busy, \(what) skipped: the device lock is still held")
            return false
        }
        return true
    }

    private func startLocked() throws {
        // The engine is the authority on whether it is running. It stops
        // itself on a configuration change, taking the tap with it, and a
        // press that trusted the flag instead would install nothing, start
        // nothing, and record nothing — while the overlay, the meter and
        // the menu all behaved normally.
        if !engine.isRunning, isRunning {
            isRunning = false
            tapInstalled = false
        }
        // Only when there is no tap. Re-installing one on every press would
        // discard whatever buffer the device was part-way through filling,
        // which is the clipped first syllable coming back by another route.
        if !tapInstalled { installTapLocked() }
        guard !isRunning else { return }
        // Timed because this is the call that hangs. Ordinary opens cost
        // 15-472 ms (`--testmic`); a device that CoreAudio is still tearing down
        // — a Bluetooth headset just disconnected — can make it take seconds,
        // and it is invisible from the outside because nothing else is logged
        // between the press and the audio. A slow open now names itself.
        let began = ContinuousClock.now
        try engine.start()
        let took = (ContinuousClock.now - began) / .milliseconds(1)
        if took >= 250 {
            diagnosticLog?(String(format: "opening the input device took %.0f ms", took))
        }
        isRunning = true
    }

    private func installTapLocked() {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        if let targetFormat, targetFormat != inputFormat, converter == nil {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        let converter = self.converter
        let targetFormat = self.targetFormat

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, when in
            self?.deliver(buffer, at: when, converter: converter, targetFormat: targetFormat)
        }
        tapInstalled = true
    }

    /// Runs on the audio thread for every buffer.
    private func deliver(
        _ buffer: AVAudioPCMBuffer,
        at when: AVAudioTime,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat?
    ) {
        updateLevel(from: buffer)

        let outgoing: AVAudioPCMBuffer
        if let converter, let targetFormat {
            guard
                let converted = AudioFormatConverter.convert(
                    buffer, using: converter, to: targetFormat
                )
            else { return }
            outgoing = converted
        } else {
            outgoing = buffer
        }
        // Measured from the *incoming* buffer: the conversion changes the
        // sample rate and the frame count, not the stretch of time the audio
        // came from.
        let end = Self.endHostTime(of: buffer, at: when)

        sinkLock.lock()
        if let sink {
            sink(outgoing)
        } else {
            let wanted = AVAudioFrameCount(
                (preRollSeconds * outgoing.format.sampleRate).rounded(.up))
            if idleRoll.capacityFrames != wanted {
                idleRoll = PreRollBuffer(capacityFrames: wanted)
            }
            idleRoll.append(outgoing)
        }
        // Marked only after the hand-off, so a waiter resumed here knows the
        // audio has already reached the engine rather than merely arrived.
        deliveredThroughHostTime = max(deliveredThroughHostTime, end)
        var due: [CheckedContinuation<Void, Never>] = []
        deliveryWaiters.removeAll { waiter in
            guard waiter.through <= end else { return false }
            if let continuation = waiter.continuation {
                due.append(continuation)
                waiter.continuation = nil
            }
            return true
        }
        sinkLock.unlock()

        for continuation in due { continuation.resume() }
    }

    // MARK: - Waiting for audio that has not been handed over yet

    /// Host time through which the tap has handed audio over.
    private var deliveredThroughHostTime: UInt64 = 0
    private var deliveryWaiters: [DeliveryWaiter] = []

    /// One caller waiting for the buffer that covers a particular instant.
    /// Every field is touched only under `sinkLock`.
    private final class DeliveryWaiter {
        let through: UInt64
        var continuation: CheckedContinuation<Void, Never>?
        /// Set when the timeout fired before the continuation was installed —
        /// a real race, since the timer starts first, and without this the
        /// caller would wait for a resume that is never coming.
        var expired = false
        init(through: UInt64) { self.through = through }
    }

    /// Suspends until the tap has handed over the audio recorded up to
    /// `hostTime`, or until `timeout` elapses.
    ///
    /// The tap delivers a buffer only once it has *filled*, so at the moment a
    /// key is released the last fraction of a second is still inside the
    /// device. Waiting for it is not optional — that is the final word of the
    /// utterance — but what is being waited for is one specific event, and a
    /// fixed sleep has to be sized for the worst case of it. Measured, the
    /// buffer is 100 ms and a release lands uniformly inside one, so the wait
    /// that is always long enough is twice the wait that is usually needed.
    ///
    /// Asking the buffers themselves collapses that: the common case returns
    /// as soon as the covering buffer arrives, and `timeout` only decides how
    /// long to keep believing one is coming.
    public func waitForAudio(recordedThrough hostTime: UInt64, timeout: Duration) async {
        // Nothing will ever be delivered with the device closed, so a caller
        // would sit out the whole timeout for audio that does not exist.
        guard isArmed else { return }

        let waiter = DeliveryWaiter(through: hostTime)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.giveUp(on: waiter)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sinkLock.lock()
            guard deliveredThroughHostTime < hostTime, !waiter.expired else {
                sinkLock.unlock()
                continuation.resume()
                return
            }
            waiter.continuation = continuation
            deliveryWaiters.append(waiter)
            sinkLock.unlock()
        }
        timer.cancel()
    }

    /// Resumes everyone waiting, whether or not their buffer arrived.
    private func releaseDeliveryWaiters() {
        sinkLock.lock()
        var due: [CheckedContinuation<Void, Never>] = []
        for waiter in deliveryWaiters {
            waiter.expired = true
            if let continuation = waiter.continuation {
                due.append(continuation)
                waiter.continuation = nil
            }
        }
        deliveryWaiters.removeAll()
        sinkLock.unlock()
        for continuation in due { continuation.resume() }
    }

    /// Stops waiting for a buffer that has not arrived in time.
    private func giveUp(on waiter: DeliveryWaiter) {
        sinkLock.lock()
        waiter.expired = true
        let continuation = waiter.continuation
        waiter.continuation = nil
        deliveryWaiters.removeAll { $0 === waiter }
        sinkLock.unlock()
        continuation?.resume()
    }

    /// When the audio in `buffer` ends, on the host clock.
    ///
    /// `AVAudioTime` stamps the *first* sample, so the end is that plus the
    /// buffer's own duration. This is the buffer's own account of what it
    /// covers rather than the clock at delivery, and the two differ by the
    /// input latency — reading the clock instead would credit a buffer with
    /// audio recorded after it had already been captured.
    private static func endHostTime(of buffer: AVAudioPCMBuffer, at when: AVAudioTime) -> UInt64 {
        guard when.isHostTimeValid, buffer.format.sampleRate > 0 else {
            return mach_absolute_time()
        }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        return when.hostTime &+ AVAudioTime.hostTime(forSeconds: seconds)
    }

    /// Root-mean-square of the buffer, mapped onto a scale that looks linear
    /// to the eye. Speech sits far too low on a raw amplitude scale to read.
    ///
    /// Measured in slices rather than whole, so the meter can show what
    /// happened *inside* a buffer — see `drainLevelSamples`.
    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let seconds =
            buffer.format.sampleRate > 0
            ? Double(buffer.frameLength) / buffer.format.sampleRate : 0

        let frames = Int(buffer.frameLength)
        let sliceLength = max(1, frames / Self.levelSliceCount)

        levelLock.lock()
        var start = 0
        while start < frames {
            let count = min(sliceLength, frames - start)
            // Runs on the audio thread for every buffer, so the mean square is
            // taken with one vectorized call rather than a scalar loop.
            var meanSquare: Float = 0
            vDSP_measqv(channel + start, 1, &meanSquare, vDSP_Length(count))
            let measured = Self.loudness(ofRMS: meanSquare.squareRoot())

            // Rises instantly and falls away over a few slices, or the bar
            // flickers between words. The coefficient is per 25 ms slice, not
            // per 100 ms buffer as it used to be, so it decays four times as
            // often for the same number — 0.82 here is a gentler fall than
            // 0.82 was, which is what keeps the meter from jittering now that
            // it is sampled four times as finely.
            level = measured > level ? measured : level * 0.82 + measured * 0.18
            // The measurement, not the decayed meter value: the decay exists so
            // the bars do not flicker between words, and counting it here would
            // credit the gaps to the speech either side of them.
            if capturing, measured >= Self.speechLevel {
                speechSecondsMeasured +=
                    buffer.format.sampleRate > 0 ? Double(count) / buffer.format.sampleRate : 0
            }
            levelSamples.append(
                LevelSample(
                    level: level,
                    bands: spectrumWanted
                        ? spectrum.bands(
                            of: channel + start, count: count,
                            sampleRate: buffer.format.sampleRate)
                        : []
                )
            )
            start += count
        }
        // A meter nobody is draining must not grow without bound — during
        // push-to-talk with a streaming engine there is no meter at all.
        if levelSamples.count > Self.maximumBufferedLevels {
            levelSamples.removeFirst(levelSamples.count - Self.maximumBufferedLevels)
        }
        // Never falls: the trailing wait has to cover the worst buffer seen,
        // and a run of short ones does not make the long ones stop happening.
        bufferSeconds = max(bufferSeconds, seconds)
        levelLock.unlock()
    }

    /// Two seconds of slices, which is more than any meter shows at once.
    private static let maximumBufferedLevels = 80

    /// Loudness of one RMS reading, 0...1.
    ///
    /// Linear in decibels between the two ends, then an S-curve, which is the
    /// part that makes speaking look different from not speaking: it pushes
    /// room noise down towards the floor and lifts ordinary speech towards the
    /// top, instead of leaving both in the middle where they look alike.
    public static func loudness(ofRMS rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-7))
        let range = loudDecibels - quietDecibels
        let normalized = max(0, min(1, (decibels - quietDecibels) / range))
        return normalized * normalized * (3 - 2 * normalized)
    }
}

// MARK: - What the system thinks

extension AudioCapture {

    /// Whether macOS considers this process to be recording input right now.
    ///
    /// This is the signal behind the orange microphone indicator, asked of
    /// CoreAudio rather than inferred from our own bookkeeping. `isArmed` says
    /// what this object believes; this says what the operating system will
    /// tell the user. They are allowed to disagree, and when they do it is
    /// this one that is right.
    public static var systemReportsInputRunning: Bool? {
        var pid = getpid()
        var translate = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let translated = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &translate,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject
        )
        guard translated == noErr, processObject != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        var running = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let read = AudioObjectGetPropertyData(
            processObject, &running, 0, nil, &size, &value
        )
        guard read == noErr else { return nil }
        return value != 0
    }

    /// Whether the system's current default input device connects over
    /// Bluetooth.
    ///
    /// AirPods and similar headsets cannot run their high-quality output
    /// profile at the same time as their microphone: opening the mic input
    /// forces macOS to renegotiate the whole link down to a mono voice
    /// profile, audible on anything else using the same device — music, a
    /// call — for as long as the input stays open.
    public static var defaultInputIsBluetooth: Bool {
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let deviceRead = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &deviceID
        )
        guard deviceRead == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return false
        }

        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let transportRead = AudioObjectGetPropertyData(
            deviceID, &transportAddress, 0, nil, &size, &transportType
        )
        guard transportRead == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}
