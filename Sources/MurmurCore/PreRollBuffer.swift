import AVFoundation
import Foundation

/// Holds the most recent audio so it can be replayed once speech is confirmed.
///
/// A detector only knows speech started after it has already been going for a
/// chunk or two — measured at 300 ms worst case with Silero. Feeding the engine
/// from that moment clips the first word of every utterance, so the audio the
/// detector made its decision from has to be kept and replayed.
public struct PreRollBuffer {

    /// Oldest first, which is the order they must be replayed in.
    public private(set) var buffers: [AVAudioPCMBuffer] = []
    public private(set) var frameCount: AVAudioFrameCount = 0

    /// How much audio to keep. Must comfortably exceed the detector's worst
    /// confirmation lag or the clipping comes back.
    public let capacityFrames: AVAudioFrameCount

    public init(capacityFrames: AVAudioFrameCount) {
        self.capacityFrames = capacityFrames
    }

    /// Keeps `seconds` of audio at `sampleRate`.
    public init(seconds: Double, sampleRate: Int) {
        self.init(capacityFrames: AVAudioFrameCount(seconds * Double(sampleRate)))
    }

    public mutating func append(_ buffer: AVAudioPCMBuffer) {
        buffers.append(buffer)
        frameCount += buffer.frameLength
        // Drop whole buffers rather than splitting them: the engines take
        // buffers, and a partial one would need a copy on the audio path.
        while frameCount > capacityFrames, buffers.count > 1 {
            frameCount -= buffers.removeFirst().frameLength
        }
    }

    /// Returns everything held and empties the buffer.
    public mutating func drain() -> [AVAudioPCMBuffer] {
        let held = buffers
        buffers.removeAll()
        frameCount = 0
        return held
    }

    public mutating func reset() {
        buffers.removeAll()
        frameCount = 0
    }
}
