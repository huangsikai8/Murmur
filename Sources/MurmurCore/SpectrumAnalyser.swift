import Accelerate
import Foundation

/// One measurement of the microphone: how loud, and — when a meter asks for it
/// — how that loudness was spread across frequency.
public struct LevelSample: Sendable, Equatable {
    /// 0...1 on `AudioCapture`'s curve.
    public let level: Float
    /// 0...1 per band, low frequencies first. Empty unless
    /// `AudioCapture.analysesSpectrum` is on.
    public let bands: [Float]

    public init(level: Float, bands: [Float] = []) {
        self.level = level
        self.bands = bands
    }
}

/// Splits a slice of audio into a handful of frequency bands, for a meter whose
/// bars move independently.
///
/// A level meter answers "how loud", which is one number however many bars are
/// drawn, so every bar has to say the same thing. This answers "loud at which
/// frequencies", which is what makes a vowel and an "s" look different: vowels
/// put their energy low, sibilants put it high.
///
/// Not reused from `WhisperFeatures`. That is a log-mel front end checked to
/// 1.5e-5 against a reference implementation because a recognizer depends on
/// it; this drives an animation, and holding it to that standard would mean
/// paying for a 201-point mel filterbank forty times a second to decide the
/// height of fourteen rectangles.
public final class SpectrumAnalyser: @unchecked Sendable {

    /// Bars in the spectrum meter. Enough to show the shape of a voice, few
    /// enough that each one is wide enough to see.
    public static let bandCount = 14

    /// 512 samples is ~32 ms at 16 kHz and ~11 ms at 48 kHz, so a 25 ms slice
    /// always has enough to fill it, and the resolution — 31 Hz per bin at
    /// 16 kHz — is finer than the bands need.
    private static let windowLength = 512
    private static let log2n = vDSP_Length(9)

    private let setup: FFTSetup?
    private var window: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var padded: [Float]
    private var magnitudes: [Float]
    /// Bars fall back gradually rather than dropping the instant a sound stops,
    /// which is what makes a spectrum look like it is decaying rather than
    /// flickering.
    private var held: [Float]

    public init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: Self.windowLength)
        // Hann, so a tone that does not fit a whole number of cycles into the
        // window does not smear across every band.
        vDSP_hann_window(&window, vDSP_Length(Self.windowLength), Int32(vDSP_HANN_NORM))
        real = [Float](repeating: 0, count: Self.windowLength / 2)
        imaginary = [Float](repeating: 0, count: Self.windowLength / 2)
        padded = [Float](repeating: 0, count: Self.windowLength)
        magnitudes = [Float](repeating: 0, count: Self.windowLength / 2)
        held = [Float](repeating: 0, count: Self.bandCount)
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    /// Band magnitudes, 0...1, low frequencies first.
    ///
    /// Runs on the audio thread, so everything it needs is allocated once in
    /// `init` and reused.
    public func bands(
        of samples: UnsafePointer<Float>, count: Int, sampleRate: Double
    ) -> [Float] {
        guard let setup, count > 0, sampleRate > 0 else { return held }

        // Short slices are zero-padded rather than skipped: a quiet tail at the
        // end of a buffer is still a measurement, and dropping it would leave
        // the meter holding the previous value.
        let used = min(count, Self.windowLength)
        padded.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.update(from: samples, count: used)
            if used < Self.windowLength {
                destination.baseAddress!.advanced(by: used)
                    .update(repeating: 0, count: Self.windowLength - used)
            }
        }
        vDSP_vmul(padded, 1, window, 1, &padded, 1, vDSP_Length(Self.windowLength))

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                padded.withUnsafeBufferPointer { source in
                    source.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: Self.windowLength / 2
                    ) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(Self.windowLength / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { output in
                    vDSP_zvabs(
                        &split, 1, output.baseAddress!, 1, vDSP_Length(Self.windowLength / 2))
                }
            }
        }

        let binWidth = sampleRate / Double(Self.windowLength)
        var result = [Float](repeating: 0, count: Self.bandCount)

        for band in 0..<Self.bandCount {
            let (low, high) = Self.edges(of: band)
            let firstBin = max(1, Int(low / binWidth))
            let lastBin = min(magnitudes.count - 1, Int(high / binWidth))
            guard firstBin <= lastBin else { continue }

            // Peak within the band, not mean: a band spanning many bins would
            // otherwise dilute a strong narrow tone into nothing.
            var peak: Float = 0
            for bin in firstBin...lastBin { peak = max(peak, magnitudes[bin]) }

            // The FFT is unnormalized and vDSP's real transform carries a
            // factor of two, so this scales back to something comparable with
            // an amplitude before going to decibels.
            let amplitude = peak / Float(Self.windowLength)
            var value = AudioCapture.loudness(ofRMS: amplitude)

            // A voice has far less energy up high than down low — a flat
            // scale leaves the right-hand bars permanently dead. Tilting
            // upwards by frequency is what a spectrum analyser has always
            // done, for exactly this reason.
            value = min(1, value * Self.tilt[band])

            // Attack instantly, fall gradually.
            held[band] = value > held[band] ? value : held[band] * 0.78 + value * 0.22
            result[band] = held[band]
        }
        return result
    }

    /// Band edges in hertz, spaced roughly logarithmically over the range a
    /// voice actually occupies. Above ~8 kHz there is nothing but breath, and a
    /// bar that never moves is worse than no bar.
    public static func edges(of band: Int) -> (low: Double, high: Double) {
        let lowest = 80.0
        let highest = 8000.0
        let ratio = pow(highest / lowest, 1.0 / Double(bandCount))
        let low = lowest * pow(ratio, Double(band))
        return (low, low * ratio)
    }

    /// Per-band gain, rising with frequency to offset the natural roll-off of
    /// speech. Measured by eye against a voice rather than derived: the point
    /// is that all fourteen bars are usable, not that the numbers are physics.
    private static let tilt: [Float] = (0..<bandCount).map { band in
        1.0 + Float(band) / Float(bandCount) * 1.6
    }
}
