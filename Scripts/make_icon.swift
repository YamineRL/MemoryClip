#!/usr/bin/env swift
//
//  make_icon.swift — generates Resources/AppIcon.icns for MemoryClip.
//
//  Usage:  swift Scripts/make_icon.swift
//
//  The icon is drawn programmatically with Core Graphics (no network, no
//  checked-in binary source art) and rendered natively at every size the
//  iconset needs, so the 16pt rendering is a real 16pt draw rather than a
//  downsample of the 1024pt one.
//
//  Design: logo direction 1a, "The Stack". A full-bleed indigo rounded square
//  (macOS 26 convention — no baked-in drop shadow, no inner padding) carrying
//  three white cards that march up and to the right, with a small clip tab
//  straddling the top edge of the front card. The stack is the *history*; the
//  tab is what makes it a *clipboard*.
//
//  Every number below is lifted from the design file: a 180x180 tile and a
//  104x104 mark viewBox. Both systems are named in the constants so the
//  drawing can be checked against the design without re-deriving anything.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = repoRoot.appendingPathComponent(".build/icon/AppIcon.iconset")
let icnsURL = repoRoot.appendingPathComponent("Resources/AppIcon.icns")

// MARK: - Geometry helpers

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - The tile

/// The design's tile is 180x180 with a 40px radius — a ratio of 40/180 =
/// 0.2222, which is within a hair of the 0.2237 macOS/iOS app-icon ratio this
/// script already used. Keep 0.2237: it is the platform's own squircle
/// proportion, the two differ by 0.15px at 1024px, and looking native next to
/// Finder and Safari matters more than matching a CSS value that was itself
/// rounded to a whole pixel. (The design's small tiles quote 14/64 and 7/32 =
/// 0.219 and 4.5/18 = 0.25 for the same reason — CSS pushing 0.2222 to whole
/// pixels — so they collapse into this one ratio too.)
let cornerRatio: CGFloat = 0.2237

/// `linear-gradient(170deg, #6d7cf6 0%, #4a54d8 55%, #3a3fb8 100%)`.
let indigoLight: (CGFloat, CGFloat, CGFloat) = (109 / 255, 124 / 255, 246 / 255)  // #6d7cf6
let indigoMid: (CGFloat, CGFloat, CGFloat) = (74 / 255, 84 / 255, 216 / 255)      // #4a54d8
let indigoDark: (CGFloat, CGFloat, CGFloat) = (58 / 255, 63 / 255, 184 / 255)     // #3a3fb8

/// CSS gradient angle, in degrees clockwise from "to top". 170deg runs almost
/// straight down, leaning 10 degrees to the right — the same diagonal the card
/// stack climbs, in reverse.
let gradientAngle: CGFloat = 170

/// The design's inner top highlight, `inset 0 1.5px 0 rgba(255,255,255,0.35)`
/// on the 180px tile. Expressed as a fraction of the tile so it stays a
/// hairline at 1024px instead of becoming a stripe.
let highlightRatio: CGFloat = 1.5 / 180
let highlightAlpha: CGFloat = 0.35

// MARK: - The mark

/// The mark has its own 104x104 viewBox and is placed at 108/180 = 60% of the
/// tile width, centred. Every card coordinate below is in viewBox units, with
/// the design's y axis (growing *downward*); `rect(_:)` does the flip.
let markViewBox: CGFloat = 104
let markInset: CGFloat = 0.6

/// One rounded rect of the mark, straight out of the design file.
struct MarkRect {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat
    /// Corner radius, viewBox units.
    let r: CGFloat
    let rgb: (CGFloat, CGFloat, CGFloat)
    /// The design's `opacity` on the card. The stack fades back into the
    /// gradient rather than being drawn in a lighter blue, so the same numbers
    /// hold whatever the background does.
    let alpha: CGFloat
}

let cardWhite: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)
/// #dfe4ff — the tab is a shade cooler than the card it sits on, so it still
/// reads as a separate part over the white and not just a bump in the outline.
let tabTint: (CGFloat, CGFloat, CGFloat) = (223 / 255, 228 / 255, 255 / 255)

/// The full-detail mark: three 56x56 cards, each offset +9 x and -10 y from
/// the one behind it, so the stack marches up and to the right. The tab is
/// centred on the front card (52..72 against a card spanning 34..90) and
/// straddles its top edge — 7 units above, 6 below.
let fullMark: [MarkRect] = [
    MarkRect(x: 16, y: 34, w: 56, h: 56, r: 15, rgb: cardWhite, alpha: 0.25),
    MarkRect(x: 25, y: 24, w: 56, h: 56, r: 15, rgb: cardWhite, alpha: 0.50),
    MarkRect(x: 34, y: 14, w: 56, h: 56, r: 15, rgb: cardWhite, alpha: 1.00),
    MarkRect(x: 52, y: 7, w: 20, h: 13, r: 6, rgb: tabTint, alpha: 1.00),
]

/// At or below this many *pixels*, the mark drops to two cards.
///
/// Three cards are separated by 9 viewBox units, which is 9/104 of a mark that
/// is itself 60% of the tile: about 3.3px of step at 64px, 1.7px at 32px and
/// 0.9px at 16px. The threshold was picked by rendering both versions and
/// looking at them rather than by arithmetic. At 128px the three cards each
/// show a clean edge. At 64px they do not — the middle card smears into the
/// front one and the stack reads as a blurred halo, while the two-card version
/// at the same size still shows one card clearly behind another. So the cut is
/// 64 inclusive. That is also where the design put it: its "32px tile and
/// below" tier is CSS pixels, and a 32pt tile on the Retina display this app
/// actually runs on is 64 device pixels.
let twoCardCutoff = 64

/// The small mark: two 58x58 cards, +14 x / -22 y apart. Bigger cards and a
/// much bigger step than the full-detail version, because at these sizes the
/// only thing that has to read is "two layers, one in front".
func smallMark(pixels: Int) -> [MarkRect] {
    // The design's smallest tier (an 18px tile) opens the corners to rx=19 and
    // lifts the back card to 0.40 — at that size the 0.35 card disappears into
    // the gradient and square-ish corners look like grit. Our 16px tile is
    // that tier; 32px keeps the 17/0.35 values.
    let radius: CGFloat = pixels <= 16 ? 19 : 17
    let backAlpha: CGFloat = pixels <= 16 ? 0.40 : 0.35
    return [
        MarkRect(x: 18, y: 40, w: 58, h: 58, r: radius, rgb: cardWhite, alpha: backAlpha),
        MarkRect(x: 32, y: 18, w: 58, h: 58, r: radius, rgb: cardWhite, alpha: 1.00),
        MarkRect(x: 50, y: 10, w: 22, h: 14, r: 7, rgb: tabTint, alpha: 1.00),
    ]
}

// MARK: - Drawing

func drawIcon(into ctx: CGContext, size: CGFloat) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ rgb: (CGFloat, CGFloat, CGFloat), _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [rgb.0, rgb.1, rgb.2, alpha])!
    }

    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let pixels = Int(size)
    let isSmall = pixels <= twoCardCutoff

    // --- Background: full-bleed squircle with the 170deg gradient. ---
    let radius = size * cornerRatio
    let tile = rounded(CGRect(x: 0, y: 0, width: size, height: size), radius)
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()

    // The design drops the middle stop on small tiles. It is nearly the same
    // ramp either way (two-stop interpolation lands on #515ad4 at 55%, against
    // the design's #4a54d8) but fewer stops means fewer banding artefacts in
    // the handful of pixels a 16px tile actually has.
    let stops: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = isSmall
        ? [(0, indigoLight), (1, indigoDark)]
        : [(0, indigoLight), (0.55, indigoMid), (1, indigoDark)]
    let gradient = CGGradient(
        colorsSpace: space,
        colors: stops.map { color($0.1) } as CFArray,
        locations: stops.map(\.0)
    )!

    // CSS measures gradient angles clockwise from "up", so in Core Graphics'
    // y-up space the gradient travels along (sin, cos) of the angle. The line
    // has to be long enough to cover the box's projection onto it, which for a
    // square is (|dx| + |dy|) * size.
    let theta = gradientAngle * .pi / 180
    let dir = CGPoint(x: sin(theta), y: cos(theta))
    let half = (abs(dir.x) + abs(dir.y)) * size / 2
    let mid = CGPoint(x: size / 2, y: size / 2)
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: mid.x - dir.x * half, y: mid.y - dir.y * half),
        end: CGPoint(x: mid.x + dir.x * half, y: mid.y + dir.y * half),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // --- Inner top highlight. ---
    // `inset 0 1.5px 0` is the tile shape minus the same shape shifted 1.5/180
    // of the tile downward: a hairline of light that follows the top edge and
    // dies out as the corners turn. Even-odd fills the difference; the clip to
    // `tile` (still in force) keeps it inside the squircle.
    var shift = CGAffineTransform(translationX: 0, y: -size * highlightRatio)
    let shifted = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
        cornerWidth: radius, cornerHeight: radius, transform: &shift
    )
    let band = CGMutablePath()
    band.addPath(tile)
    band.addPath(shifted)
    ctx.setFillColor(color((1, 1, 1), highlightAlpha))
    ctx.addPath(band)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // --- The mark: the 104x104 viewBox, drawn at 60% of the tile, centred. ---
    let side = size * markInset
    let origin = (size - side) / 2
    let unit = side / markViewBox
    func rect(_ m: MarkRect) -> CGRect {
        // The design's y grows downward; Core Graphics' grows upward, so a
        // card's design y becomes (104 - y - height).
        CGRect(
            x: origin + m.x * unit,
            y: origin + (markViewBox - m.y - m.h) * unit,
            width: m.w * unit,
            height: m.h * unit
        )
    }

    // Back to front, as listed: the translucent cards composite over the
    // gradient exactly as they do in the design file, and the opaque front
    // card crops the ones behind it.
    for m in isSmall ? smallMark(pixels: pixels) : fullMark {
        ctx.setFillColor(color(m.rgb, m.alpha))
        ctx.addPath(rounded(rect(m), m.r * unit))
        ctx.fillPath()
    }
}

// MARK: - Rendering

func renderPNG(size: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw Failure("could not create a \(size)x\(size) bitmap context")
    }

    drawIcon(into: ctx, size: CGFloat(size))

    guard let image = ctx.makeImage() else {
        throw Failure("could not snapshot the \(size)x\(size) bitmap")
    }
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw Failure("could not open \(url.path) for writing")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw Failure("could not write \(url.path)")
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func run(_ launchPath: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw Failure("\(launchPath) \(arguments.joined(separator: " ")) failed"
            + " with status \(process.terminationStatus)")
    }
}

// MARK: - Main

/// (point size, scale) pairs required by a complete .iconset.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

do {
    let fm = FileManager.default
    if fm.fileExists(atPath: iconsetURL.path) {
        try fm.removeItem(at: iconsetURL)
    }
    try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    try fm.createDirectory(
        at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )

    for variant in variants {
        let pixels = variant.points * variant.scale
        let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
        let name = "icon_\(variant.points)x\(variant.points)\(suffix).png"
        try renderPNG(size: pixels, to: iconsetURL.appendingPathComponent(name))
        print("  rendered \(name) (\(pixels)px)")
    }

    try run("/usr/bin/iconutil", ["-c", "icns", iconsetURL.path, "-o", icnsURL.path])

    let bytes = (try fm.attributesOfItem(atPath: icnsURL.path)[.size] as? Int) ?? 0
    print("OK: wrote \(icnsURL.path) (\(bytes) bytes)")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
