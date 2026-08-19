import AVFoundation
import Foundation

/// Microphone capture that runs only while dictation is active.
///
/// The engine is created and `prepare()`d ahead of time so that `start()` only
/// has to open the input device, which is what keeps hotkey-to-microphone
/// latency in the tens of milliseconds. Nothing is captured while idle.
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
    private let lock = NSLock()

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

    /// Pre-builds the audio graph without opening the microphone, so the
    /// hardware indicator only lights up when dictation actually starts.
    public func prearm(targetFormat: AVAudioFormat?) {
        lock.lock()
        defer { lock.unlock() }
        self.targetFormat = targetFormat
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        if let targetFormat, targetFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }
        engine.prepare()
    }

    /// Opens the microphone and delivers buffers in the engine's target format.
    public func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        if let targetFormat, targetFormat != inputFormat, converter == nil {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        let converter = self.converter
        let targetFormat = self.targetFormat

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let converter, let targetFormat else {
                onBuffer(buffer)
                return
            }
            guard
                let converted = AudioFormatConverter.convert(
                    buffer, using: converter, to: targetFormat
                )
            else { return }
            onBuffer(converted)
        }

        try engine.start()
        isRunning = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        // Leave the graph prepared so the next start() stays fast.
        engine.prepare()
    }
}
