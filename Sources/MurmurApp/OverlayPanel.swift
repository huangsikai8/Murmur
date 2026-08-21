import AppKit
import MurmurCore
import SwiftUI

/// Borderless, non-activating panel that shows live transcription.
///
/// `.nonactivatingPanel` plus `canBecomeKey == false` means showing it never
/// moves keyboard focus, so the text field the user was typing in stays
/// focused and receives the paste at the end.
@MainActor
final class OverlayPanel {

    private let panel: NSPanel
    private let model = OverlayModel()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    /// Shows the indicator without taking focus.
    ///
    /// `showsMeter` is for engines that produce no text until the key is
    /// released. An empty card for the whole hold reads as a failure, so those
    /// get a live input meter and an explicit note about when text arrives.
    func show(showsMeter: Bool = false) {
        model.transcript = ""
        model.state = .listening
        model.showsMeter = showsMeter
        model.levels = Array(repeating: 0, count: OverlayModel.meterBarCount)
        model.level = 0
        model.bands = Array(repeating: 0, count: SpectrumAnalyser.bandCount)
        model.isActive = true
        reposition()
        panel.orderFrontRegardless()
    }

    /// Appends one input-level sample, scrolling the meter leftward.
    func pushLevel(_ value: Float) {
        pushLevels([value])
    }

    /// Appends a run of samples in one go.
    ///
    /// The tap hands over several slices at a time, and publishing each one
    /// separately would lay the card out once per bar for no visible gain.
    func pushLevels(_ values: [Float]) {
        push(values.map { LevelSample(level: $0) })
    }

    /// Appends measurements, with their spectrum when one was taken.
    func push(_ samples: [LevelSample]) {
        guard model.showsMeter, !samples.isEmpty else { return }
        var levels = model.levels
        levels.append(contentsOf: samples.map { max(0, min(1, $0.level)) })
        if levels.count > OverlayModel.meterBarCount {
            levels.removeFirst(levels.count - OverlayModel.meterBarCount)
        }
        model.levels = levels
        model.level = levels.last ?? 0
        if let bands = samples.last?.bands, !bands.isEmpty {
            model.bands = bands
        }
    }

    func setMeterStyle(_ style: MeterStyle) {
        model.style = style
    }

    func update(transcript: String) {
        model.transcript = transcript
    }

    func setState(_ state: OverlayModel.State) {
        model.state = state
    }

    func hide() {
        panel.orderOut(nil)
        // Tears down the animated content. A `.repeatForever` animation keeps
        // ticking in a hidden window, which is not free.
        model.isActive = false
        model.transcript = ""
    }

    /// Bottom-centre of whichever screen holds the pointer.
    private func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        // Fixed container; the card inside sizes itself and anchors to the
        // bottom, so a growing transcript expands upward without re-laying out
        // the window on every partial result.
        let width = min(CGFloat(620), frame.width - 80)
        let height = CGFloat(160)

        panel.setFrame(
            NSRect(
                x: frame.midX - width / 2,
                y: frame.minY + 120,
                width: width,
                height: height
            ),
            display: true
        )
    }
}

/// How the input meter is drawn while a batch engine is listening.
///
/// Only the shape changes: every style is fed the same measured loudness, sits
/// in the same fixed box, and never resizes the card.
enum MeterStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Scrolling history, newest on the right. One bar per 25 ms.
    case waveform
    /// One loudness value shaping every bar at once, tallest in the middle.
    case pulse
    /// Real frequency bands, each bar moving on its own.
    case spectrum
    /// Loudness again, with per-bar drift so the bars do not move in lockstep.
    case lively
    /// The iOS 9 Siri wave: overlapping translucent curves.
    case siri

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .waveform: "Scrolling waveform"
        case .pulse: "Pulse"
        case .spectrum: "Frequency bands"
        case .lively: "Bouncing bars"
        case .siri: "Siri wave"
        }
    }

    var summary: String {
        switch self {
        case .waveform:
            "The last 0.7 seconds of your voice, scrolling past."
        case .pulse:
            "One shape that rises and falls with how loud you are."
        case .spectrum:
            "Each bar is a frequency, so vowels and consonants look different."
        case .lively:
            "Loudness again, but the bars drift instead of moving together."
        case .siri:
            "Overlapping curves that gather in the middle, as in iOS."
        }
    }

    /// Whether this style needs the frequency analysis switched on.
    var needsSpectrum: Bool { self == .spectrum }

    /// Whether this style animates between measurements rather than only when
    /// a new one arrives.
    var needsClock: Bool { self == .siri || self == .lively || self == .pulse }
}

@MainActor
final class OverlayModel: ObservableObject {
    enum State: Equatable {
        case listening
        case transcribing
        case cleaning
        /// Nothing could receive the text, so it went to the clipboard.
        case copiedToClipboard
        /// The last insertion was taken back.
        case scratched
        /// There was nothing left that could be taken back.
        case nothingToScratch
        case error(String)
    }

    static let meterBarCount = 28

    @Published var transcript: String = ""
    @Published var state: State = .listening
    /// Drives whether the animated content exists at all.
    @Published var isActive: Bool = false
    /// True for engines that only produce text on release.
    @Published var showsMeter: Bool = false
    /// Recent input levels, oldest first. Real microphone data, not decoration.
    @Published var levels: [Float] = Array(repeating: 0, count: meterBarCount)
    /// The most recent level on its own, for the styles that draw one value.
    @Published var level: Float = 0
    /// Band magnitudes, low frequencies first. Only filled for `.spectrum`.
    @Published var bands: [Float] = Array(repeating: 0, count: SpectrumAnalyser.bandCount)
    @Published var style: MeterStyle = .waveform
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            // Building the card only while active means no animation runs, and
            // no view tree exists, while Murmur sits idle in the menu bar.
            if model.isActive { card }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 9, height: 9)
                    .opacity(pulse ? 1.0 : 0.35)
                    .animation(
                        model.state == .listening
                            ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                            : .default,
                        value: pulse
                    )
                if showsMeter {
                    meter
                } else {
                    Text(label)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            if showsMeter {
                Text("Listening — text appears when you release")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if !model.transcript.isEmpty {
                Text(model.transcript)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(minWidth: 280, maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .onAppear { pulse = true }
    }

    /// The meter belongs to the listening phase only; once the key is released
    /// there is no more input and the card switches to reporting progress.
    private var showsMeter: Bool {
        model.showsMeter && model.state == .listening
    }

    /// The meter, in whichever shape the speaker chose.
    ///
    /// Every style is handed the same measured loudness and draws inside the
    /// same fixed box — `meterWidth` by `meterHeight` — so switching style
    /// never moves anything else on the card.
    @ViewBuilder private var meter: some View {
        Group {
            switch model.style {
            case .waveform: scrollingWaveform
            case .pulse: pulseBars
            case .spectrum: spectrumBars
            case .lively: bouncingBars
            case .siri: siriWave
            }
        }
        .frame(width: Self.meterWidth, height: Self.meterHeight)
    }

    private static let meterWidth: CGFloat = 165
    private static let meterHeight: CGFloat = 22
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 3

    /// Bars are 25 ms of audio each, newest on the right.
    ///
    /// Deliberately not animated. `ForEach` here is keyed by position, so a
    /// scrolling meter is not 28 bars moving, it is 28 bars each taking the
    /// height of its neighbour — and animating that interpolates every bar
    /// towards the value beside it, which smears the waveform into a blur and
    /// pays for 28 interpolations every 25 ms to do it. The bars arrive 40
    /// times a second; that is already smooth, and a redraw is far cheaper
    /// than a transition.
    private var scrollingWaveform: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                bar(height: Self.barHeight(for: level))
            }
        }
    }

    /// One loudness value shaping every bar, tallest in the middle.
    ///
    /// The envelope is what stops this reading as a solid block: without it all
    /// the bars are the same height and the meter is a rectangle that changes
    /// size.
    private var pulseBars: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let breath = Self.breath(at: timeline.date)
            HStack(alignment: .center, spacing: Self.barSpacing) {
                ForEach(0..<Self.pulseBarCount, id: \.self) { index in
                    let envelope = Self.centreWeight(index, of: Self.pulseBarCount)
                    // A slow breath so the shape is alive at rest too. It is
                    // scaled by the level, so silence is still flat — the
                    // motion never invents loudness that was not measured.
                    let value = Double(model.level) * envelope * breath
                    bar(height: Self.barHeight(for: Float(value)))
                }
            }
        }
    }

    /// Real frequency bands, low on the left.
    private var spectrumBars: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(Array(model.bands.enumerated()), id: \.offset) { _, magnitude in
                bar(height: Self.barHeight(for: magnitude), width: Self.wideBarWidth)
            }
        }
    }

    /// Loudness again, with each bar drifting on its own phase.
    ///
    /// The drift is decoration, and it is the only decoration here: the height
    /// is still the measured level, so the meter cannot show movement when
    /// nobody is speaking — it can only show that movement differently.
    private var bouncingBars: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: Self.barSpacing) {
                ForEach(0..<Self.pulseBarCount, id: \.self) { index in
                    let phase = Double(index) * 0.7
                    let speed = 6.0 + Double(index % 4) * 1.7
                    // 0.55...1.0, so a bar is never fully still while there is
                    // sound, and never taller than the level allows.
                    let drift = 0.775 + 0.225 * sin(time * speed + phase)
                    let envelope = 0.55 + 0.45 * Self.centreWeight(index, of: Self.pulseBarCount)
                    let value = Double(model.level) * drift * envelope
                    bar(height: Self.barHeight(for: Float(value)))
                }
            }
        }
    }

    private var siriWave: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            SiriWave(
                amplitude: Double(model.level),
                time: timeline.date.timeIntervalSinceReferenceDate,
                height: Self.meterHeight
            )
        }
    }

    private func bar(height: CGFloat, width: CGFloat = OverlayView.barWidth) -> some View {
        Capsule(style: .continuous)
            // Quiet bars sit well back, so a spoken syllable stands out against
            // the room instead of being a slightly brighter shade of the same
            // red.
            .fill(Color.red.opacity(0.18 + Double(height / Self.meterHeight) * 0.82))
            .frame(width: width, height: height)
    }

    /// Bars for the styles that draw a shape rather than a history. Fewer and
    /// wider than the waveform's, because they are read as one figure.
    private static let pulseBarCount = 16
    private static let wideBarWidth: CGFloat = 5

    /// A visible floor, so silence still reads as "running".
    private static func barHeight(for level: Float) -> CGFloat {
        3 + CGFloat(max(0, min(1, level))) * (meterHeight - 3)
    }

    /// 1 at the centre, tapering to about 0.25 at the ends.
    private static func centreWeight(_ index: Int, of count: Int) -> Double {
        guard count > 1 else { return 1 }
        let position = Double(index) / Double(count - 1) * 2 - 1
        return 1 - 0.75 * position * position
    }

    /// A slow rise and fall, so a held note is not a frozen shape.
    private static func breath(at date: Date) -> Double {
        0.86 + 0.14 * sin(date.timeIntervalSinceReferenceDate * 3.1)
    }

    private var indicatorColor: Color {
        switch model.state {
        case .listening: .red
        case .transcribing: .orange
        case .cleaning: .blue
        case .copiedToClipboard: .yellow
        case .scratched: .green
        case .nothingToScratch: .gray
        case .error: .gray
        }
    }

    private var label: String {
        switch model.state {
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .cleaning: "Cleaning up…"
        case .copiedToClipboard: "No text field focused — copied to clipboard"
        case .scratched: "Scratched"
        case .nothingToScratch: "Nothing to scratch"
        case .error(let message): message
        }
    }
}
