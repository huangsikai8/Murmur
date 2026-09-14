import Accelerate
import Foundation

/// Keeps words nobody said out of a batch engine's transcript.
///
/// Speech models trained on captioned audio answer silence with the caption
/// track's habits — "Thank you.", "you", a bare full stop. Whisper was the first
/// engine here to do it, and `--testsilence` then caught Cohere Transcribe (3 of
/// 4 silent holds) and Granite Speech 5.0 (4 of 4) doing exactly the same, so
/// the guard belongs to every engine that decodes a whole hold, not to one.
///
/// Each check is deliberately weaker than it could be, because dropping a real
/// sentence is worse than letting a stray "." through.
public enum SilenceGuard {

    /// Below this, a hold is not decoded at all.
    ///
    /// -45 dBFS is quieter than a quiet room and far below any voice: real
    /// speech peaks between -25 and -15 dBFS even from across a desk, because
    /// this is the loudest 25 ms of the whole hold, not its average. Chosen to
    /// sit well under speech rather than close to it — a wrong "that was
    /// silence" throws away a sentence, which is the worse failure of the two.
    public static let silenceCeiling: Float = -45

    /// Below this, a transcript that is only a stock filler is taken to be
    /// invented. Quieter than any utterance that could actually have carried the
    /// words, so someone who says "thank you" out loud keeps it.
    public static let inventionFloor: Float = -38

    /// Loudest 25 ms of an utterance, in dBFS.
    ///
    /// Peak rather than average, because a sentence is mostly gaps: averaging
    /// pulls a real utterance down towards the room it was spoken in, and the
    /// question here is whether anything in the hold was ever loud enough to be
    /// a voice.
    public static func peakDecibels(_ samples: [Float], sampleRate: Double = 16000) -> Float {
        peakDecibels(samples, in: 0..<samples.count, sampleRate: sampleRate)
    }

    /// `peakDecibels` over part of an array, without copying it.
    public static func peakDecibels(
        _ samples: [Float], in range: Range<Int>, sampleRate: Double = 16000
    ) -> Float {
        guard !range.isEmpty else { return -.infinity }
        let sliceLength = max(1, Int(sampleRate * 0.025))
        var peak: Float = 0
        var start = range.lowerBound
        while start < range.upperBound {
            let count = min(sliceLength, range.upperBound - start)
            var meanSquare: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                vDSP_measqv(buffer.baseAddress! + start, 1, &meanSquare, vDSP_Length(count))
            }
            peak = max(peak, meanSquare.squareRoot())
            start += count
        }
        return 20 * log10(max(peak, 1e-7))
    }

    /// Whether the text contains anything a person could have said. The most
    /// common answer to near-silence is a bare "." or "...", which carries no
    /// words at all and is safe to drop whatever the audio held.
    public static func carriesWords(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Whether a transcript is one of the stock silence fillers arriving on audio
    /// too quiet to have contained it.
    ///
    /// Both halves are required. The phrases are real things people say, so
    /// they are only distrusted below `inventionFloor`. Whole-transcript matches
    /// only: these words inside a longer sentence are somebody actually
    /// speaking.
    public static func isInventedSilence(_ text: String, peak: Float) -> Bool {
        guard peak < inventionFloor else { return false }
        let stripped = text.lowercased().filter { $0.isLetter || $0.isWhitespace }
            .trimmingCharacters(in: .whitespaces)
        return inventedOnSilence.contains(stripped)
    }

    private static let inventedOnSilence: Set<String> = [
        "you", "i", "thank you", "thanks", "thank you very much", "thanks for watching",
        "thank you for watching", "bye", "bye bye", "blank audio", "silence",
        "music", "applause", "subs by www zeoranger co uk",
    ]
}
