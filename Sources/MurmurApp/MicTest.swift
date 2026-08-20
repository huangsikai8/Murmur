import AVFoundation
import Foundation
import MurmurCore

/// `Murmur --testmic` — how much speech is lost before the microphone exists?
///
/// The gap at the *start* of an utterance is the mirror of the missing
/// trailing silence at the end, and it was much larger. Real sessions logged
/// 155-466 ms from the key to the first sample, and nothing buffers that
/// window: the input device is not running, so the audio does not exist.
///
/// `StartupAudioBuffer` never covered it. That closes the gap between the
/// microphone running and the recognizer being ready, ~15 ms; this one is
/// entirely before it.
///
/// Four measurements:
///   * cold — the device opened on the key, which is what the app did.
///   * armed — the device already open, a press only swapping the sink.
///   * pre-roll — audio recorded *before* the press, replayed into the session.
///   * cadence — how long the tap holds audio, which sizes the trailing wait.
enum MicTest {

    static func run(iterations: Int = 5) async -> Int32 {
        guard AudioCapture.hasPermission else {
            print("Microphone permission not granted; nothing to measure.")
            return 1
        }
        print("Murmur microphone open-latency test")
        print("Each row: the cost a dictation pays before any audio exists.\n")

        let capture = AudioCapture()
        // Exactly what the app prearms with for the streaming Core ML engines.
        capture.prearm(targetFormat: nil)

        print("── cold: device closed between presses")
        var coldStart: [Double] = []
        for index in 1...iterations {
            let started = await timeOneOpen(capture)
            coldStart.append(started)
            print(String(format: "   %d  start() %6.1f ms", index, started))
            capture.stop()
            try? await Task.sleep(for: .milliseconds(700))
        }

        print("\n── armed: device held open, press only swaps the sink")
        var armedStart: [Double] = []
        do {
            try capture.arm()
        } catch {
            print("   arm() failed: \(error.localizedDescription)")
            return 1
        }
        for index in 1...iterations {
            let started = await timeOneOpen(capture)
            armedStart.append(started)
            print(String(format: "   %d  start() %6.1f ms", index, started))
            capture.idle()
            try? await Task.sleep(for: .milliseconds(700))
        }

        print("")
        let preRollOK = await reportPreRoll(capture)
        print("")
        let cadence = await reportCadence(capture)
        print("")
        let switched = await reportFormatSwitch(capture)
        print("")
        let releases = await reportRelease(capture)
        capture.stop()

        print("")
        report("cold  start()", coldStart)
        report("armed start()", armedStart)
        print("")
        let saved = median(coldStart) - median(armedStart)
        print(String(format: "An armed microphone saves %.0f ms of speech per press.", saved))

        guard preRollOK, cadence, switched, releases else { return 1 }
        return 0
    }

    /// Turning the preference off has to actually put the microphone out.
    ///
    /// `isArmed` is this app's own bookkeeping and proves nothing about what
    /// the user sees. The orange indicator follows CoreAudio's
    /// `kAudioProcessPropertyIsRunningInput` for the process, so that is what
    /// is asked here — the two are allowed to disagree, and when they do it is
    /// CoreAudio that is right.
    private static func reportRelease(_ capture: AudioCapture) async -> Bool {
        print("── release: does stop() put the indicator out?")
        do {
            try capture.arm()
        } catch {
            print("   FAILED: arm() — \(error.localizedDescription)")
            return false
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard let armed = AudioCapture.systemReportsInputRunning else {
            print("   SKIPPED: CoreAudio would not report this process")
            return true
        }
        print("   armed:   isArmed=\(capture.isArmed)  system reports input running=\(armed)")
        guard armed else {
            print("   FAILED: armed, but the system does not consider input running")
            return false
        }

        capture.stop()
        // The property is not updated synchronously with the stop.
        var released = true
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(50))
            released = AudioCapture.systemReportsInputRunning == false
            if released { break }
        }
        let after = AudioCapture.systemReportsInputRunning ?? false
        print("   stopped: isArmed=\(capture.isArmed)  system reports input running=\(after)")
        guard released else {
            print("   FAILED: stop() left the microphone running — the indicator stays lit")
            return false
        }
        print("   the indicator goes out")
        return true
    }

    /// Hands-free re-points the armed device at 16 kHz mono for the detector,
    /// and a push-to-talk session points it back at whatever its engine wants.
    ///
    /// Two things must hold across that. Buffers have to arrive in the *new*
    /// format — Apple's SpeechAnalyzer does not reject a format it did not ask
    /// for, it traps inside the Speech framework — and the pre-roll captured
    /// in the old format must be dropped rather than replayed into the new
    /// session, which is the same trap by a slower route.
    private static func reportFormatSwitch(_ capture: AudioCapture) async -> Bool {
        print("── format switch: re-pointing the armed device")
        guard
            let sixteenK = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                interleaved: false)
        else {
            print("   FAILED: could not build the 16 kHz format")
            return false
        }

        do {
            try capture.arm()
        } catch {
            print("   FAILED: arm() — \(error.localizedDescription)")
            return false
        }
        // Fill the pre-roll at the hardware format, then change formats.
        try? await Task.sleep(for: .seconds(1))
        capture.prearm(targetFormat: sixteenK)

        let replayed = ReplayBox()
        do {
            try capture.start { replayed.record($0) }
        } catch {
            print("   FAILED: start() — \(error.localizedDescription)")
            return false
        }
        let (staleFrames, staleRate) = replayed.summary
        guard staleFrames == 0 else {
            print(String(format: "   FAILED: %d frames at %.0f Hz replayed from before the switch",
                         staleFrames, staleRate))
            return false
        }
        print("   pre-roll from the previous format was dropped, not replayed")

        let live = CadenceBox()
        capture.idle()
        do {
            try capture.start { live.record($0) }
        } catch {
            print("   FAILED: start() — \(error.localizedDescription)")
            return false
        }
        try? await Task.sleep(for: .milliseconds(800))
        capture.idle()

        let (_, rate, count) = live.summary
        guard count > 0 else {
            print("   FAILED: no buffers after the switch")
            return false
        }
        guard rate == 16000 else {
            print(String(format: "   FAILED: still delivering %.0f Hz, not 16000 Hz", rate))
            return false
        }
        print("   buffers now arrive at 16000 Hz")

        // And back, which is what stopping hands-free does.
        capture.prearm(targetFormat: nil)
        let back = CadenceBox()
        do {
            try capture.start { back.record($0) }
        } catch {
            print("   FAILED: start() — \(error.localizedDescription)")
            return false
        }
        try? await Task.sleep(for: .milliseconds(800))
        capture.idle()
        let (_, backRate, backCount) = back.summary
        guard backCount > 0, backRate != 16000 else {
            print("   FAILED: did not return to the hardware format")
            return false
        }
        print(String(format: "   and back to %.0f Hz for push-to-talk", backRate))
        return true
    }

    /// Audio spoken just before the key still has to reach the recognizer, so
    /// starting a session must replay what the idle tap was holding. Measured
    /// as frames delivered *during* `start()` itself: nothing recorded after
    /// the call can be in them.
    private static func reportPreRoll(_ capture: AudioCapture) async -> Bool {
        print("── pre-roll: audio recorded before the press")
        do {
            try capture.arm()
        } catch {
            print("   FAILED: arm() — \(error.localizedDescription)")
            return false
        }
        // Long enough to fill the roll several times over, so what comes back
        // is the cap rather than everything since arming.
        try? await Task.sleep(for: .seconds(2))

        let box = ReplayBox()
        do {
            try capture.start { box.record($0) }
        } catch {
            print("   FAILED: start() — \(error.localizedDescription)")
            return false
        }
        let (frames, rate) = box.summary
        capture.idle()

        guard frames > 0, rate > 0 else {
            print("   FAILED: nothing replayed — a press still loses whatever")
            print("           was said before it")
            return false
        }
        let ms = Double(frames) / rate * 1000
        print(String(format: "   %d frames replayed at %.0f Hz = %.0f ms of speech",
                     frames, rate, ms))
        // The roll is capped at whole buffers, so it holds between one buffer
        // and the cap. Anything under one buffer means it is not working.
        guard ms >= 90 else {
            print("   FAILED: less than one buffer replayed")
            return false
        }
        print("   kept: audio from before the key reaches the session")
        return true
    }

    /// How long the tap holds audio before handing it over, which is exactly
    /// how long `DictationController.trailingCaptureWait` has to exceed: the
    /// buffer containing the moment the key was struck is not delivered until
    /// it has filled.
    private static func reportCadence(_ capture: AudioCapture) async -> Bool {
        print("── cadence: how long the tap holds audio")
        let box = CadenceBox()
        do {
            try capture.start { box.record($0) }
        } catch {
            print("   FAILED: start() — \(error.localizedDescription)")
            return false
        }
        try? await Task.sleep(for: .seconds(2))
        capture.idle()

        let (frames, rate, count) = box.summary
        guard count > 1, rate > 0 else {
            print("   FAILED: no buffers")
            return false
        }
        let ms = Double(frames) / rate * 1000
        print(String(format: "   tap delivers %d frames at %.0f Hz = %.1f ms per buffer (%d seen)",
                     frames, rate, ms, count))
        let observed = capture.observedBufferSeconds * 1000
        print(String(format: "   AudioCapture reports %.1f ms, so the trailing wait is sized to it",
                     observed))
        guard observed >= ms - 0.5 else {
            print("   FAILED: the reported buffer is shorter than the one delivered")
            return false
        }
        return true
    }

    /// Milliseconds for `start()` to return, which is the whole cost of a press
    /// once the device is open: everything before the first sample.
    private static func timeOneOpen(_ capture: AudioCapture) async -> Double {
        let began = ContinuousClock.now
        do {
            try capture.start { _ in }
        } catch {
            print("   start failed: \(error.localizedDescription)")
            return .nan
        }
        return milliseconds(since: began)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func median(_ values: [Double]) -> Double {
        let usable = values.filter { !$0.isNaN }.sorted()
        guard !usable.isEmpty else { return .nan }
        return usable[usable.count / 2]
    }

    private static func report(_ label: String, _ values: [Double]) {
        let usable = values.filter { !$0.isNaN }
        guard !usable.isEmpty else {
            print("   \(label)  no samples")
            return
        }
        print(String(format: "   %@ median %6.1f ms   worst %6.1f ms",
                     label, median(values), usable.max() ?? 0))
    }

    /// Frames handed over synchronously inside `start()` — the replayed
    /// pre-roll, and nothing else.
    private final class ReplayBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        private var rate: Double = 0

        var summary: (Int, Double) {
            lock.lock()
            defer { lock.unlock() }
            return (frames, rate)
        }

        func record(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            frames += Int(buffer.frameLength)
            rate = buffer.format.sampleRate
        }
    }

    /// Largest buffer the tap handed over, which is the interval that decides
    /// how long listening must outlive the key.
    private final class CadenceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: AVAudioFrameCount = 0
        private var rate: Double = 0
        private var count = 0

        var summary: (AVAudioFrameCount, Double, Int) {
            lock.lock()
            defer { lock.unlock() }
            return (frames, rate, count)
        }

        func record(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            frames = max(frames, buffer.frameLength)
            rate = buffer.format.sampleRate
            count += 1
        }
    }
}
