import Foundation

/// Accumulates streaming recognizer output.
///
/// Finalized results are appended permanently; volatile (in-flight) results
/// are held separately and replaced wholesale on every update, so a revised
/// guess can never leave a duplicated fragment behind. Only `finalText` is
/// ever inserted into another application.
public struct TranscriptBuffer: Equatable, Sendable {

    public private(set) var finalizedText: String = ""
    public private(set) var volatileText: String = ""

    public init() {}

    /// Applies one recognizer result.
    public mutating func apply(text: String, isFinal: Bool) {
        if isFinal {
            finalizedText = TextNormalizer.join(finalizedText, text)
            // A finalized result supersedes whatever was speculated for it.
            volatileText = ""
        } else {
            volatileText = text
        }
    }

    public mutating func reset() {
        finalizedText = ""
        volatileText = ""
    }

    /// Text for the on-screen overlay: settled text plus the current guess.
    public var liveText: String {
        TextNormalizer.join(finalizedText, volatileText)
    }

    /// The string committed to the target application. Volatile text is
    /// deliberately excluded — it is speculative by definition.
    public var finalText: String {
        TextNormalizer.finalize(finalizedText)
    }

    public var isEmpty: Bool {
        finalizedText.isEmpty && volatileText.isEmpty
    }
}
