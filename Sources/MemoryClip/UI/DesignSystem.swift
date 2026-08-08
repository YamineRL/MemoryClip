import SwiftUI
import AppKit

/// The single source of truth for MemoryClip's visual language.
///
/// Every spacing, radius, size, duration, font and colour used by the panel,
/// the rows, the preview, settings and onboarding is named here rather than
/// spelled out at the use site. Two reasons:
///
/// 1. Consistency. Before this existed the same idea was written six ways —
///    `padding(6)`, `padding(8)`, `padding(12)`, `cornerRadius: 4/6/10` — and
///    the panel read as an accumulation of one-off decisions rather than a
///    designed surface.
/// 2. Accessibility. Contrast, hover and selection treatment are decided in
///    one place, so raising the bar raises it everywhere at once instead of
///    leaving one view behind.
///
/// Colours are deliberately *semantic* (`Color(nsColor:)` system colours,
/// hierarchical styles, materials) rather than literal RGB. That is what makes
/// the app look native in Light and Dark Mode, follow the user's accent colour,
/// and react to Increase Contrast without a per-scheme code path.
enum Design {

    // MARK: - Spacing

    /// A 2/4-point spacing scale. Nothing in the UI should use a raw literal:
    /// if a gap is not on this scale it is almost always a mistake.
    enum Space {
        /// 2 — glyph-to-glyph, baseline nudges.
        static let hair: CGFloat = 2
        /// 4 — inside a compound label.
        static let tight: CGFloat = 4
        /// 6 — between rows of a list, chip internals.
        static let snug: CGFloat = 6
        /// 8 — the default gap between related controls.
        static let normal: CGFloat = 8
        /// 12 — between groups inside a section.
        static let roomy: CGFloat = 12
        /// 16 — section padding.
        static let loose: CGFloat = 16
        /// 20 — window-edge padding.
        static let wide: CGFloat = 20
        /// 24 — major vertical rhythm.
        static let vast: CGFloat = 24
    }

    // MARK: - Radii

    /// Corner radii, concentric from the inside out: a 6-point thumbnail
    /// inside a 10-point row inside a 16-point pane never looks squeezed.
    enum Radius {
        /// 28 — the floating panel itself. The single largest radius in the
        /// app: the panel is a slab hovering over the desktop, not a window.
        static let panel: CGFloat = 28
        /// 16 — a clip card. Concentric inside the 28-point panel.
        static let card: CGFloat = 16
        /// 4 — keycaps and other very small chips.
        static let tiny: CGFloat = 4
        /// 6 — thumbnails, colour swatches.
        static let small: CGFloat = 6
        /// 8 — icon tiles, quick-filter chips.
        static let control: CGFloat = 8
        /// 12 — the search field.
        static let field: CGFloat = 12
        /// 16 — content panes (preview surfaces, onboarding tiles).
        static let pane: CGFloat = 16
    }

    // MARK: - Sizes

    enum Size {
        /// The floating panel: a wide, bottom-anchored deck of cards rather
        /// than a menu-bar dropdown.
        ///
        /// `PanelController` is the only consumer — it builds its
        /// `KeyablePanel` content rect from these tokens and clamps the width
        /// to the screen — so the geometry is stated exactly once.
        static let panelWidth: CGFloat = 1080
        /// Panel height with the card strip alone:
        /// `panelTopPadding` + `topBarHeight` + `cardStripHeight` + footer.
        static let panelHeight: CGFloat = panelTopPadding
            + topBarHeight
            + cardStripHeight
            + panelFooterHeight
        /// Panel height while the preview pane is open. The panel grows
        /// *upward*: its bottom edge is anchored to the screen.
        static let panelExpandedHeight: CGFloat = panelHeight + previewPaneHeight
        /// Gap between the panel and the bottom / sides of the visible screen.
        static let panelBottomMargin: CGFloat = 28
        static let panelSideMargin: CGFloat = 24

        /// The chip/search bar across the top of the panel.
        static let topBarHeight: CGFloat = 44
        /// Breathing room above the top bar, inside the panel's rounded edge.
        static let panelTopPadding: CGFloat = 10
        /// The footer strip (source-app menu, clip count, delete-all).
        static let panelFooterHeight: CGFloat = 34
        /// The preview pane, revealed under the card strip.
        static let previewPaneHeight: CGFloat = 250
        /// Ceiling on an image clip's extracted-text block, so a screenshot
        /// full of text cannot crowd the image out of the same pane.
        static let previewExtractedTextHeight: CGFloat = 110

        /// A clip card is a SQUARE. This is both its width and its height.
        static let card: CGFloat = 200
        /// The card's header band; the content well is `card - cardHeader`.
        static let cardHeader: CGFloat = 40
        /// Gap between cards.
        static let cardSpace: CGFloat = 16
        /// Gap under the card strip, before the footer.
        static let cardBottomPadding: CGFloat = 12
        /// Total vertical space the card strip occupies.
        static let cardStripHeight: CGFloat = card + cardBottomPadding + Space.normal

        /// The source app's icon in a card header.
        static let cardAppIcon: CGFloat = 20
        /// The coloured dot on a type-filter chip.
        static let chipDot: CGFloat = 7
        /// The search field in the top bar. Fixed rather than flexible so the
        /// filter chips beside it do not shift as a query is typed.
        static let searchFieldWidth: CGFloat = 150

        /// Settings and onboarding windows.
        static let sheetWidth: CGFloat = 520
        static let sheetHeight: CGFloat = 420

        /// The square tile used as a settings/onboarding header glyph.
        static let rowIconTile: CGFloat = 34

        /// Trailing hover/selection buttons.
        static let rowActionButton: CGFloat = 22
        /// The queue-position badge.
        static let queueBadge: CGFloat = 18

        /// Onboarding header glyph tile.
        static let onboardingTile: CGFloat = 46
        /// Onboarding progress dot.
        static let progressDot: CGFloat = 6

        /// Preview: colour swatch and file-row icon.
        static let previewSwatch: CGFloat = 88
        static let previewFileIcon: CGFloat = 26
    }

    // MARK: - Line widths

    enum Stroke {
        /// A true device hairline for separators and quiet outlines.
        static let hairline: CGFloat = 1
        /// The selected row's outline — thick enough to read as a *shape*
        /// cue, which is what keeps selection legible without relying on
        /// colour alone.
        static let selection: CGFloat = 1.5
    }

    // MARK: - Motion

    enum Motion {
        /// Selection scrolling and hover — fast enough to feel direct.
        static let quick = Animation.easeOut(duration: 0.12)
        /// State changes that redraw a whole region (preview, filter chips).
        static let standard = Animation.easeOut(duration: 0.18)
    }

    // MARK: - Typography

    /// Named text roles. Sizes that carry content are driven through
    /// `@ScaledMetric` at the use site so they follow the system text-size
    /// setting; the weights and designs live here.
    enum Typography {
        /// The panel's primary body size — the search field, preview text.
        static let bodySize: CGFloat = 13
        /// The preview's body text.
        static let previewBodySize: CGFloat = 13
        /// The instant-calc result, which is the answer the user came for.
        static let calcResultSize: CGFloat = 24

        /// A card header's app name.
        static let cardAppName = Font.system(size: 11, weight: .semibold)
        /// The relative timestamp under it.
        static let cardTime = Font.system(size: 10)
        /// A card's content preview.
        static let cardBodySize: CGFloat = 12
        /// The card's footer stat line ("66 characters").
        static let cardStat = Font.system(size: 10)

        /// Metadata under a row title.
        static let meta = Font.caption
        /// The ⌘N keycap and vim mode badge.
        static let keycap = Font.system(size: 10, weight: .semibold, design: .monospaced)
        /// Quick-filter chips and detection chips.
        static let chip = Font.system(size: 11, weight: .medium)
        /// The footer's clip count.
        static let footnote = Font.caption
    }

    // MARK: - Colour

    /// Semantic colours. Everything resolves through AppKit's system colours
    /// or SwiftUI's hierarchical styles, so Dark Mode, the user's accent
    /// colour and Increase Contrast are all handled by the system.
    enum Palette {
        /// An appearance-dependent colour built the AppKit way, so it
        /// re-resolves when the user switches Light/Dark rather than being
        /// frozen at the value that happened to be current at launch.
        ///
        /// The provider closure is `nonisolated` on purpose: SwiftUI can
        /// resolve colours off its display-link renderer, and a MainActor
        /// closure there trips the executor check.
        nonisolated static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
        }

        /// The user's accent colour, as AppKit resolves it.
        static let accent = Color(nsColor: .controlAccentColor)

        // MARK: Panel & cards

        /// Tint laid over the panel's material. The material alone is too
        /// transparent to read text against an arbitrary desktop picture.
        static let panelOverlay = adaptive(
            light: NSColor.white.withAlphaComponent(0.30),
            dark: NSColor.black.withAlphaComponent(0.22)
        )

        /// A card's header band — a shade separated from its content well, so
        /// the 40-point band reads as a distinct part of the card.
        static let cardHeaderFill = adaptive(
            light: NSColor(red: 0.92, green: 0.92, blue: 0.94, alpha: 0.98),
            dark: NSColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 0.95)
        )

        /// A card's content well.
        static let cardContentFill = adaptive(
            light: NSColor(white: 1.0, alpha: 0.98),
            dark: NSColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 0.98)
        )

        /// The selected card's outline. Neutral rather than accent-coloured:
        /// it is the cue that survives greyscale, colour blindness and every
        /// accent the user may have chosen.
        static func cardSelectedBorder(increasedContrast: Bool) -> Color {
            adaptive(
                light: NSColor.black.withAlphaComponent(increasedContrast ? 0.75 : 0.40),
                dark: NSColor.white.withAlphaComponent(increasedContrast ? 0.85 : 0.50)
            )
        }

        /// Accent wash over the selected card. Deliberately kept *in addition*
        /// to the neutral outline: outline-only selection is nearly invisible
        /// against the hover treatment MemoryClip already had.
        static func cardSelectedTint(increasedContrast: Bool) -> Color {
            accent.opacity(increasedContrast ? 0.34 : 0.16)
        }

        /// Hover wash over an unselected card.
        static func cardHover(increasedContrast: Bool) -> Color {
            Color.primary.opacity(increasedContrast ? 0.14 : 0.06)
        }
        /// Text that sits *on* the accent colour. Never hardcode white here:
        /// macOS picks a legible pair for every accent, including yellow.
        static let onAccent = Color(nsColor: .selectedControlTextColor)

        /// Quiet outline used for tiles, chips and swatches.
        static let hairline = Color.primary.opacity(0.10)
        /// A slightly raised surface (icon tiles, keycaps, chip backgrounds).
        static let surface = Color.primary.opacity(0.06)
        /// The chrome behind the search bar and footer, distinguishing them
        /// from the scrolling list between them.
        static let chrome = Color.primary.opacity(0.035)

        /// Card lift. A fixed black shadow is tuned for a light background:
        /// on the dark panel it muddies the gap between cards without adding
        /// separation, so Dark Mode leans on a deeper, tighter shadow.
        static let cardShadow = adaptive(
            light: NSColor.black.withAlphaComponent(0.18),
            dark: NSColor.black.withAlphaComponent(0.42)
        )

        /// Pins. `.orange` on its own fails contrast on a light background;
        /// the system colour is tuned per appearance.
        static let pin = Color(nsColor: .systemOrange)
        /// The paused-capture warning in the footer.
        static let warning = Color(nsColor: .systemOrange)

        /// Outline of the selected type-filter chip.
        static func chipSelectedBorder(increasedContrast: Bool) -> Color {
            accent.opacity(increasedContrast ? 1.0 : 0.75)
        }

        /// Background of a quick-filter chip.
        static func chipFill(isOn: Bool, increasedContrast: Bool) -> Color {
            if isOn {
                return accent.opacity(increasedContrast ? 0.45 : 0.22)
            }
            return Color.primary.opacity(increasedContrast ? 0.12 : 0.055)
        }

        /// Foreground of a quick-filter chip. The "on" state uses the label
        /// colour rather than the accent so it stays legible against its own
        /// accent-tinted background at every accent colour.
        static func chipText(isOn: Bool) -> Color {
            isOn ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor)
        }
    }
}

// MARK: - Reusable pieces

/// A small rounded tile used as a row's leading slot and as the onboarding
/// header glyph: it gives every kind of clip the same silhouette, so a list
/// mixing text, images and colours still reads as one column.
struct IconTile<Content: View>: View {
    var size: CGFloat = Design.Size.rowIconTile
    var radius: CGFloat = Design.Radius.control
    /// Filled tiles sit behind glyphs; image thumbnails supply their own
    /// pixels and only need the outline.
    var filled: Bool = true
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .background {
                if filled {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Design.Palette.surface)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Design.Palette.hairline, lineWidth: Design.Stroke.hairline)
            }
    }
}

/// A keyboard-cap style label, used for the ⌘1…⌘9 quick-paste hints.
///
/// Replaces the old tertiary-grey text: a bordered cap reads as "this is a
/// key you can press", and lifts the hint's contrast at the same time.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Design.Typography.keycap)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .padding(.horizontal, Design.Space.tight)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.tiny, style: .continuous)
                    .fill(Design.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.tiny, style: .continuous)
                    .strokeBorder(Design.Palette.hairline, lineWidth: Design.Stroke.hairline)
            )
            .monospacedDigit()
    }
}

/// The small capsule used for detected content kinds in the preview.
struct DetectionChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Design.Typography.chip)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .padding(.horizontal, Design.Space.normal)
            .padding(.vertical, Design.Space.tight)
            .background(Capsule(style: .continuous).fill(Design.Palette.surface))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Design.Palette.hairline, lineWidth: Design.Stroke.hairline)
            )
    }
}

extension View {
    /// A pane: a rounded, outlined surface for grouped content.
    func designPane(
        radius: CGFloat = Design.Radius.pane,
        fill: Color = Design.Palette.surface
    ) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Design.Palette.hairline, lineWidth: Design.Stroke.hairline)
            )
    }
}
