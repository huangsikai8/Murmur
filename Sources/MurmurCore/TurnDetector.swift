import Foundation

/// Decides whether a speaker has actually finished, rather than merely stopped
/// making noise.
///
/// Silence duration is a proxy for "they are done", and it is a bad one:
/// people pause mid-sentence several times a minute, and a detector that
/// endpoints on silence alone commits at every one of them. That is what makes
/// continuous dictation feel time-pressured — every pause is a commitment,
/// because insertion cannot be taken back.
///
/// smart-turn v3 reads the *waveform*, not the transcript, so it hears the
/// difference between a sentence that landed and one left hanging. It is
/// consulted only when the VAD reports silence, which lets that silence
/// threshold drop: the wait stops carrying the whole burden of the decision.
///
/// 8M parameters, 8 MB on disk, ~29 ms per decision measured here. BSD-2-Clause.
public actor TurnDetector {

    public struct Decision: Sendable {
        /// Probability that the turn is finished, in 0...1.
        public let probability: Float
        public let isComplete: Bool
        /// What the decision cost, features included.
        public let elapsed: Duration
    }

    /// The int8 CPU build. The GPU one is the same graph at a precision the
    /// ANE would not take anyway, and this runs in under 30 ms on CPU.
    private static let fileName = "smart-turn-v3.2-cpu.onnx"
    private static let remote = URL(
        string: "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/main/\(fileName)")!

    public static var modelDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("smart-turn", isDirectory: true)
    }

    public static var modelPath: URL { modelDirectory.appendingPathComponent(fileName) }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Fetches the weights. Downloads to a sibling path and moves into place,
    /// so an interrupted download cannot leave a truncated model that loads and
    /// then predicts nonsense.
    @discardableResult
    public static func download() async throws -> URL {
        if isInstalled { return modelPath }
        try FileManager.default.createDirectory(
            at: modelDirectory, withIntermediateDirectories: true)
        let (temporary, response) = try await URLSession.shared.download(from: remote)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OnnxSession.Failure.ort("download failed with HTTP \(http.statusCode)")
        }
        let staged = modelDirectory.appendingPathComponent(fileName + ".partial")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: temporary, to: staged)
        try? FileManager.default.removeItem(at: modelPath)
        try FileManager.default.moveItem(at: staged, to: modelPath)
        return modelPath
    }

    /// Above this the turn is treated as finished. 0.5 is the reference
    /// threshold; raising it makes the detector more willing to wait.
    public var threshold: Float

    private let features = WhisperFeatures()
    private var session: OnnxSession?

    public init(threshold: Float = 0.5) {
        self.threshold = threshold
    }

    public func setThreshold(_ value: Float) {
        threshold = value
    }

    public var isReady: Bool { session != nil }

    public func prepare() async throws {
        guard session == nil else { return }
        let path = try await Self.download()
        session = try OnnxSession(
            modelPath: path.path, inputName: "input_features", outputName: "logits")
    }

    public func releaseModel() {
        session = nil
    }

    /// Judges the turn from its trailing audio, which must be 16 kHz mono.
    ///
    /// Returns nil when the model is not loaded, so a caller can fall back to
    /// plain silence endpointing rather than stalling. Everything shorter than
    /// 8 s is left-padded, so the end of speech always sits at the end of the
    /// window — the model was trained to look there.
    public func evaluate(_ samples: [Float]) -> Decision? {
        guard let session else { return nil }
        let clock = ContinuousClock()
        var probability: Float = 0
        let elapsed = clock.measure {
            let input = features.extract(WhisperFeatures.fit(samples))
            probability = (try? session.run(input: input, shape: [1, 80, 800]))?.first ?? 1
        }
        return Decision(
            probability: probability, isComplete: probability > threshold, elapsed: elapsed)
    }
}
