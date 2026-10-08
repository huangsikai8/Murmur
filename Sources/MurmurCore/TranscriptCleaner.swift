import Foundation

/// Optional post-processing between the recognizer and insertion.
///
/// Kept deliberately separate from recognition so the two can be toggled,
/// swapped, and measured independently.
public protocol TranscriptCleaner: AnyObject, Sendable {
    static var cleanerName: String { get }

    /// Loads the model. Safe to call repeatedly.
    func prepare() async throws

    /// Returns a corrected version of `text` at the requested strength.
    /// Implementations must preserve meaning and must never answer questions
    /// contained in the text.
    /// `context` is text already on screen where the transcript will land. It
    /// may only steer spelling and capitalization of names and technical terms;
    /// it is never content to draw phrasing from, and never something to answer.
    func clean(_ text: String, level: CleanupLevel, context: String?) async throws -> String

    /// Drops the model from memory.
    func releaseModels() async

    /// Terms the cleaner must not rewrite.
    func setProtectedTerms(_ terms: [String]) async
}

extension TranscriptCleaner {
    /// Cleaners that do not rewrite anything ignore the word list.
    public func setProtectedTerms(_ terms: [String]) async {}

    /// Callers with nothing on screen to offer, and every existing call site.
    public func clean(_ text: String, level: CleanupLevel) async throws -> String {
        try await clean(text, level: level, context: nil)
    }
}

/// Default cleaner: returns the transcript untouched.
///
/// Used when AI cleanup is off, and as the Phase 1-4 stand-in so the pipeline
/// slot exists before a model is wired in.
public final class PassthroughCleaner: TranscriptCleaner {
    public static let cleanerName = "None (raw transcript)"

    public init() {}
    public func prepare() async throws {}
    public func clean(_ text: String, level: CleanupLevel, context: String?) async throws
        -> String
    { text }
    public func releaseModels() async {}
}
