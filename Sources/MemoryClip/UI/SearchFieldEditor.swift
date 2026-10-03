import AppKit

/// The marker `SearchOperatorFieldEditor` sets on `key:value` spans and
/// `OperatorTokenLayoutManager` draws pills behind. The attribute is how
/// the styling pass hands a span to the drawing pass without either knowing
/// the other's bookkeeping.
private extension NSAttributedString.Key {
    static let operatorToken = NSAttributedString.Key("MemoryClipOperatorToken")
}

/// Draws the rounded background behind `.operatorToken` spans - the one
/// part of the operator-token treatment an attributed string cannot carry.
final class OperatorTokenLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.operatorToken, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            // The pill hugs the token's glyphs with a breath of padding and
            // clears the baseline, rather than running to the line box.
            let pill = rect.insetBy(dx: -3, dy: 1.5)
            let path = NSBezierPath(
                roundedRect: pill,
                xRadius: Design.Radius.small,
                yRadius: Design.Radius.small
            )
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }
}

/// The field editor the panel's search field edits with.
///
/// Handed out by `PanelController.windowWillReturnFieldEditor`, which is the
/// one hook AppKit gives a window over the editor its text fields share -
/// and the only way to draw inside a text field's live editing without
/// replacing the field itself. Behaves like the stock editor in every
/// respect but `restyle()`: recognised `key:value` operators get the pill
/// and a secondary-coloured `key:` head, an operator whose value its key
/// does not know gets a warning underline and a tooltip naming the valid
/// values, and plain words keep the defaults.
///
/// The styling re-derives from the text on every edit, so a token edited
/// back into a word loses its pill rather than keeping a stale one.
final class SearchOperatorFieldEditor: NSTextView {
    init() {
        // Build the text stack by hand - NSTextView's own initialisers make
        // their own layout manager - then hand the custom container to the
        // textview so `OperatorTokenLayoutManager` draws its background.
        let storage = NSTextStorage()
        let layoutManager = OperatorTokenLayoutManager()
        let container = NSTextContainer()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)

        // Field-editor behaviour: single visual line that scrolls sideways,
        // no rich-text smarts, and none of the substitutions that would
        // rewrite a query under the caret (smart quotes turning `app:"x"`
        // into `app:"x"`'s curly cousins would still parse - the grammar
        // strips them - but the text on screen must be the text stored).
        isFieldEditor = true
        isRichText = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        allowsUndo = true
        drawsBackground = false
        textContainerInset = .zero
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false
        font = .systemFont(ofSize: Design.Typography.bodySize)
        textColor = .labelColor
        typingAttributes = [
            .font: NSFont.systemFont(ofSize: Design.Typography.bodySize),
            .foregroundColor: NSColor.labelColor
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SearchOperatorFieldEditor is constructed in code only")
    }

    override func didChangeText() {
        super.didChangeText()
        restyle()
    }

    /// Re-derive the whole field's styling from the text - cheap at search-
    /// field sizes, and idempotent, so it can run on every edit rather than
    /// tracking which spans moved.
    private func restyle() {
        guard let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let baseFont = NSFont.systemFont(ofSize: Design.Typography.bodySize)
        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
        ], range: whole)
        storage.removeAttribute(.operatorToken, range: whole)
        storage.removeAttribute(.underlineStyle, range: whole)
        storage.removeAttribute(.underlineColor, range: whole)
        storage.removeAttribute(.toolTip, range: whole)
        for token in ClipQuery.operatorTokens(in: storage.string) {
            let span = NSRange(token.range, in: storage.string)
            storage.addAttribute(.operatorToken, value: true, range: span)
            storage.addAttribute(
                .foregroundColor,
                value: NSColor.secondaryLabelColor,
                range: NSRange(token.head, in: storage.string)
            )
            if !token.valueIsKnown {
                // A value the key does not know contributes nothing - the
                // underline and the tooltip are how that is said without
                // interrupting the typing.
                storage.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: span
                )
                storage.addAttribute(
                    .underlineColor,
                    value: NSColor.systemOrange,
                    range: span
                )
                storage.addAttribute(
                    .toolTip,
                    value: loc("Not a known value: %@", token.key.knownValues.joined(separator: ", ")),
                    range: span
                )
            }
        }
        storage.endEditing()
        // Text typed next must come in plain: attributes at the caret
        // propagate forward, and a token's secondary colour would bleed
        // into whatever follows it otherwise.
        typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
        ]
    }
}
