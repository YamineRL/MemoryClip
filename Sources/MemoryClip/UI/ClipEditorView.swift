import AppKit
import SwiftUI

/// The preview pane's editing face: the clip's plain text in a real editor,
/// under a header that says what is being edited and which keys leave, and a
/// footer with the three ways out: Cancel, Save, Save and Paste.
///
/// The view is deliberately dumb: every key still belongs to
/// `PanelContentView.panelKeys` (Escape layering, ⌘S as save, ⌘Return as
/// save-and-paste, the ⌘1…⌘9 stand-down), so the one place that knows the
/// rules keeps them. The text view itself only intercepts a bare Escape,
/// because left to the responder chain it would reach `KeyablePanel`'s
/// `cancelOperation` and close the whole window, draft included.
struct ClipEditorView: View {
    let item: ClipItem
    /// The live draft, bound into the panel's editing session.
    @Binding var draft: String
    /// True while the first-Escape "discard?" notice is up.
    let discardArmed: Bool
    let onSave: () -> Void
    let onSaveAndPaste: () -> Void
    let onCancel: () -> Void
    /// What a bare Escape pressed inside the text view runs: the panel's
    /// own `handleEscape`, so the layering is decided in exactly one place.
    let onEscape: () -> Void

    /// Follows the system text-size setting the way the preview body does.
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = Design.Typography.previewBodySize

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.roomy) {
            // Header: what is being edited, and the two ways out by key.
            HStack(spacing: Design.Space.normal) {
                Text(loc("Editing · %@", ClipDisplay.kindLabel(item.kind, isScreenshot: item.isScreenshot)))
                    .font(Design.Typography.cardAppName.weight(.semibold))
                Spacer(minLength: Design.Space.tight)
                Text(loc("⌘S Save"))
                    .font(Design.Typography.meta)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                Text(loc("⌘Return Save and Paste"))
                    .font(Design.Typography.meta)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                Text(loc("Esc Cancel"))
                    .font(Design.Typography.meta)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }

            // A rich-text clip saves flattened, and the one place to say so
            // is above the draft that loses its formatting.
            if item.kind == .richText {
                Text(loc("Formatting is removed when you save."))
                    .font(Design.Typography.meta)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }

            ClipTextEditor(
                text: $draft,
                monospaced: ClipEdit.prefersMonospaced(for: item),
                fontSize: bodyFontSize,
                onEscape: onEscape
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Design.Space.snug)
            .designPane(radius: Design.Radius.pane, fill: Design.Palette.chrome)

            // The inline answer to the first Escape on a dirty draft; the
            // second Escape (or Cancel again) is the discard it warns about.
            if discardArmed {
                Text(loc("Discard changes? Esc again to discard, ⌘S to save."))
                    .font(Design.Typography.meta)
                    .foregroundStyle(Design.Palette.warning)
            }

            HStack(spacing: Design.Space.roomy) {
                Button(loc("Cancel")) { onCancel() }
                    .help(loc("Discard the edit (Esc)"))
                Spacer(minLength: Design.Space.tight)
                Button(loc("Save")) { onSave() }
                    .help(loc("Save the edited clip (⌘S)"))
                Button(loc("Save and Paste")) { onSaveAndPaste() }
                    .buttonStyle(.borderedProminent)
                    .help(loc("Save the edit and paste it (⌘Return)"))
            }
            .controlSize(.small)
        }
        .padding(Design.Space.roomy)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Escape pressed while the panel, not the text view, has the focus
        // (a footer button just clicked) still unwinds the editor first.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc("Clip editor"))
    }
}

/// The editable text inside `ClipEditorView`, wrapped in an `NSScrollView` so
/// a long draft scrolls inside the pane rather than growing it.
struct ClipTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Matches the body font size at the current system text size.
    let monospaced: Bool
    let fontSize: CGFloat
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = ClipDraftTextView()
        textView.onEscape = onEscape
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        // No smart rewriting: an editor that swaps straight quotes for curly
        // ones or "--" for a dash would silently change what gets stored.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = Self.font(monospaced: monospaced, size: fontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Design.Space.snug, height: Design.Space.snug)

        // The standard recipe for a wrapping, vertically scrolling text
        // view: it sizes itself to the scroll view's width and grows down.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        textView.setAccessibilityLabel(loc("Clip text"))
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ClipDraftTextView else { return }
        textView.onEscape = onEscape
        // A keystroke's round trip comes back with the same string and is a
        // no-op; only a draft swapped in from outside (the restored stash)
        // replaces the contents, and then the caret belongs at the end.
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            textView.scrollToEndOfDocument(nil)
        }
        textView.font = Self.font(monospaced: monospaced, size: fontSize)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    private static func font(monospaced: Bool, size: CGFloat) -> NSFont {
        monospaced
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// The text view behind `ClipTextEditor`.
///
/// Escape is intercepted in `keyDown` rather than left to the key-bindings
/// table, where it would become `cancelOperation` and climb the responder
/// chain to `KeyablePanel`, closing the whole window, draft and all. And it
/// takes focus with the caret at the end of the draft, the way "resume what
/// you were typing" expects.
final class ClipDraftTextView: NSTextView {
    var onEscape: (() -> Void)?
    /// True until the first time the view lands in a window.
    private var wantsInitialFocus = true

    override func keyDown(with event: NSEvent) {
        let isPlainEscape = event.keyCode == 53
            && event.modifierFlags
                .intersection([.command, .option, .control, .shift])
                .isEmpty
        if isPlainEscape {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsInitialFocus, window != nil else { return }
        wantsInitialFocus = false
        // After the window is up: focusing any earlier races the panel's own
        // first-responder setup.
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: self.string.utf16.count, length: 0))
            self.scrollToEndOfDocument(nil)
        }
    }
}
