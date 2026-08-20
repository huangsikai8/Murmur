import AppKit

/// The menu bar mark: the same five bars as the app icon, drawn as a template
/// image so AppKit tints it for the menu bar's appearance and for the
/// highlighted state.
///
/// It is drawn rather than shipped as a PNG because the status bar is not one
/// fixed size — it changes with the menu bar's height and with the display's
/// scale — and because a template image the build has to copy is one more thing
/// that can go missing from the bundle without the app noticing.
///
/// The proportions here are the icon's, re-derived at menu bar size rather than
/// scaled down from it: at 18pt a bar is under 2pt wide, so the icon's
/// fractions-of-the-side arithmetic would land the bars off the pixel grid.
/// If `barHeights` changes in `scripts/make-icon.swift`, change it here too.
enum MenuBarGlyph {
    /// Tops trace an M; also the envelope of a waveform.
    private static let barHeights: [CGFloat] = [1.0, 0.70, 0.40, 0.70, 1.0]

    private static let barWidth: CGFloat = 1.8
    private static let barGap: CGFloat = 1.2
    private static let maxBarHeight: CGFloat = 11

    /// Padding between the bars and the edge of the filled container.
    private static let containerInset: CGFloat = 2.5

    /// One canvas for every state, so the status item does not change width
    /// when the state does — a jumping menu bar item reads as a glitch.
    private static let canvas = NSSize(width: 19, height: 18)

    private static var markWidth: CGFloat {
        barWidth * CGFloat(barHeights.count) + barGap * CGFloat(barHeights.count - 1)
    }

    /// - Parameters:
    ///   - active: the microphone is actually open. Drawn as a filled container
    ///     with the bars knocked out of it, which is the same relationship SF
    ///     Symbols uses between `mic` and `mic.fill`.
    ///   - slashed: the app cannot dictate.
    static func mark(
        active: Bool = false,
        slashed: Bool = false,
        accessibilityDescription: String
    ) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }

            let bars = CGRect(
                x: (canvas.width - markWidth) / 2,
                y: (canvas.height - maxBarHeight) / 2,
                width: markWidth,
                height: maxBarHeight
            )

            let barPath = CGMutablePath()
            var x = bars.minX
            for fraction in barHeights {
                let height = maxBarHeight * fraction
                let bar = CGRect(x: x, y: bars.minY, width: barWidth, height: height)
                let radius = min(barWidth / 2, height / 2)
                barPath.addPath(CGPath(
                    roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil
                ))
                x += barWidth + barGap
            }

            ctx.setFillColor(NSColor.black.cgColor)
            if active {
                // Fill the container, then clear the bars out of it. Even-odd
                // on a single path would be simpler but the bar shapes are
                // separate subpaths, and even-odd would cancel where two of
                // them overlap — which they do not today and might tomorrow.
                let container = bars.insetBy(dx: -containerInset, dy: -containerInset)
                ctx.addPath(CGPath(
                    roundedRect: container, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil
                ))
                ctx.fillPath()
                ctx.setBlendMode(.clear)
                ctx.addPath(barPath)
                ctx.fillPath()
                ctx.setBlendMode(.normal)
            } else {
                ctx.addPath(barPath)
                ctx.fillPath()
            }

            if slashed {
                // Short and steep, crossing only the middle of the mark. A
                // slash spanning the full width fragments all five bars at
                // once and the whole glyph reads as broken rather than
                // disabled — the mark is thin strokes, not one solid shape
                // like the SF Symbol this borrows from.
                let start = CGPoint(x: bars.midX - 4, y: bars.minY - 1)
                let end = CGPoint(x: bars.midX + 4, y: bars.maxY + 1)
                // A gap around the slash keeps it legible where it crosses a
                // bar. It has to stay under a bar's width, or clearing it
                // removes more of the mark than the slash adds.
                ctx.setLineCap(.round)
                ctx.setBlendMode(.clear)
                ctx.setLineWidth(barWidth * 1.4)
                ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
                ctx.setBlendMode(.normal)
                ctx.setLineWidth(barWidth * 0.85)
                ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
            }

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
