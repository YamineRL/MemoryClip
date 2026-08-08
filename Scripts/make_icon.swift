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
//  Design: full-bleed rounded square (macOS 26 convention, no baked-in drop
//  shadow, no inner padding) with a white clipboard mark backed by two
//  offset "stacked clip" cards.
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

/// Reference canvas. Every coordinate below is expressed in this space and
/// scaled to the size actually being rendered.
let canvas: CGFloat = 1024

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Drawing

func drawIcon(into ctx: CGContext, size: CGFloat) {
    let s = size / canvas
    func p(_ v: CGFloat) -> CGFloat { v * s }
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: p(x), y: p(y), width: p(w), height: p(h))
    }

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [red, green, blue, alpha])!
    }

    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // --- Background: full-bleed rounded square with a diagonal gradient. ---
    // 0.2237 is the standard macOS/iOS app-icon corner ratio.
    let bgPath = rounded(CGRect(x: 0, y: 0, width: size, height: size), size * 0.2237)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let top = color(0.325, 0.451, 0.980)     // #536CFA
    let bottom = color(0.153, 0.208, 0.706)  // #2735B4
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [top, bottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // --- Stacked "clips" behind the board. ---
    // Drawn first, then covered by the opaque board, so only a sliver shows.
    let board = r(206, 168, 470, 588)
    let cardRadius = p(64)

    ctx.setFillColor(color(1, 1, 1, 0.36))
    ctx.addPath(rounded(board.offsetBy(dx: p(104), dy: p(94)), cardRadius))
    ctx.fillPath()

    ctx.setFillColor(color(1, 1, 1, 0.64))
    ctx.addPath(rounded(board.offsetBy(dx: p(54), dy: p(48)), cardRadius))
    ctx.fillPath()

    // --- The board itself. ---
    ctx.setFillColor(color(1, 1, 1, 1))
    ctx.addPath(rounded(board, cardRadius))
    ctx.fillPath()

    // --- Clip slot: a solid well at the top of the board. Solid (rather than
    //     gradient-filled) so the contrast holds at 16pt. ---
    let ink = color(0.129, 0.176, 0.635)
    ctx.setFillColor(ink)
    ctx.addPath(rounded(r(316, 612, 250, 136), p(58)))
    ctx.fillPath()

    // --- Clip head: white tab straddling the top edge of the board. ---
    ctx.setFillColor(color(1, 1, 1, 1))
    ctx.addPath(rounded(r(374, 650, 134, 164), p(46)))
    ctx.fillPath()

    // --- Content lines. Two thick, well-separated bars: a third line turns
    //     to mud once the icon is rendered at 16pt. ---
    ctx.setFillColor(ink)
    for y in [432 as CGFloat, 292] {
        ctx.addPath(rounded(r(280, y, 322, 74), p(37)))
    }
    ctx.fillPath()
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
