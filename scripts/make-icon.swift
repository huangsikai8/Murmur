#!/usr/bin/env swift
//
// Renders Murmur's app icon into `Resources/`.
//
//     swift scripts/make-icon.swift
//
// The mark is five bars whose tops trace an M — two full-height stems with a
// valley between them — which is also the envelope of a waveform. It is drawn
// rather than committed as pixels so the proportions stay editable, and because
// the small sizes need different numbers from the large ones: at 16pt a bar is
// about a pixel wide, so widths and gaps are snapped to whole pixels below
// 128pt or the whole mark turns to grey mush.
//
// Only the products are committed (`Resources/Murmur.icns` and the README
// image); the build does not run this, so nothing in a normal build depends on
// having a working Swift toolchain for scripts.

import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Proportions

/// Apple's icon grid: the shape occupies 824 of 1024 points, centred, and the
/// system adds the shadow. Baking one in would double it.
let shapeFraction: CGFloat = 824.0 / 1024.0

/// Bar heights as a fraction of the tallest. Anchored on a common baseline the
/// tops read as an M; centred on the midline they would read as a bar chart.
///
/// Sampling a real M at five evenly spaced columns gives roughly
/// `[1, 0.5, 0.15, 0.5, 1]`, and that is worse: the middle bar collapses to a
/// dot and the eye stops connecting the tops into a contour, so it reads as a
/// bar chart. A shallower valley is less accurate and much more legible.
let barHeights: [CGFloat] = [1.0, 0.70, 0.40, 0.70, 1.0]

let barWidthFraction: CGFloat = 0.108   // of the shape's side
let barGapFraction: CGFloat = 0.045
let barMaxHeightFraction: CGFloat = 0.58

/// Below this size the mark is drawn on the pixel grid instead of the point
/// grid. Antialiasing a 1.3px bar spreads it over two columns at half strength.
let snapBelow: CGFloat = 129

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// An indigo base running corner to corner, with a warm and a cool light source
// bleeding in from opposite corners. Two things date an icon background, and
// both are avoided here: a gradient running straight down the vertical axis,
// and a hard highlight band across the top. The light is off-axis instead, and
// the colour has somewhere to travel between the corners.
let baseStart = rgb(88, 86, 240)
let baseEnd = rgb(58, 40, 170)
let warmLight = rgb(236, 120, 255)
let coolLight = rgb(60, 200, 255)

// MARK: - Drawing

/// Apple's icon outline is a superellipse, not a rounded rectangle: the corner
/// blends into the side instead of meeting it at a tangent point. `n = 5` is
/// the exponent that matches the system shape closely enough to sit next to it.
func superellipse(in rect: CGRect, exponent n: CGFloat = 5, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let e = 2 / n
    for i in 0...steps {
        let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
        let c = cos(t), s = sin(t)
        let point = CGPoint(
            x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), e),
            y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), e)
        )
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: CGFloat) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create a \(Int(size))pt context") }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let side = (size * shapeFraction).rounded()
    let shape = CGRect(
        x: ((size - side) / 2).rounded(),
        y: ((size - side) / 2).rounded(),
        width: side, height: side
    )
    let outline = superellipse(in: shape)

    // Background.
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    let base = CGGradient(
        colorsSpace: space, colors: [baseStart, baseEnd] as CFArray, locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        base,
        start: CGPoint(x: shape.minX, y: shape.maxY),
        end: CGPoint(x: shape.maxX, y: shape.minY),
        options: []
    )

    /// A colour source that fades to nothing, so it blends into the base
    /// instead of sitting on top of it as a band would.
    func bleed(_ color: CGColor, at point: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let g = CGGradient(
            colorsSpace: space,
            colors: [
                color.copy(alpha: alpha)!,
                color.copy(alpha: 0)!,
            ] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawRadialGradient(
            g, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius, options: []
        )
    }
    bleed(warmLight, at: CGPoint(x: shape.maxX - side * 0.10, y: shape.maxY - side * 0.05),
          radius: side * 0.85, alpha: 0.75)
    bleed(coolLight, at: CGPoint(x: shape.minX + side * 0.05, y: shape.minY + side * 0.12),
          radius: side * 0.80, alpha: 0.55)
    ctx.restoreGState()

    // MARK: bars
    let snap = size < snapBelow
    var barW = side * barWidthFraction
    var gap = side * barGapFraction
    var maxH = side * barMaxHeightFraction
    if snap {
        barW = max(1, barW.rounded())
        gap = max(1, gap.rounded())
        maxH = max(2, maxH.rounded())
    }

    func width(bar: CGFloat, gap: CGFloat) -> CGFloat {
        bar * CGFloat(barHeights.count) + gap * CGFloat(barHeights.count - 1)
    }
    // Rounding up at 16pt can push the row past the shape's edge. Losing a
    // pixel from each bar is the cheaper failure.
    while snap, barW > 1, width(bar: barW, gap: gap) > side {
        barW -= 1
    }

    let totalW = width(bar: barW, gap: gap)
    var x = shape.midX - totalW / 2
    var baseline = shape.midY - maxH / 2
    if snap {
        x = x.rounded()
        baseline = baseline.rounded()
    }

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    for fraction in barHeights {
        var h = maxH * fraction
        if snap { h = max(barW, h.rounded()) }
        let bar = CGRect(x: x, y: baseline, width: barW, height: h)
        // A pill cap, except where the bar is too short to take one.
        let radius = min(barW / 2, h / 2)
        ctx.addPath(CGPath(
            roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil
        ))
        ctx.fillPath()
        x += barW + gap
    }

    guard let image = ctx.makeImage() else { fatalError("could not render \(Int(size))pt") }
    return image
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("could not open \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try! process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write(
            "error: \(tool) \(arguments.joined(separator: " ")) failed\n".data(using: .utf8)!
        )
        exit(1)
    }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // repo root
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("Murmur.iconset")

let fm = FileManager.default
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// The ten slots `iconutil` expects. 16 and 32 each appear twice, at different
// scales, and are rendered once per pixel size rather than once per slot.
let slots: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

var rendered: [CGFloat: CGImage] = [:]
for slot in slots {
    let image = rendered[slot.pixels] ?? drawIcon(size: slot.pixels)
    rendered[slot.pixels] = image
    write(image, to: iconset.appendingPathComponent(slot.name))
    print("    \(slot.name)  \(Int(slot.pixels))px")
}

let icns = resources.appendingPathComponent("Murmur.icns")
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
try? fm.removeItem(at: iconset)
print("==> \(icns.path)")

// A separate render for the README, which wants a plain image and not an icns.
let logo = resources.appendingPathComponent("murmur-logo.png")
write(rendered[512]!, to: logo)
print("==> \(logo.path)")
