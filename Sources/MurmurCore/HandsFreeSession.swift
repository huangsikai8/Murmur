import AVFoundation
import Foundation

/// Continuous dictation: audio in, finished utterances out.
///
/// This owns the whole sequence — detector, pre-roll, and the engine's session
/// lifecycle — so that the app and the self-test drive exactly the same code.
/// Keeping the sequence in one place is deliberate: the last time engine
/// selection existed in two copies they drifted, and the self-test passed on a
/// path the app never ran.
public actor HandsFreeSession {

    public enum Event: Sendable, Equatable {
        /// Speech was confirmed; the caller should show its listening UI.
        case utteranceBegan
        /// One finished utterance. Already normalized, never empty.
        case transcript(String)
        /// Speech ended but produced nothing usable.
        case utteranceDiscarded
        /// Speech stopped, but the turn detector judged the thought unfinished,
        /// so the utterance is still open and nothing has been inserted. The
        /// caller should keep showing its listening UI.
        case turnHeld(probability: Float)
    }

    private var engine: any SpeechRecognitionEngine
    private let detector: VoiceActivityDetector
    private var preRoll: PreRollBuffer
    private var isOpen = false

    /// Judges whether a pause is the end of a turn or the middle of a thought.
    /// Optional: without it this endpoints on silence alone, as it always did.
    private var turnDetector: TurnDetector?
    /// How long a held turn may stay open with no further speech. The detector
    /// can be wrong, and an utterance that never finalizes is a stopped app —
    /// so silence still wins in the end, just not at 250 ms.
    private var holdCeiling: Duration = .seconds(3)
    private var awaitingContinuation = false
    private var holdDeadline: ContinuousClock.Instant?
    /// Trailing audio for the detector, in its 16 kHz input format. Capped at
    /// the 8 s the model looks at plus a block of slack, so this cannot grow
    /// without bound.
    private var turnAudio: [Float] = []
    /// How far past the window `turnAudio` may run before it is compacted.
    /// One second, so the shift happens about once a second instead of about
    /// fifty times.
    private static let turnAudioSlack = VoiceActivityDetector.sampleRate

    /// Audio arrives in the detector's format, which is not necessarily the
    /// engine's. Apple's SpeechAnalyzer traps inside the framework when handed
    /// a format it did not ask for, so this conversion is not optional.
    private var engineFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    /// Partial results, for callers that show live text. Never inserted.
    public var onPartial: (@Sendable (String) -> Void)?
    private var updatesTask: Task<Void, Never>?
    /// Accumulates partials for display. A `TranscriptUpdate` carries only its
    /// own chunk, so showing it directly replaces the sentence on screen with
    /// its last few words instead of growing it.
    private var buffer = TranscriptBuffer()

    public init(
        engine: any SpeechRecognitionEngine,
        tuning: VoiceActivityDetector.Tuning = VoiceActivityDetector.Tuning(),
        preRollSeconds: Double = 0.5
    ) {
        self.engine = engine
        self.detector = VoiceActivityDetector(tuning: tuning)
        self.preRoll = PreRollBuffer(
            seconds: preRollSeconds, sampleRate: VoiceActivityDetector.sampleRate)
    }

    /// Swaps the engine between utterances. Ignored while one is open, since
    /// changing engines mid-sentence would lose the audio already fed in.
    public func setEngine(_ engine: any SpeechRecognitionEngine) async {
        guard !isOpen else { return }
        self.engine = engine
        await refreshEngineFormat()
    }

    public func setTuning(_ tuning: VoiceActivityDetector.Tuning) async {
        await detector.setTuning(tuning)
    }

    /// Installs the turn detector. Passing nil restores plain silence
    /// endpointing.
    public func setTurnDetector(_ detector: TurnDetector?, ceiling: Duration = .seconds(3)) {
        turnDetector = detector
        holdCeiling = ceiling
        awaitingContinuation = false
        holdDeadline = nil
    }

    public func setPartialHandler(_ handler: (@Sendable (String) -> Void)?) {
        onPartial = handler
    }

    public func prepare() async throws {
        try await detector.prepare()
        try await engine.prepare()
        await refreshEngineFormat()
    }

    /// Rebuilds the conversion into whatever the current engine wants. A nil
    /// preferred format means the engine resamples internally and buffers pass
    /// through untouched.
    private func refreshEngineFormat() async {
        engineFormat = await engine.preferredInputFormat()
        guard let engineFormat, let source = inputFormat, engineFormat != source else {
            converter = nil
            return
        }
        converter = AVAudioConverter(from: source, to: engineFormat)
    }

    /// Hands one buffer to the engine in the format it expects.
    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let engineFormat else {
            engine.append(buffer)
            return
        }
        guard let converted = AudioFormatConverter.convert(
            buffer, using: converter, to: engineFormat)
        else { return }
        engine.append(converted)
    }

    /// The format audio must arrive in: the detector's, which every engine
    /// either wants already or resamples from.
    public nonisolated var inputFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(VoiceActivityDetector.sampleRate),
            channels: 1,
            interleaved: false)
    }

    /// Feeds one buffer and returns whatever it completed, in order.
    public func ingest(_ buffer: AVAudioPCMBuffer) async -> [Event] {
        if isOpen {
            feed(buffer)
        } else {
            // Held in the detector's format and converted only if it is
            // actually replayed, so idle capture does no conversion work.
            preRoll.append(buffer)
        }

        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))

        // Kept for every buffer, open or not, so the pre-roll the detector
        // needed to confirm speech is already in the window when the turn
        // detector is asked about it.
        turnAudio.append(contentsOf: samples)
        // Trimmed in blocks, not on every buffer. Holding the window to exactly
        // 8 s means memmoving half a megabyte per buffer, roughly fifty times a
        // second — the same cost `VoiceActivityDetector.process` already avoids
        // by compacting once instead of per chunk. `WhisperFeatures.fit` takes
        // the *suffix* it needs, so carrying a second of slack changes nothing
        // the detector sees.
        if turnAudio.count > WhisperFeatures.sampleCount + Self.turnAudioSlack {
            turnAudio.removeFirst(turnAudio.count - WhisperFeatures.sampleCount)
        }

        guard let boundaries = try? await detector.process(samples) else {
            return await expireHeldTurn()
        }

        var events: [Event] = []
        for boundary in boundaries {
            switch boundary {
            case .speechStarted:
                if awaitingContinuation {
                    // The same turn resuming. The engine session was never
                    // closed, so this is a pause inside one utterance rather
                    // than the start of a new one.
                    awaitingContinuation = false
                    holdDeadline = nil
                } else if await open() {
                    events.append(.utteranceBegan)
                }
            case .speechEnded:
                if let event = await endOfSpeech() { events.append(event) }
            }
        }
        return events + (await expireHeldTurn())
    }

    /// Finalizes a held turn once its ceiling passes, so a detector that keeps
    /// saying "unfinished" cannot hold text hostage indefinitely.
    private func expireHeldTurn() async -> [Event] {
        guard awaitingContinuation, let holdDeadline, ContinuousClock.now >= holdDeadline
        else { return [] }
        awaitingContinuation = false
        self.holdDeadline = nil
        guard let event = await finalize() else { return [] }
        return [event]
    }

    /// Silence has been detected. Whether that ends the utterance is the turn
    /// detector's call — without one it always did.
    private func endOfSpeech() async -> Event? {
        guard isOpen else { return nil }
        if let turnDetector, let decision = await turnDetector.evaluate(turnAudio),
            !decision.isComplete
        {
            awaitingContinuation = true
            holdDeadline = ContinuousClock.now + holdCeiling
            return .turnHeld(probability: decision.probability)
        }
        return await finalize()
    }

    private func open() async -> Bool {
        guard !isOpen else { return false }
        buffer.reset()
        do {
            let updates = try await engine.beginSession()
            updatesTask = Task { [weak self] in
                for await update in updates {
                    guard let self else { return }
                    await handle(update)
                }
            }
        } catch {
            preRoll.reset()
            return false
        }
        isOpen = true
        // The detector confirms speech only after it has begun, so the audio it
        // decided from must be replayed or the first word is lost.
        for buffered in preRoll.drain() { feed(buffered) }
        return true
    }

    private func handle(_ update: TranscriptUpdate) {
        guard !update.text.isEmpty else { return }
        buffer.apply(text: update.text, isFinal: update.isFinal)
        // Volatile text reaches the overlay only. What gets inserted is still
        // the engine's own final transcript, never this.
        onPartial?(buffer.liveText)
    }

    private func finalize() async -> Event? {
        guard isOpen else { return nil }
        isOpen = false
        awaitingContinuation = false
        holdDeadline = nil
        turnAudio.removeAll(keepingCapacity: true)

        let transcript: String
        do {
            transcript = try await engine.finishSession()
        } catch {
            updatesTask?.cancel()
            updatesTask = nil
            return .utteranceDiscarded
        }
        updatesTask?.cancel()
        updatesTask = nil

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .utteranceDiscarded : .transcript(trimmed)
    }

    /// Ends the utterance in progress right now, without waiting for the
    /// detector to agree that speech has stopped.
    ///
    /// This is the manual override for the whole endpointing question: the VAD
    /// silence wait and the turn detector both exist to guess when a speaker is
    /// done, and neither is needed when the speaker says so. Returns the same
    /// event `ingest` would have produced, so the caller's handling is shared.
    public func finalizeNow() async -> Event? {
        guard isOpen else { return nil }
        return await finalize()
    }

    /// Throws away the utterance in progress without stopping the mode.
    public func cancelUtterance() async {
        guard isOpen else { return }
        isOpen = false
        awaitingContinuation = false
        holdDeadline = nil
        turnAudio.removeAll(keepingCapacity: true)
        updatesTask?.cancel()
        updatesTask = nil
        await engine.cancelSession()
        await detector.reset()
        preRoll.reset()
    }

    public func reset() async {
        await cancelUtterance()
        await detector.reset()
        preRoll.reset()
    }

    public func releaseModels() async {
        await reset()
        await detector.releaseModels()
    }
}
