import SwiftUI
import SwiftData
import AppKit

/// Phase-2 preview pane: renders a clip's payload by kind, followed by the
/// instant-calc result (when the text evaluates), detection chips, and JSON
/// quick-transform buttons.
struct PreviewView: View {
    let item: ClipItem
    /// Optional transform callback (wired by PanelView to
    /// `actions.applyTransform`); transform buttons are hidden when absent.
    var onTransform: ((Transform) -> Void)? = nil
    /// Copy callback (wired by PanelView to `actions.copyText`). Falls back to
    /// a plain pasteboard write when absent.
    var onCopy: ((String) -> Void)? = nil

    /// Detection/calc results are cached per content change rather than
    /// recomputed on every body pass — scanning a multi-megabyte clip on the
    /// main actor for each hover or selection change is not affordable.
    @State private var detectedKinds: [DetectedKind] = []
    @State private var calcResult: String?
    /// The full-resolution image, loaded on demand for the ONE previewed clip
    /// (the row list deliberately never touches `imageData`). The thumbnail
    /// stands in until it arrives.
    @State private var fullImage: NSImage?
    /// The clip read back in the user's own language, when it was not in it
    /// already. The state and the work both live outside the view — see
    /// `ClipTranslationPresenter` and `ClipTranslationRuns` — because a
    /// SwiftUI task dies with the pane, and this pane is put away every time
    /// the app stops being frontmost.
    @State private var presenter = ClipTranslationPresenter()
    /// How tall the translated text actually is, so the block can shrink to
    /// it — see `translationBodyHeight`. Zero means "not measured yet".
    @State private var translationTextHeight: CGFloat = 0

    /// Read here rather than through `ClipTranslation` so that changing either
    /// in Settings re-runs the work for the clip on screen, instead of taking
    /// effect at the next selection.
    @AppStorage(NoteSettingsKeys.clipTranslateEnabled) private var translateEnabled = false
    @AppStorage(NoteSettingsKeys.clipTranslationTarget) private var translationTarget = ClipTranslation.defaultTargetIdentifier

    /// Where the translation is cached, so re-opening a preview is free.
    @Environment(\.modelContext) private var modelContext

    /// Design sizes that follow the system text-size setting instead of
    /// being frozen at their point value.
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = Design.Typography.previewBodySize
    @ScaledMetric(relativeTo: .title2) private var calcFontSize: CGFloat = Design.Typography.calcResultSize

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.roomy) {
            // Above the clip, because a clip in a language you do not read is
            // one you look away from: the translation is what makes the pane
            // worth looking at, and the original is right underneath it.
            translationBlock

            // The payload sits on its own pane, so the preview reads as a
            // surface holding content rather than text loose in a box.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Design.Space.roomy)
                .designPane(radius: Design.Radius.pane, fill: Design.Palette.chrome)

            if let calc = calcResult {
                // The answer the user came for: full label colour, not the
                // secondary grey it used to be given.
                Text("= \(calc)")
                    .font(.system(size: calcFontSize, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .textSelection(.enabled)
                    .accessibilityLabel(loc("Equals %@", calc))
            }

            if !detectedKinds.isEmpty {
                HStack(spacing: Design.Space.snug) {
                    ForEach(detectedKinds, id: \.rawValue) { kind in
                        DetectionChip(text: label(for: kind))
                    }
                    Spacer(minLength: Design.Space.normal)
                    if detectedKinds.contains(.json), let onTransform {
                        Button(loc("Format JSON")) { onTransform(.jsonFormat) }
                            .buttonStyle(.bordered)
                        Button(loc("Minify JSON")) { onTransform(.jsonMinify) }
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(Design.Space.roomy)
        // Full-bleed and hit-testable, so a right-click in the pane's empty
        // space — padding, the room beside a short line — reaches the menu.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .contextMenu {
            ForEach(copyOptions) { option in
                Button(option.title) { PreviewCopy.perform(option, using: onCopy) }
            }
        }
        .task(id: contentKey) { await refreshAnalysis() }
        .task(id: contentKey) { await loadFullImage() }
        .task(id: translationKey) { await refreshTranslation() }
    }

    /// What the right-click menu offers for this clip.
    private var copyOptions: [PreviewCopyOption] {
        PreviewCopy.options(for: item, translation: presenter.translation?.text)
    }

    // MARK: Cached analysis

    /// Identity of the previewed *content*; the scans re-run only when it
    /// changes, not on every body pass.
    private var contentKey: String {
        "\(item.contentHash)-\(item.text?.count ?? 0)"
    }

    private func refreshAnalysis() async {
        let kind = item.kind
        let text = item.text
        let result = await Task.detached(priority: .utility) {
            (
                kinds: TextDetector.detect(text ?? ""),
                calc: ClipDisplay.calcResult(kind: kind, text: text)
            )
        }.value
        guard !Task.isCancelled else { return }
        detectedKinds = result.kinds
        calcResult = result.calc
    }

    /// Read the full blob for the previewed clip only. Reset first so a
    /// previously previewed image is released and never shown under the new
    /// selection.
    private func loadFullImage() async {
        fullImage = nil
        guard let payload = item.imagePayload else { return }
        switch payload {
        case .data(let data):
            guard !Task.isCancelled else { return }
            fullImage = NSImage(data: data)
        case .fileURL(let url):
            // A screenshot clip holds a path, so this is real file I/O —
            // off the main actor, and tolerant of the file having been moved
            // or trashed since it was captured (the thumbnail stays on
            // screen in that case, which is why nothing is reported here).
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            guard !Task.isCancelled else { return }
            fullImage = loaded
        }
    }

    // MARK: Translation

    /// Identity of the work: the clip, plus the two settings that decide what
    /// is done with it. Changing the target language in Settings re-runs this
    /// for the clip already on screen.
    ///
    /// Recognition and refinement are counted in as well, because a
    /// screenshot is very often previewed before either has finished with it:
    /// without them the pane would keep showing the nothing it had when the
    /// clip was selected. Lengths rather than the text, so a body pass costs
    /// no copies of it.
    private var translationKey: String {
        "\(contentKey)-\(item.ocrText?.count ?? 0)-\(item.refinedText?.count ?? 0)-\(translateEnabled)-\(translationTarget)"
    }

    /// How tall the translated text is allowed to be: its own height, or the
    /// ceiling, whichever is smaller.
    ///
    /// The ceiling stands in until the first measurement arrives, so the
    /// block settles down to the text rather than growing into it.
    private var translationBodyHeight: CGFloat {
        guard translationTextHeight > 0 else { return Design.Size.previewTranslationHeight }
        return min(translationTextHeight.rounded(.up), Design.Size.previewTranslationHeight)
    }

    /// The translation, over the clip and inside its own pane.
    ///
    /// Nothing at all for the ordinary case — a clip in the language the user
    /// reads — so the pane is unchanged for everyone who has not asked for
    /// this. When there is something, it is bounded: the clip below is what
    /// the preview is for.
    @ViewBuilder
    private var translationBlock: some View {
        if presenter.isTranslating || presenter.translation != nil {
            VStack(alignment: .leading, spacing: Design.Space.snug) {
                HStack(spacing: Design.Space.snug) {
                    Text(presenter.translation?.languagePair ?? loc("Translating…"))
                        .font(Design.Typography.meta)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    if presenter.isTranslating {
                        // Small and unlabelled: the pane already says what is
                        // happening, and the clip below is readable meanwhile.
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                }

                if let translation = presenter.translation {
                    ScrollView {
                        SelectableText(text: translation.text, size: bodyFontSize)
                            // Measured from INSIDE the scroll view, which
                            // proposes no height to its content, so this is
                            // the text's own height rather than the one it
                            // was given.
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                translationTextHeight = height
                            }
                    }
                    // An exact height, not a maximum: a scroll view takes
                    // every point it is offered up to its cap, so a
                    // two-line translation in a `maxHeight` frame sat in
                    // 84 points of empty pane.
                    .frame(height: translationBodyHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Design.Space.roomy)
            .designPane(radius: Design.Radius.pane, fill: Design.Palette.chrome)
            // `.contain` rather than `.combine`: the translated text stays its
            // own element, so it can be read, navigated and selected, and the
            // group carries the label that says what it is.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(presenter.translation?.accessibilityDescription ?? loc("Translating this clip"))
        }
    }

    /// Show the clip's translation, or start one.
    ///
    /// Thin on purpose: the state and the work are the presenter's and the
    /// run store's, so neither dies when this pane does — which it does every
    /// time MemoryClip stops being the frontmost app.
    private func refreshTranslation() async {
        // The previous clip's measurement says nothing about this one's.
        translationTextHeight = 0
        await presenter.refresh(
            item: item,
            context: modelContext,
            isEnabled: translateEnabled,
            target: Locale.Language(identifier: translationTarget)
        )
    }

    // MARK: Content by kind

    @ViewBuilder
    private var content: some View {
        // The screenshot check comes first: such a clip's kind is `.file`,
        // but a list of one path is not what the user opened the preview to
        // see — the picture and its text are.
        if item.isScreenshot {
            imageContent
        } else {
            switch item.kind {
            case .text, .richText, .link:
                textContent
            case .image:
                imageContent
            case .color:
                colorContent
            case .file:
                fileContent
            }
        }
    }

    /// Selectable, scrollable full text (covers .text, .richText and .link —
    /// all of them carry their plain text in `item.text`).
    private var textContent: some View {
        let body = ClipDisplay.previewBody(item.text ?? "")
        return ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.normal) {
                SelectableText(text: body.text, size: bodyFontSize)
                if let notice = body.notice {
                    Text(notice)
                        .font(Design.Typography.meta)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        // The image keeps the pane, but when OCR found something the text is
        // the reason most people opened the preview — so it gets its own
        // selectable, scrollable half rather than being hidden behind search.
        VStack(alignment: .leading, spacing: Design.Space.roomy) {
            if let nsImage = fullImage ?? item.thumbnailData.flatMap(NSImage.init(data:)) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    // A floor as well as a ceiling: the picture is the reason
                    // this pane exists, and sharing 250 points with the text
                    // blocks under it had shrunk it to a band nothing could
                    // be read in.
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Design.Size.previewImageMinHeight,
                        maxHeight: .infinity
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous))
            } else {
                emptyPlaceholder
            }

            // Hidden while a translation is on screen. Three blocks do not
            // fit in this pane, and this is the one that earns its place
            // least of the three: the translation above already carries this
            // same recognised text in a language the reader can read, and the
            // picture carries it as it actually appeared. Raw recognition in
            // a script they do not read, wedged under a squeezed thumbnail,
            // is the third copy. With translation off, or for a clip that had
            // none to make, the block is exactly what it always was.
            if let extracted = extractedText, presenter.translation == nil {
                Divider()
                VStack(alignment: .leading, spacing: Design.Space.snug) {
                    Text(loc("Extracted Text"))
                        .font(Design.Typography.meta)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    ScrollView {
                        extractedBody(extracted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Bounded so a text-heavy screenshot cannot squeeze the image
                // out of the pane entirely.
                .frame(maxHeight: Design.Size.previewExtractedTextHeight)
            }
        }
    }

    /// Extracted text, with any table in it drawn as a table.
    ///
    /// Recognition stores tables as Markdown (see `TableLayout`), which is the
    /// right thing to store and the wrong thing to show: a column of pipes in
    /// a proportional font is harder to read than the screenshot it came from.
    /// So the pane parses them back out and lays them on a grid, and leaves
    /// everything else as the plain, selectable text it already was.
    @ViewBuilder
    private func extractedBody(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.roomy) {
            ForEach(Array(MarkdownTable.blocks(in: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        SelectableText(text: trimmed, size: bodyFontSize)
                    }
                case .table(let table):
                    tableGrid(table)
                }
            }
        }
    }

    /// One recognized table. Monospaced digits so a column of numbers lines
    /// up under its header the way it did on screen, and a rule under the
    /// header row because that is the only thing separating it from the data
    /// once the pipes are gone.
    private func tableGrid(_ table: MarkdownTable) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Design.Space.loose, verticalSpacing: Design.Space.snug) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                    Text(cell)
                        .font(.system(size: bodyFontSize, weight: .semibold))
                        .textSelection(.enabled)
                }
            }
            Divider().gridCellColumns(table.columnCount)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.system(size: bodyFontSize).monospacedDigit())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The image clip's OCR text, or nil when Vision found nothing usable.
    private var extractedText: String? {
        ClipDisplay.extractedText(for: item)
    }

    @ViewBuilder
    private var colorContent: some View {
        if let hex = item.colorHex, let color = NSColor(hexString: hex) {
            HStack(spacing: Design.Space.loose) {
                RoundedRectangle(cornerRadius: Design.Radius.pane, style: .continuous)
                    .fill(Color(nsColor: color))
                    .frame(width: Design.Size.previewSwatch, height: Design.Size.previewSwatch)
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.Radius.pane, style: .continuous)
                            .strokeBorder(Design.Palette.hairline, lineWidth: Design.Stroke.hairline)
                    )
                VStack(alignment: .leading, spacing: Design.Space.snug) {
                    Text(hex)
                        .font(.title3.monospaced().weight(.medium))
                        .textSelection(.enabled)
                    Text(loc("RGB %@", rgbDescription(of: color)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .textSelection(.enabled)
                }
            }
        } else {
            emptyPlaceholder
        }
    }

    private var fileContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.roomy) {
                ForEach(item.fileURLStrings, id: \.self) { urlString in
                    // Stored as URL.absoluteString, so decode before showing
                    // it or looking up its icon ("my%20file.txt").
                    let path = ClipDisplay.displayPath(urlString)
                    HStack(spacing: Design.Space.roomy) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .scaledToFit()
                            .frame(width: Design.Size.previewFileIcon, height: Design.Size.previewFileIcon)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Design.Space.hair) {
                            Text(ClipDisplay.displayName(urlString))
                                .lineLimit(1)
                            Text(path)
                                .font(Design.Typography.meta)
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: Design.Space.normal) {
            Image(systemName: "eye.slash")
                .font(.system(size: 22, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(loc("Nothing to preview"))
                .font(Design.Typography.meta)
        }
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Info bar pieces

    private func label(for kind: DetectedKind) -> String {
        switch kind {
        case .email: return loc("Email")
        case .url: return "URL"
        case .phone: return loc("Phone")
        case .jwt: return "JWT"
        case .json: return "JSON"
        }
    }

    private func rgbDescription(of color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let red = Int((srgb.redComponent * 255).rounded())
        let green = Int((srgb.greenComponent * 255).rounded())
        let blue = Int((srgb.blueComponent * 255).rounded())
        return "\(red), \(green), \(blue)"
    }
}

// MARK: - Selectable body text

/// Read-only text whose selectable region is the full width it is given, so a
/// drag anywhere on a line selects that line.
///
/// A SwiftUI `Text` is laid out at the width of its own glyphs, and
/// `.textSelection(.enabled)` covers exactly that — a `.frame(maxWidth:
/// .infinity)` around it widens the view, not the selection.
struct SelectableText: NSViewRepresentable {
    let text: String
    let size: CGFloat

    func makeNSView(context _: Context) -> PreviewTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let view = PreviewTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        // Drawn in the accent colour even though the view never takes focus.
        view.selectedTextAttributes = [NSAttributedString.Key.backgroundColor: NSColor.selectedTextBackgroundColor]
        return view
    }

    func updateNSView(_ view: PreviewTextView, context _: Context) {
        if view.string != text { view.string = text }
        // After `string`, which resets both.
        view.font = NSFont.systemFont(ofSize: size)
        view.textColor = .labelColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewTextView, context _: Context) -> CGSize? {
        let proposed = proposal.width ?? nsView.bounds.width
        let width = (proposed.isFinite && proposed > 0) ? proposed : nsView.bounds.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// The text view behind `SelectableText`.
final class PreviewTextView: NSTextView {
    /// Never becomes first responder, so the panel keeps the arrow keys,
    /// Space and Escape while a preview is open.
    override var acceptsFirstResponder: Bool { false }

    /// No menu of its own: right-clicks fall through to the pane's
    /// `.contextMenu`, so the same menu appears everywhere in the preview.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    /// Height the text lays out to at `width`.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layoutManager else { return 0 }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height.rounded(.up)
    }
}
