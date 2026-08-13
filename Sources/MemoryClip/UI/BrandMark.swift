import AppKit

/// The MemoryClip mark — logo direction 1a, "The Stack".
///
/// Rounded cards marching up and to the right with a clip tab straddling the
/// front card's top edge: the stack is the *history*, the tab is what makes it
/// a *clipboard*.
///
/// Every number here is in the design file's 104x104 mark viewBox, the same
/// one `Scripts/make_icon.swift` draws `Resources/AppIcon.icns` from. The two
/// copies exist because the icon generator is a standalone `swift` script and
/// cannot import this module — only the two-card mark below is shared between
/// them, so keep the two in step if the design ever moves.
enum BrandMark {
    /// The design's mark viewBox. Coordinates below use its y-down axis; the
    /// drawing code flips them.
    private static let viewBox: CGFloat = 104

    private struct Card {
        let x: CGFloat
        let y: CGFloat
        let w: CGFloat
        let h: CGFloat
        /// Corner radius, viewBox units.
        let r: CGFloat
        let alpha: CGFloat
    }

    /// Two 58x58 cards, +14 x / -22 y apart, plus the tab. This is the
    /// design's small-size simplification: at anything near menu-bar size the
    /// full three-card stack has under 2pt between layers and smears into one
    /// white blob, so the design drops the middle card and widens the step.
    private static func cards(backAlpha: CGFloat) -> [Card] {
        [
            Card(x: 18, y: 40, w: 58, h: 58, r: 16, alpha: backAlpha),
            Card(x: 32, y: 18, w: 58, h: 58, r: 16, alpha: 1),
            Card(x: 50, y: 10, w: 22, h: 14, r: 7, alpha: 1),
        ]
    }

    /// Fill `cards` into `rect`, mapping the viewBox onto it. `tint` supplies
    /// the colour; each card's own alpha is applied on top of it.
    private static func draw(_ cards: [Card], in rect: CGRect, tint: NSColor, tabTint: NSColor) {
        let unit = min(rect.width, rect.height) / viewBox
        for (index, card) in cards.enumerated() {
            // The last entry is the tab, which is a shade cooler than the card
            // it sits on so it reads as a separate part rather than a bump in
            // the outline. In a template image both collapse to the same
            // alpha, which is why the tab still clears the card's top edge.
            let colour = index == cards.count - 1 ? tabTint : tint
            colour.withAlphaComponent(card.alpha).setFill()
            let frame = CGRect(
                x: rect.minX + card.x * unit,
                // The design's y grows downward, AppKit's grows upward.
                y: rect.minY + (viewBox - card.y - card.h) * unit,
                width: card.w * unit,
                height: card.h * unit
            )
            NSBezierPath(roundedRect: frame, xRadius: card.r * unit, yRadius: card.r * unit).fill()
        }
    }

    /// The monochrome menu-bar mark, as a template image.
    ///
    /// 17pt is the design's own menu-bar size, and the mark runs nearly the
    /// full viewBox (x 18..90, y 10..98) rather than being inset the way it is
    /// inside an icon tile — there is no tile in the menu bar, so the inset
    /// would only make it small.
    ///
    /// Template images carry alpha only: AppKit paints them black on a light
    /// menu bar and white on a dark one, and the back card's 0.4 comes through
    /// as 40% of whichever that is. The design's `#1d1d21` is therefore not
    /// named here — it *is* the template black.
    static func menuBarImage(pointSize: CGFloat = 17) -> NSImage {
        let image = NSImage(
            size: CGSize(width: pointSize, height: pointSize), flipped: false
        ) { rect in
            // 0.4, not the tile variant's 0.35: at menu-bar size a 0.35 card
            // over the desktop wallpaper is barely there.
            draw(cards(backAlpha: 0.4), in: rect, tint: .black, tabTint: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MemoryClip"
        return image
    }

    /// The app mark on its indigo tile, for in-app chrome that wants the logo
    /// rather than an SF Symbol.
    ///
    /// This is the design's own small-tile treatment: the two-card mark at
    /// 62.5% of the tile (its 40px header tile carries a 25px mark), the
    /// two-stop gradient the design uses below 180px, and the platform
    /// squircle ratio.
    static func tileImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(
            size: CGSize(width: pointSize, height: pointSize), flipped: false
        ) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let tile = NSBezierPath(
                roundedRect: rect,
                xRadius: rect.width * 0.2237,
                yRadius: rect.width * 0.2237
            )
            ctx.saveGState()
            tile.addClip()
            // `linear-gradient(170deg, #6d7cf6, #3a3fb8)` — almost straight
            // down, leaning 10 degrees, running against the way the cards
            // climb. NSGradient measures its angle counter-clockwise from
            // "to the right", where CSS measures clockwise from "up", so
            // 170deg CSS is -80deg here.
            let gradient = NSGradient(
                starting: NSColor(srgbRed: 109 / 255, green: 124 / 255, blue: 246 / 255, alpha: 1),
                ending: NSColor(srgbRed: 58 / 255, green: 63 / 255, blue: 184 / 255, alpha: 1)
            )
            gradient?.draw(in: rect, angle: -80)
            ctx.restoreGState()

            let inset = rect.width * 0.625
            let mark = CGRect(
                x: rect.midX - inset / 2,
                y: rect.midY - inset / 2,
                width: inset,
                height: inset
            )
            draw(
                cards(backAlpha: 0.35),
                in: mark,
                tint: .white,
                // #dfe4ff
                tabTint: NSColor(srgbRed: 223 / 255, green: 228 / 255, blue: 255 / 255, alpha: 1)
            )
            return true
        }
        image.accessibilityDescription = "MemoryClip"
        return image
    }
}
