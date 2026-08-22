#!/usr/bin/env swift
//
//  make_dmg_background.swift — draws the disk image window's background.
//
//  Usage:  swift Scripts/make_dmg_background.swift [outdir]
//
//  Writes two PNGs into outdir, which defaults to Resources/:
//
//      dmg-background.png       640 x 440 pixels
//      dmg-background@2x.png   1280 x 880 pixels
//
//  Both PNGs are committed, exactly as Resources/AppIcon.icns is. This script
//  regenerates them when the copy or the layout changes; Scripts/make_dmg.sh
//  reads the committed files straight off disk and never compiles Swift, so
//  cutting a release cannot be blocked on a Swift build.
//
//  Why the window says what it says: the daily update check downloads a
//  release disk image and opens it while MemoryClip is still running, and
//  macOS will not replace a running application. The window has to say so
//  before the drag rather than after it fails.
//
//  Colour: Finder does not swap a disk image's background picture between the
//  light and dark appearances — one image is shown under both. Every colour
//  below is therefore an explicit sRGB value, never a dynamic system colour,
//  which would resolve to whichever appearance this script happened to run in
//  and be wrong half the time. The slate is deliberately mid-tone: dark enough
//  that the black item labels Finder draws in the light appearance stay
//  legible against it, light enough that the white ones it draws in the dark
//  appearance do too.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outDir: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
    return repoRoot.appendingPathComponent("Resources", isDirectory: true)
}()

// MARK: - Layout

// Finder's icon view puts (0, 0) at the top-left corner of the window's
// content area and counts y downwards, and it pins the background picture to
// that same corner. Every number here is therefore in the coordinate space
// Scripts/make_dmg.sh hands to Finder, so the art and the icon positions
// cannot drift apart — change one and change the other.

let canvasWidth: CGFloat = 640
let canvasHeight: CGFloat = 440

/// What can be counted on being *visible*.
///
/// The `bounds` Finder takes for a window include its title bar, and how tall
/// that is is Finder's business, not ours — 32pt on macOS 26, historically 28.
/// make_dmg.sh asks for the smaller allowance so the art always covers the
/// whole content area rather than leaving a bare strip under it, which means
/// the bottom of this canvas is a band that may or may not be on screen.
/// Nothing is drawn in it, and no icon is positioned into it.
let safeHeight: CGFloat = 400

/// Centre line of both icon slots, and of the arrow between them.
let slotRow: CGFloat = 250
let appSlot = CGPoint(x: 170, y: slotRow)
let applicationsSlot = CGPoint(x: 470, y: slotRow)
/// The `icon size` make_dmg.sh sets on the view. The slots are left empty:
/// Finder draws the real icons on top of this image.
let slotSide: CGFloat = 112

/// The gap between the two slots, which is all the room the arrow and its
/// caption have.
let gap = CGRect(
    x: appSlot.x + slotSide / 2,
    y: slotRow - slotSide / 2,
    width: applicationsSlot.x - appSlot.x - slotSide,
    height: slotSide
)

// MARK: - Palette

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let slateTop = srgb(0x8E94AE)     // relative luminance 0.29 — white labels clear 3:1
let slateBottom = srgb(0x7A8099)  // relative luminance 0.21 — black labels clear 4:1
let ink = srgb(0x161A2E)          // 5.5:1 on the top of the gradient
let inkSoft = srgb(0x272D48)
let pillFill = srgb(0x1B2038)
let pillText = srgb(0xF4F6FB)

// MARK: - Copy
//
// The wording is the point of this image. "Quit MemoryClip" is the literal
// title of the menu item in StatusController, so the sentence names the thing
// the user has to click.

let heading = "Installing MemoryClip"
let warning = "Quit MemoryClip before you drag."
let explanation = """
Click the clipboard glyph in the menu bar and choose Quit MemoryClip.
macOS will not replace an app while it is running.
"""
let caption = "Then drag it onto Applications."

// MARK: - Text

func centred(lineSpacing: CGFloat = 0) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineSpacing = lineSpacing
    return style
}

/// Draws `text` centred in `rect`, top-aligned, and reports the size it
/// actually took so the caller can check it against the room it left.
@discardableResult
func draw(
    _ text: String,
    font: NSFont,
    colour: NSColor,
    in rect: CGRect,
    lineSpacing: CGFloat = 0
) -> CGSize {
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: colour,
        .paragraphStyle: centred(lineSpacing: lineSpacing),
        .kern: 0.1
    ])
    let bounds = attributed.boundingRect(
        with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
}

// MARK: - The drawing

func drawBackground() {
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    // Ground: a slate gradient, lighter under the heading than under the
    // slots so the copy sits on the more contrasty half.
    let colours = [slateTop.cgColor, slateBottom.cgColor] as CFArray
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: canvasHeight),
            options: []
        )
    }

    // Heading.
    let headingSize = draw(
        heading,
        font: .systemFont(ofSize: 27, weight: .semibold),
        colour: ink,
        in: CGRect(x: 60, y: 26, width: canvasWidth - 120, height: 40)
    )
    report("heading", headingSize, room: canvasWidth - 120)

    // The instruction that matters, on a dark pill so it reads before the
    // paragraph under it does.
    let warningFont = NSFont.systemFont(ofSize: 20, weight: .bold)
    let warningWidth = (warning as NSString).size(withAttributes: [.font: warningFont]).width
    let pill = CGRect(
        x: ((canvasWidth - (warningWidth + 52)) / 2).rounded(),
        y: 72,
        width: (warningWidth + 52).rounded(),
        height: 44
    )
    pillFill.setFill()
    NSBezierPath(roundedRect: pill, xRadius: 22, yRadius: 22).fill()
    draw(
        warning,
        font: warningFont,
        colour: pillText,
        in: pill.insetBy(dx: 20, dy: 0).offsetBy(dx: 0, dy: 11)
    )
    report("warning pill", pill.size, room: canvasWidth - 120)

    // How to quit, and why it is being asked for.
    let explanationSize = draw(
        explanation,
        font: .systemFont(ofSize: 13, weight: .regular),
        colour: inkSoft,
        in: CGRect(x: 80, y: 130, width: canvasWidth - 160, height: 48),
        lineSpacing: 3
    )
    report("explanation", explanationSize, room: canvasWidth - 160)

    // The arrow, on the slot centre line, pointing at Applications.
    drawArrow()

    let captionTop: CGFloat = 274
    let captionSize = draw(
        caption,
        font: .systemFont(ofSize: 11, weight: .semibold),
        colour: inkSoft,
        in: CGRect(x: gap.minX, y: captionTop, width: gap.width, height: 22)
    )
    report("caption", captionSize, room: gap.width)

    let lowest = captionTop + captionSize.height
    let verdict = lowest <= safeHeight ? "inside" : "BELOW THE FOLD"
    print("    lowest ink at y=\(Int(lowest)), safe band ends at \(Int(safeHeight)) — \(verdict)")
}

func drawArrow() {
    let tipX = applicationsSlot.x - slotSide / 2 - 16
    let tailX = appSlot.x + slotSide / 2 + 18
    let headWidth: CGFloat = 30
    let headHeight: CGFloat = 30

    inkSoft.setFill()
    inkSoft.setStroke()

    let shaft = NSBezierPath(
        roundedRect: CGRect(
            x: tailX,
            y: slotRow - 5,
            width: tipX - headWidth - tailX + 8,
            height: 10
        ),
        xRadius: 5,
        yRadius: 5
    )
    shaft.fill()

    // Stroked as well as filled, with a round join, so the point of the head
    // is softened rather than needle-sharp.
    let head = NSBezierPath()
    head.move(to: CGPoint(x: tipX - 4, y: slotRow))
    head.line(to: CGPoint(x: tipX - headWidth, y: slotRow - headHeight / 2 + 3))
    head.line(to: CGPoint(x: tipX - headWidth, y: slotRow + headHeight / 2 - 3))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 7
    head.fill()
    head.stroke()
}

func report(_ label: String, _ size: CGSize, room: CGFloat) {
    let verdict = size.width <= room ? "fits" : "TOO WIDE"
    let padded = label.padding(toLength: 14, withPad: " ", startingAt: 0)
    print(String(format: "    %@ %6.1f x %5.1f  (room %.0f) %@",
                 padded, size.width, size.height, room, verdict))
}

// MARK: - Rendering

/// Renders the canvas at `scale`, in points throughout: the context is set up
/// with the origin at the top-left and y counting downwards, so the drawing
/// code speaks Finder's coordinate space at both 1x and 2x.
func render(scale: CGFloat) -> Data? {
    let pixelsWide = Int(canvasWidth * scale)
    let pixelsHigh = Int(canvasHeight * scale)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: pixelsWide,
              height: pixelsHigh,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }

    context.translateBy(x: 0, y: CGFloat(pixelsHigh))
    context.scaleBy(x: scale, y: -scale)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    drawBackground()
    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    // The point size stays 640x440 at both scales, which is what makes the 2x
    // file a genuine @2x asset rather than a larger picture.
    rep.size = CGSize(width: canvasWidth, height: canvasHeight)
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Write

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (name, scale) in [("dmg-background.png", CGFloat(1)), ("dmg-background@2x.png", CGFloat(2))] {
    print("==> \(name)  \(Int(canvasWidth * scale)) x \(Int(canvasHeight * scale)) pixels")
    guard let data = render(scale: scale) else {
        FileHandle.standardError.write(Data("error: could not render \(name)\n".utf8))
        exit(1)
    }
    let url = outDir.appendingPathComponent(name)
    do {
        try data.write(to: url)
    } catch {
        FileHandle.standardError.write(Data("error: could not write \(url.path): \(error)\n".utf8))
        exit(1)
    }
}

print("OK: wrote dmg-background.png and dmg-background@2x.png to \(outDir.path)")
