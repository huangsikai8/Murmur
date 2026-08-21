import SwiftUI

/// The iOS 9 Siri waveform: several translucent sine curves, each windowed so
/// it dies away at the edges, drawn over one another so where they overlap they
/// brighten.
///
/// The maths is the one described by the author of `siriwave.js`. A curve is
/// an ordinary sine, `sin(k·x − φ)`, multiplied by a bell that is 1 in the
/// middle and 0 at the ends:
///
///     window(x) = (a / (a + x²))^a          for a = `attenuation`
///
/// That window is the whole trick. Without it the curves run off both sides at
/// full height and read as a signal generator; with it they gather in the
/// middle and taper out, which is what makes the shape look like it is coming
/// from somewhere rather than scrolling past.
///
/// Every curve carries its own frequency, speed, phase and height, so the group
/// drifts in and out of alignment instead of moving as one thick line. Those
/// numbers are fixed rather than random: a wave that is different on every
/// launch cannot be told apart from one that is misbehaving.
struct SiriWave: View {

    /// 0...1, how loud the speaker is right now.
    let amplitude: Double
    /// Seconds since the view appeared, driving the phase.
    let time: Double
    /// Height of the box the wave is drawn in. The wave is centred in it.
    let height: Double

    /// What the curves are actually drawn at.
    ///
    /// The measured level is not used directly, because it is not meant to be:
    /// it is calibrated so that -42 dBFS is nothing and -12 dBFS is everything,
    /// and ordinary speech lands around 0.35-0.6 of that. Multiplying a half-
    /// height of 11 points by 0.4 gives a wave four points tall, which is a
    /// ripple rather than a voice. The curve below lifts the middle of the
    /// range — 0.4 becomes 0.75, 0.6 becomes 0.95 — without ever exceeding the
    /// box, so a loud voice still has somewhere to go.
    ///
    /// The shape is a soft knee, `(1 - e^-kx) / (1 - e^-k)`, rather than a gain
    /// with a ceiling. A gain large enough to make speech fill the box pins
    /// everything above about 0.65 to the top, so raising your voice stops
    /// changing anything — the wave would be at full height for most of a
    /// sentence. This rises steeply at the bottom and eases off towards 1
    /// without ever reaching it early, so every loudness still looks different
    /// from the one above it.
    private var displayAmplitude: Double {
        let level = max(0, min(1, amplitude))
        let knee = (1 - exp(-Self.knee * level)) / (1 - exp(-Self.knee))
        return max(Self.idleAmplitude, knee)
    }

    private static let knee = 2.6

    /// A wave at zero amplitude is a flat line, and a card showing a flat line
    /// for the whole hold reads as the microphone having failed — which is the
    /// one thing the meter exists to rule out. Small enough that speech is
    /// unmistakably different from it.
    private static let idleAmplitude = 0.06

    var body: some View {
        Canvas { context, size in
            // Additive, so overlapping curves brighten rather than paint over
            // each other. This is what gives the middle its glow, and it is
            // the reason the curves are drawn translucent to begin with. Set
            // per fill: `GraphicsContext` carries the blend mode as state, not
            // as a filter.
            for curve in Self.curves {
                var layer = context
                layer.blendMode = .plusLighter
                layer.fill(
                    path(for: curve, in: size),
                    with: .color(curve.color.opacity(curve.opacity))
                )
            }
        }
        .frame(height: height)
        // Speech has to be visible instantly, but the fall back to flat should
        // not be — an abrupt drop to a line between two words reads as the
        // microphone cutting out.
        .animation(.easeOut(duration: 0.12), value: amplitude)
    }

    /// One closed shape per curve: the sine along the top, mirrored back along
    /// the bottom, so the curve has a body rather than being a hairline.
    private func path(for curve: Curve, in size: CGSize) -> Path {
        var path = Path()
        let midY = size.height / 2
        // The window is defined over -2...2, where it is ~1 in the middle and
        // has decayed to nothing by the edges.
        let span = 2.0
        let steps = 64

        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        top.reserveCapacity(steps + 1)
        bottom.reserveCapacity(steps + 1)

        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let x = -span + progress * span * 2
            let window = pow(
                curve.attenuation / (curve.attenuation + x * x), curve.attenuation)
            let wave = sin(curve.frequency * x - time * curve.speed + curve.phase)
            // `maximumHeight` keeps a loud voice inside the box: the curves are
            // summed by the blend, not by arithmetic, but they still have to
            // fit.
            let y = window * wave * displayAmplitude * curve.height * midY * Self.maximumHeight

            let pixelX = progress * size.width
            top.append(CGPoint(x: pixelX, y: midY - y))
            bottom.append(CGPoint(x: pixelX, y: midY + y * Self.thickness))
        }

        path.move(to: top[0])
        for point in top.dropFirst() { path.addLine(to: point) }
        for point in bottom.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// How much of the half-height the loudest curve may use. The blend adds
    /// no height of its own, so the tallest curve is the tallest thing drawn
    /// and it may as well reach the edge of the box.
    private static let maximumHeight = 1.0
    /// How far the mirrored underside sits from the top edge. Below 1 the shape
    /// is a lens rather than a ribbon, which is what the iOS 9 wave looks like.
    private static let thickness = 0.55

    private struct Curve {
        let color: Color
        let opacity: Double
        /// Width of the bell. Larger is narrower — more of the curve is pinned
        /// to the centre.
        let attenuation: Double
        /// Cycles across the box.
        let frequency: Double
        /// How fast it travels. Signs differ so curves cross each other.
        let speed: Double
        let phase: Double
        /// Share of the full height this curve may reach.
        let height: Double
    }

    /// Nine curves in three colours, the arrangement the iOS 9 wave uses.
    ///
    /// Three per colour is what makes it read as depth: one broad curve
    /// carrying the shape, and two narrower faster ones breaking up its edge.
    private static let curves: [Curve] = [
        Curve(color: .red, opacity: 0.55, attenuation: 1.2, frequency: 2.4, speed: 2.2, phase: 0.0, height: 1.00),
        Curve(color: .red, opacity: 0.35, attenuation: 2.4, frequency: 3.7, speed: -3.1, phase: 1.1, height: 0.72),
        Curve(color: .red, opacity: 0.25, attenuation: 3.6, frequency: 5.1, speed: 4.0, phase: 2.3, height: 0.48),

        Curve(color: .green, opacity: 0.45, attenuation: 1.5, frequency: 2.9, speed: -2.6, phase: 0.7, height: 0.88),
        Curve(color: .green, opacity: 0.30, attenuation: 2.8, frequency: 4.3, speed: 3.4, phase: 1.9, height: 0.62),
        Curve(color: .green, opacity: 0.20, attenuation: 4.0, frequency: 6.2, speed: -4.7, phase: 3.0, height: 0.40),

        Curve(color: .blue, opacity: 0.50, attenuation: 1.35, frequency: 2.1, speed: 2.9, phase: 2.0, height: 0.94),
        Curve(color: .blue, opacity: 0.32, attenuation: 2.6, frequency: 4.9, speed: -3.7, phase: 0.4, height: 0.66),
        Curve(color: .blue, opacity: 0.22, attenuation: 3.8, frequency: 6.8, speed: 5.2, phase: 1.5, height: 0.44),
    ]
}
