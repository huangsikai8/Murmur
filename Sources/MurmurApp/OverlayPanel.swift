import AppKit
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
        model.isActive = true
        reposition()
        panel.orderFrontRegardless()
    }

    /// Appends one input-level sample, scrolling the meter leftward.
    func pushLevel(_ value: Float) {
        guard model.showsMeter else { return }
        var levels = model.levels
        levels.removeFirst()
        levels.append(max(0, min(1, value)))
        model.levels = levels
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

@MainActor
final class OverlayModel: ObservableObject {
    enum State: Equatable {
        case listening
        case transcribing
        case cleaning
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

    private var meter: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(0.35 + Double(level) * 0.65))
                    // A visible floor, so silence still reads as "running".
                    .frame(width: 3, height: 3 + CGFloat(level) * 19)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.05), value: model.levels)
    }

    private var indicatorColor: Color {
        switch model.state {
        case .listening: .red
        case .transcribing: .orange
        case .cleaning: .blue
        case .error: .gray
        }
    }

    private var label: String {
        switch model.state {
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .cleaning: "Cleaning up…"
        case .error(let message): message
        }
    }
}
