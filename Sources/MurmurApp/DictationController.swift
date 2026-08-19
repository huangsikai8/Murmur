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
    var cleanupLevel: CleanupLevel = .off

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
    private var isActive = false
    private var pressedAt: ContinuousClock.Instant?
    private var activeModelID = ModelCatalog.appleSpeechID
    /// False for engines that only produce text when the key is released. The
    /// overlay needs to say so rather than sit empty.
    private var engineStreamsLiveText = true
    private var meterTask: Task<Void, Never>?
    private var activeCorrectionModelID = ModelCatalog.appleCorrectionID

    init(
        engine: any SpeechRecognitionEngine = AppleSpeechEngine(),
        cleaner: any TranscriptCleaner = FoundationModelsCleaner(),
        inserter: any TextInserting = ClipboardPasteInserter()
    ) {
        self.engine = engine
        self.cleaner = cleaner
        self.inserter = inserter
    }

    /// Loads models and pre-builds the audio graph so the first dictation is
    /// no slower than the rest.
    func warmUp() async {
        status = .preparing
        do {
            try await engine.prepare()
            let format = await engine.preferredInputFormat()
            capture.prearm(targetFormat: format)
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
        let desired: any TranscriptCleaner
        if let variant = MLXCleaner.Variant.from(modelID: modelID) {
            desired = MLXCleaner(variant: variant)
        } else {
            desired = FoundationModelsCleaner()
        }
        guard modelID != activeCorrectionModelID else { return }

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
        do {
            try await engine.prepare()
            let format = await engine.preferredInputFormat()
            capture.prearm(targetFormat: format)
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
    }

    func releaseModels() async {
        await engine.releaseModels()
        await cleaner.releaseModels()
        status = .idle
    }

    // MARK: - Hotkey handling

    func begin() {
        guard !isActive else { return }
        if case .unavailable = status { return }
        isActive = true

        latency.begin()
        latency.mark(.hotkeyDown)

        buffer.reset()
        pressedAt = ContinuousClock.now
        focusTarget = FocusTracker.capture()
        overlay.show(showsMeter: !engineStreamsLiveText)
        startMeter()
        status = .listening

        Task { await startPipeline() }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        latency.mark(.hotkeyUp)
        stopMeter()
        capture.stop()

        // Discard an incidental tap without inserting anything.
        let held = pressedAt.map { ContinuousClock.now - $0 } ?? .zero
        if held < minimumHoldDuration {
            status = .idle
            overlay.hide()
            Task { await engine.cancelSession() }
            updatesTask?.cancel()
            updatesTask = nil
            return
        }

        status = .finishing
        overlay.setState(.transcribing)
        Task { await finishPipeline() }
    }

    /// Feeds the overlay's meter from real microphone levels while listening.
    /// Only runs for engines that show no text, since it exists to prove the
    /// microphone is live when nothing else would.
    private func startMeter() {
        guard !engineStreamsLiveText else { return }
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                overlay.pushLevel(capture.currentLevel)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
    }

    // MARK: - Pipeline

    private func startPipeline() async {
        do {
            let updates = try await engine.beginSession()
            latency.mark(.recognizerReady)

            updatesTask = Task { [weak self] in
                for await update in updates {
                    self?.consume(update)
                }
            }

            try capture.start { [weak engine] buffer in
                engine?.append(buffer)
            }
            latency.mark(.microphoneRunning)
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

        if cleanupLevel != .off {
            overlay.setState(.cleaning)
            overlay.update(transcript: transcript)
            do {
                transcript = try await cleaner.clean(transcript, level: cleanupLevel)
            } catch {
                // Cleanup is a convenience: on failure the raw transcript is
                // still inserted rather than losing what was dictated.
                Log.write("cleanup failed, inserting raw transcript: \(error)")
            }
        }
        latency.mark(.cleanupComplete)

        // Enforce the user's own spelling last, so neither the recognizer nor
        // the cleanup model can undo it.
        transcript = VocabularyNormalizer.apply(vocabulary.allTerms, to: transcript)

        // Dismiss before pasting so the overlay is never captured mid-insert.
        overlay.hide()

        if let focusTarget { await FocusTracker.restore(focusTarget) }
        do {
            try inserter.insert(transcript)
        } catch {
            NSLog("[murmur] insertion failed: \(error.localizedDescription)")
        }
        latency.mark(.inserted)
        latency.report()
    }

    private func fail(with error: Error) async {
        isActive = false
        stopMeter()
        capture.stop()
        await engine.cancelSession()
        updatesTask?.cancel()
        updatesTask = nil
        overlay.setState(.error(error.localizedDescription))
        NSLog("[murmur] dictation failed: \(error.localizedDescription)")
        try? await Task.sleep(for: .milliseconds(1200))
        overlay.hide()
        status = .idle
    }
}
