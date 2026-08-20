import Accelerate
import Foundation

/// Whisper's log-mel front end, as smart-turn's ONNX graph expects it.
///
/// This is a port of `WhisperFeatureExtractor(chunk_length=8)` with
/// `do_normalize=True`. It has to match bit-for-bit in behaviour or the model
/// silently returns confident nonsense — there is no wrong-input signal from an
/// ONNX graph, only a number. `MurmurTests` checks it against features dumped
/// from the reference implementation.
///
/// Fixed to smart-turn's shape on purpose: 8 s at 16 kHz in, 80 x 800 out.
public struct WhisperFeatures {

    public static let sampleRate = 16000
    public static let chunkSeconds = 8
    /// 128000 samples: exactly what the model's `input_features` covers.
    public static let sampleCount = sampleRate * chunkSeconds
    public static let melBins = 80
    public static let frameCount = sampleCount / hopLength  // 800
    static let fftSize = 400
    static let hopLength = 160
    static let spectrumBins = fftSize / 2 + 1  // 201

    /// Hann window, periodic — `window_function(400, "hann")` defaults to
    /// periodic, and the symmetric variant shifts every coefficient slightly.
    private let window: [Float]
    /// Row-major [melBins][spectrumBins], ready for one matrix multiply.
    private let melFilters: [Float]
    /// Row-major [spectrumBins][fftSize] real and imaginary DFT bases.
    private let dftReal: [Float]
    private let dftImaginary: [Float]

    public init() {
        window = (0..<Self.fftSize).map {
            0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(Self.fftSize))
        }
        melFilters = Self.slaneyMelFilterBank()
        (dftReal, dftImaginary) = Self.dftMatrices()
    }

    // MARK: - Mel filter bank

    /// Slaney-scale mel, which is what `mel_filter_bank(..., norm: "slaney",
    /// mel_scale: "slaney")` builds. The HTK formula is the usual alternative
    /// and produces a visibly different bank.
    private static func hzToMel(_ hz: Double) -> Double {
        let fSp = 200.0 / 3.0
        let minLogHz = 1000.0
        let minLogMel = minLogHz / fSp
        let logStep = log(6.4) / 27.0
        return hz < minLogHz ? hz / fSp : minLogMel + log(hz / minLogHz) / logStep
    }

    private static func melToHz(_ mel: Double) -> Double {
        let fSp = 200.0 / 3.0
        let minLogHz = 1000.0
        let minLogMel = minLogHz / fSp
        let logStep = log(6.4) / 27.0
        return mel < minLogMel ? fSp * mel : minLogHz * exp(logStep * (mel - minLogMel))
    }

    private static func slaneyMelFilterBank() -> [Float] {
        let nyquist = Double(sampleRate) / 2.0
        let fftFreqs = (0..<spectrumBins).map { Double($0) * nyquist / Double(spectrumBins - 1) }

        let melMin = hzToMel(0), melMax = hzToMel(nyquist)
        let edges = (0..<(melBins + 2)).map { index -> Double in
            melToHz(melMin + (melMax - melMin) * Double(index) / Double(melBins + 1))
        }

        var filters = [Float](repeating: 0, count: melBins * spectrumBins)
        for mel in 0..<melBins {
            let lower = edges[mel], center = edges[mel + 1], upper = edges[mel + 2]
            // Slaney normalization: each filter integrates to a constant, so
            // wide high-frequency filters do not dominate.
            let enorm = 2.0 / (upper - lower)
            for bin in 0..<spectrumBins {
                let freq = fftFreqs[bin]
                let rising = (freq - lower) / (center - lower)
                let falling = (upper - freq) / (upper - center)
                let weight = max(0.0, min(rising, falling))
                filters[mel * spectrumBins + bin] = Float(weight * enorm)
            }
        }
        return filters
    }

    // MARK: - Discrete Fourier transform

    /// The transform is done as one matrix multiply rather than an FFT.
    ///
    /// A 400-point FFT is awkward here: 400 = 2^4 * 25, and Accelerate's DFT
    /// only accepts lengths of f * 2^n for f in {1, 3, 5, 15}, so vDSP cannot
    /// take it and a hand-written mixed-radix version measured at 34 ms — most
    /// of it allocation inside the recursion. Multiplying by a precomputed
    /// 201 x 400 DFT matrix is exact, allocation-free, and hands the work to
    /// BLAS, which is what the hardware is good at.
    private static func dftMatrices() -> (real: [Float], imaginary: [Float]) {
        var real = [Float](repeating: 0, count: spectrumBins * fftSize)
        var imaginary = [Float](repeating: 0, count: spectrumBins * fftSize)
        for bin in 0..<spectrumBins {
            for sample in 0..<fftSize {
                let angle = -2.0 * Double.pi * Double(bin) * Double(sample) / Double(fftSize)
                real[bin * fftSize + sample] = Float(cos(angle))
                imaginary[bin * fftSize + sample] = Float(sin(angle))
            }
        }
        return (real, imaginary)
    }

    // MARK: - Extraction

    /// Trims to the last 8 s or left-pads with silence to reach it, which is
    /// what the reference `truncate_audio_to_last_n_seconds` does. Padding goes
    /// at the *front* so the end of speech stays at the end of the window.
    public static func fit(_ samples: [Float]) -> [Float] {
        if samples.count > sampleCount { return Array(samples.suffix(sampleCount)) }
        if samples.count < sampleCount {
            return [Float](repeating: 0, count: sampleCount - samples.count) + samples
        }
        return samples
    }

    /// Log-mel features for exactly `sampleCount` samples, flattened row-major
    /// as [melBins][frameCount].
    public func extract(_ fitted: [Float]) -> [Float] {
        precondition(fitted.count == Self.sampleCount, "expected \(Self.sampleCount) samples")

        // Zero mean, unit variance over the whole padded window — including the
        // silence, which is what the reference does when the caller has already
        // padded to 8 s.
        var samples = fitted
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        var negativeMean = -mean
        vDSP_vsadd(samples, 1, &negativeMean, &samples, 1, vDSP_Length(samples.count))
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        var scale = 1.0 / sqrt(meanSquare + 1e-7)
        vDSP_vsmul(samples, 1, &scale, &samples, 1, vDSP_Length(samples.count))

        // center=True with reflect padding, the default the reference relies on.
        let pad = Self.fftSize / 2
        var padded = [Float](repeating: 0, count: samples.count + 2 * pad)
        for index in 0..<pad { padded[index] = samples[pad - index] }
        for index in 0..<samples.count { padded[pad + index] = samples[index] }
        for index in 0..<pad {
            padded[pad + samples.count + index] = samples[samples.count - 2 - index]
        }

        // Every windowed frame as one [fftSize][frames] matrix. The transform
        // is then two matrix multiplies over the whole spectrogram instead of
        // 800 separate ones. Frame 801 is never built, which is what
        // `log_spec[:, :-1]` drops in the reference.
        let frames = Self.frameCount
        var windowed = [Float](repeating: 0, count: Self.fftSize * frames)
        for frame in 0..<frames {
            let start = frame * Self.hopLength
            for index in 0..<Self.fftSize {
                windowed[index * frames + frame] = padded[start + index] * window[index]
            }
        }

        // (201 x 400) * (400 x 800) -> (201 x 800), once for each basis.
        var real = [Float](repeating: 0, count: Self.spectrumBins * frames)
        var imaginary = [Float](repeating: 0, count: Self.spectrumBins * frames)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasNoTrans,
            Int32(Self.spectrumBins), Int32(frames), Int32(Self.fftSize),
            1, dftReal, Int32(Self.fftSize), windowed, Int32(frames),
            0, &real, Int32(frames))
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasNoTrans,
            Int32(Self.spectrumBins), Int32(frames), Int32(Self.fftSize),
            1, dftImaginary, Int32(Self.fftSize), windowed, Int32(frames),
            0, &imaginary, Int32(frames))

        var power = [Float](repeating: 0, count: Self.spectrumBins * frames)
        vDSP_vsq(real, 1, &power, 1, vDSP_Length(power.count))
        vDSP_vsq(imaginary, 1, &imaginary, 1, vDSP_Length(imaginary.count))
        vDSP_vadd(power, 1, imaginary, 1, &power, 1, vDSP_Length(power.count))

        // (80 x 201) * (201 x 800) -> (80 x 800)
        var mel = [Float](repeating: 0, count: Self.melBins * frames)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasNoTrans,
            Int32(Self.melBins), Int32(frames), Int32(Self.spectrumBins),
            1, melFilters, Int32(Self.spectrumBins), power, Int32(frames),
            0, &mel, Int32(frames))

        // log10, floored 8 decades below the peak, then shifted into range.
        var floorValue: Float = 1e-10
        vDSP_vthr(mel, 1, &floorValue, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlog10f(&mel, mel, &count)

        var peak: Float = 0
        vDSP_maxv(mel, 1, &peak, vDSP_Length(mel.count))
        var clamp = peak - 8.0
        vDSP_vthr(mel, 1, &clamp, &mel, 1, vDSP_Length(mel.count))

        var offset: Float = 4.0
        var quarter: Float = 0.25
        vDSP_vsadd(mel, 1, &offset, &mel, 1, vDSP_Length(mel.count))
        vDSP_vsmul(mel, 1, &quarter, &mel, 1, vDSP_Length(mel.count))
        return mel
    }
}
