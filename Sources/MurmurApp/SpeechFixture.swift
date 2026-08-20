import Foundation

/// Shared plumbing for the offline test commands.
///
/// `--selftest` and `--testhandsfree` both need synthesized speech and elapsed
/// times. They had a copy each, and the two `milliseconds` implementations had
/// already drifted apart.
enum SpeechFixture {

    /// Renders `text` with `say` into a temporary WAV at 16 kHz.
    ///
    /// - Parameter float: `true` for 32-bit float samples, which the detector
    ///   and the batch engine read directly; `false` for 16-bit integer.
    static func synthesize(_ text: String, float: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-fixture-\(UUID().uuidString).wav")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "--file-format=WAVE",
            "--data-format=\(float ? "LEF32" : "LEI16")@16000",
            "-o", url.path, text,
        ]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "Murmur.SpeechFixture", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "`say` failed to synthesize audio"])
        }
        return url
    }

    static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - instant) / .milliseconds(1))
    }
}
