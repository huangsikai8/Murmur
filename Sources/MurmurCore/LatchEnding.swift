import Foundation

/// When a latched session should finalize itself.
///
/// Pure and in `MurmurCore` for the reason `KeyChord` and `StartupAudioBuffer`
/// are: the app target cannot be imported, so a decision left inside
/// `DictationController` is testable only by holding a key for two minutes.
/// This shipped with no test at all, which is how the flat two-minute cap went
/// unexamined for as long as it did.
public enum LatchEnding: Equatable, Sendable {

    /// Keep listening.
    case keepGoing
    /// Nobody has spoken for long enough that the latch was probably forgotten.
    case silence
    /// The absolute ceiling, whatever is being said into it.
    case ceiling

    /// A held key cannot be forgotten; a latch can, and a microphone left open
    /// for the rest of the afternoon is the failure this guards. But the thing
    /// worth ending is a *forgotten* latch, and elapsed time cannot tell one of
    /// those from somebody who simply had a lot to say — a flat cap ends both,
    /// mid-sentence and with no warning.
    ///
    /// Silence separates them, and it is measured rather than assumed:
    /// `AudioCapture.speechSeconds` counts only audio loud enough to be a voice,
    /// so a forgotten latch stops advancing it and a long dictation does not.
    ///
    /// A threshold of zero disables that limit, which is what lets either one be
    /// switched off without a second flag.
    public static func decide(
        quietFor quiet: Duration,
        runningFor running: Duration,
        silenceTimeout: Duration,
        ceiling: Duration
    ) -> LatchEnding {
        // Silence first: a forgotten latch is the case worth catching, and at
        // the ceiling the two are indistinguishable anyway.
        if silenceTimeout > .zero, quiet >= silenceTimeout { return .silence }
        if ceiling > .zero, running >= ceiling { return .ceiling }
        return .keepGoing
    }
}
