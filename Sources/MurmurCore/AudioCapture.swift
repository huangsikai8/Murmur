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

        public var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access was denied."
            case .converterUnavailable: "Could not convert microphone audio to the engine's format."
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
    public var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    public init() {}

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
        lock.lock()
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
        lock.lock()
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
        lock.lock()
        defer { lock.unlock() }
        try startLocked()

        sinkLock.lock()
        // Drained and installed under one lock, in order, for the same reason
        // `StartupAudioBuffer` does: a task per buffer is not FIFO.
        for buffer in idleRoll.drain() { onBuffer(buffer) }
        sink = onBuffer
        sinkLock.unlock()
    }

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
        levelLock.unlock()
    }

    /// Closes the input device and puts the microphone indicator out.
    public func stop() {
        idle()
        lock.lock()
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

    private func startLocked() throws {
        // Only when there is no tap. Re-installing one on every press would
        // discard whatever buffer the device was part-way through filling,
        // which is the clipped first syllable coming back by another route.
        if !tapInstalled { installTapLocked() }
        guard !isRunning else { return }
        try engine.start()
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
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.deliver(buffer, converter: converter, targetFormat: targetFormat)
        }
        tapInstalled = true
    }

    /// Runs on the audio thread for every buffer.
    private func deliver(
        _ buffer: AVAudioPCMBuffer,
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

        sinkLock.lock()
        defer { sinkLock.unlock() }
        if let sink {
            sink(outgoing)
            return
        }
        let wanted = AVAudioFrameCount(
            (preRollSeconds * outgoing.format.sampleRate).rounded(.up))
        if idleRoll.capacityFrames != wanted {
            idleRoll = PreRollBuffer(capacityFrames: wanted)
        }
        idleRoll.append(outgoing)
    }

    /// Root-mean-square of the buffer, mapped onto a scale that looks linear
    /// to the eye. Speech sits far too low on a raw amplitude scale to read.
    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let seconds =
            buffer.format.sampleRate > 0
            ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
        // Runs on the audio thread for every buffer, so the mean square is
        // taken with one vectorized call rather than a scalar loop.
        var meanSquare: Float = 0
        vDSP_measqv(channel, 1, &meanSquare, vDSP_Length(buffer.frameLength))
        let rms = meanSquare.squareRoot()

        // -50 dB reads as silence, 0 dB as full scale.
        let decibels = 20 * log10(max(rms, 1e-7))
        let normalized = max(0, min(1, (decibels + 50) / 50))

        levelLock.lock()
        // Fall away more slowly than it rises, or the bar flickers between words.
        level = normalized > level ? normalized : level * 0.82 + normalized * 0.18
        // Never falls: the trailing wait has to cover the worst buffer seen,
        // and a run of short ones does not make the long ones stop happening.
        bufferSeconds = max(bufferSeconds, seconds)
        levelLock.unlock()
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
}
