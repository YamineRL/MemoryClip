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
    /// already — see `ClipTranslation`.
    @State private var translation: ClipTranslationResult?
    @State private var isTranslating = false
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

    private let translationService = ClipTranslationService()

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
                    .accessibilityLabel("Equals \(calc)")
            }

            if !detectedKinds.isEmpty {
                HStack(spacing: Design.Space.snug) {
                    ForEach(detectedKinds, id: \.rawValue) { kind in
                        DetectionChip(text: label(for: kind))
                    }
                    Spacer(minLength: Design.Space.normal)
                    if detectedKinds.contains(.json), let onTransform {
                        Button("Format JSON") { onTransform(.jsonFormat) }
                            .buttonStyle(.bordered)
                        Button("Minify JSON") { onTransform(.jsonMinify) }
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(Design.Space.roomy)
        .task(id: contentKey) { await refreshAnalysis() }
        .task(id: contentKey) { await loadFullImage() }
        .task(id: translationKey) { await refreshTranslation() }
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
        if isTranslating || translation != nil {
            VStack(alignment: .leading, spacing: Design.Space.snug) {
                HStack(spacing: Design.Space.snug) {
                    Text(translation?.languagePair ?? "Translating…")
                        .font(Design.Typography.meta)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    if isTranslating {
                        // Small and unlabelled: the pane already says what is
                        // happening, and the clip below is readable meanwhile.
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                }

                if let translation {
                    ScrollView {
                        Text(translation.text)
                            .font(.system(size: bodyFontSize))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
            .accessibilityLabel(translation?.accessibilityDescription ?? "Translating this clip")
        }
    }

    /// Translate the clip on screen, or show what was translated before.
    ///
    /// Runs when the previewed clip changes and when either translation
    /// setting does. Every early return leaves the block hidden, which is the
    /// same thing the pane did before this existed.
    private func refreshTranslation() async {
        translation = nil
        isTranslating = false
        // The previous clip's measurement says nothing about this one's.
        translationTextHeight = 0
        guard !item.isDeleted else { return }

        let plan = ClipTranslation.plan(
            text: item.clipTranslationSourceText,
            cached: item.cachedClipTranslation,
            isEnabled: translateEnabled,
            target: Locale.Language(identifier: translationTarget)
        )

        switch plan {
        case .skip:
            return
        case .cached(let cached):
            translation = cached
        case .translate(let request):
            isTranslating = true
            let result = await translationService.translation(for: request)
            // A new selection cancels this task, and the state it would write
            // belongs to the clip that is no longer on screen.
            guard !Task.isCancelled else { return }
            isTranslating = false
            guard let result else { return }
            translation = result
            cache(result)
        }
    }

    /// Keep the translation on the clip, so opening this preview again costs
    /// nothing.
    private func cache(_ result: ClipTranslationResult) {
        guard !item.isDeleted else { return }
        item.cachedClipTranslation = result
        do {
            try modelContext.save()
        } catch {
            // The translation is on screen either way; all that is lost is
            // the saving of it, which costs one re-translation next time.
            log.error("Caching a clip translation failed: \(error.localizedDescription)")
        }
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
                Text(body.text)
                    .font(.system(size: bodyFontSize))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            if let extracted = extractedText, translation == nil {
                Divider()
                VStack(alignment: .leading, spacing: Design.Space.snug) {
                    Text("Extracted Text")
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
                        Text(trimmed)
                            .font(.system(size: bodyFontSize))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text("RGB \(rgbDescription(of: color))")
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
            Text("Nothing to preview")
                .font(Design.Typography.meta)
        }
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Info bar pieces

    private func label(for kind: DetectedKind) -> String {
        switch kind {
        case .email: return "Email"
        case .url: return "URL"
        case .phone: return "Phone"
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
