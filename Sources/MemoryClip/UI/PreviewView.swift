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
    /// The height the pane was given, so an image clip's text panel can grow
    /// with it. Nil holds the panel at its default height.
    var paneHeight: CGFloat? = nil
    /// Edit callback, wired by PanelView for clips `ClipDisplay.canEdit`
    /// accepts. Nil hides the header's Edit button rather than disabling it.
    var onEdit: (() -> Void)? = nil
    /// Filter-to-this-app callback (wired by PanelView to `filter.source`):
    /// clicking the source app in the meta line inserts `app:"Name"` in the
    /// search field. The name renders plain when absent.
    var onFilterApp: ((String) -> Void)? = nil
    /// The pane's current text selection, published upward so the panel's ⌘C
    /// can copy it. Nil when nothing is selected.
    var onSelectionChange: ((String?) -> Void)? = nil

    /// A revealed secret's plaintext, while the reveal lives. Nil is the
    /// locked state; the pane never reads `secretCipher` itself.
    var secretText: String? = nil
    /// When the reveal closes — the countdown's deadline and the expiry
    /// task's key.
    var secretHidesAt: Date? = nil
    /// The one line a refused or failed reveal leaves on the locked pane.
    var secretNotice: String? = nil
    /// Locked pane's Show button (and Space's target): opens the cipher.
    var onRevealSecret: (() -> Void)? = nil
    /// Revealed pane's Hide button and the countdown's expiry: conceals.
    var onHideSecret: (() -> Void)? = nil
    /// Revealed pane's "Not a Secret": authenticates and demotes the row.
    var onDemoteSecret: (() -> Void)? = nil
    /// Concealed-write the plaintext (whole or selected) to the pasteboard.
    var onCopySecret: ((String) -> Void)? = nil
    /// Bumped by the panel's ⌘T to flip the text panel between the original
    /// and the translation.
    var textTabToggle: Int = 0

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
    /// What is selected in the pane right now, so the right-click menu can
    /// offer it. Written by every `SelectableText` in the pane.
    @State private var selection: String?

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
            // The pane's header answers "which Slack thing, yesterday" at a
            // glance: where the clip came from, and when. The app name is a
            // button because clicking it is the `app:` operator's one-tap
            // form; a clip with no source just shows the when. The Edit
            // button sits on the row's far end for the clips that offer it —
            // hidden, not disabled, for every other kind.
            HStack(spacing: Design.Space.snug) {
                if let app = item.sourceAppName, !app.isEmpty {
                    Button {
                        onFilterApp?(app)
                    } label: {
                        Text(app)
                            .font(Design.Typography.meta)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                    .buttonStyle(.plain)
                    .disabled(onFilterApp == nil)
                    .help(loc("Show only %@", app))
                    .accessibilityLabel(loc("Show only %@", app))
                }
                Text(item.createdAt, style: .relative)
                    .font(Design.Typography.meta)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                Spacer(minLength: 0)
                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Label(loc("Edit"), systemImage: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .font(Design.Typography.footnote)
                    .help(loc("Edit this clip (⌘I)"))
                }
            }

            // The payload sits on its own pane, so the preview reads as a
            // surface holding content rather than text loose in a box.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Design.Space.roomy)
                .designPane(radius: Design.Radius.pane, fill: Design.Palette.chrome)

            cleanedRow

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
            if item.isSecret {
                // Concealed writes only — the menu must never route a secret
                // through `onCopy`, which writes plain text.
                if let secretText {
                    if let selection, !selection.isEmpty {
                        Button(loc("Copy Selection")) { onCopySecret?(selection) }
                    }
                    Button(loc("Copy Secret")) { onCopySecret?(secretText) }
                }
            } else {
                ForEach(copyOptions) { option in
                    Button(option.title) { PreviewCopy.perform(option, using: onCopy) }
                }
            }
        }
        // A selection belongs to the clip it was made in.
        .onChange(of: contentKey) { report(nil) }
        .onDisappear { report(nil) }
        .task(id: contentKey) { await refreshAnalysis() }
        .task(id: contentKey) { await loadFullImage() }
        .task(id: translationKey) { await refreshTranslation() }
        // The reveal's deadline: sleeping to it rather than polling, so the
        // conceal lands on the second and dies with the pane.
        .task(id: secretHidesAt) {
            guard let secretHidesAt else { return }
            let wait = secretHidesAt.timeIntervalSinceNow
            guard wait > 0 else {
                onHideSecret?()
                return
            }
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            onHideSecret?()
        }
    }

    /// The one line a cleaned link gets: what was taken off it, and the way
    /// back.
    ///
    /// `Use original` writes the untouched URL to the pasteboard, so the next
    /// ⌘V pastes it — the stored clip keeps the cleaned form and the badge.
    /// That is the escape hatch for a parameter that turns out to matter: a
    /// campaign the user is actually reading, a share link that is genuinely
    /// per-recipient.
    @ViewBuilder
    private var cleanedRow: some View {
        if let original = item.originalText {
            HStack(spacing: Design.Space.snug) {
                DetectionChip(text: cleanedLabel)
                Spacer(minLength: Design.Space.normal)
                Button(loc("Use original")) { PreviewCopy.write(original, using: onCopy) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }

    /// `Cleaned · removed igsh`, or plain `Cleaned` for a clip stored before
    /// the removed names were recorded.
    private var cleanedLabel: String {
        let removed = LinkCleaner.clean(item.originalText ?? "", options: LinkSettings.options)?.removed ?? []
        guard !removed.isEmpty else { return loc("Cleaned") }
        return loc("Cleaned · removed %@", removed.joined(separator: ", "))
    }

    /// What the right-click menu offers for this clip.
    private var copyOptions: [PreviewCopyOption] {
        PreviewCopy.options(for: item, translation: presenter.translation?.text, selection: selection)
    }

    /// Record a selection and hand it to the panel.
    private func report(_ text: String?) {
        selection = text
        onSelectionChange?(text)
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

    /// Show the clip's translation, or start one.
    ///
    /// Thin on purpose: the state and the work are the presenter's and the
    /// run store's, so neither dies when this pane does — which it does every
    /// time MemoryClip stops being the frontmost app.
    private func refreshTranslation() async {
        // A secret row carries no text to translate, and its ciphertext must
        // never reach a model — the presenter's input is `item.text`, which
        // is nil, but the guard says so rather than relying on it.
        guard !item.isSecret else { return }
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
        // The secret check comes first: the row's payload is ciphertext, so
        // every other branch would draw an empty pane.
        if item.isSecret {
            secretContent
        } else if item.isScreenshot {
            // The screenshot check comes first: such a clip's kind is
            // `.file`, but a list of one path is not what the user opened
            // the preview to see — the picture and its text are.
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

    /// What a secret clip's pane shows, in its two states.
    ///
    /// Locked: the catalogue label, the mask, the source and age, and the
    /// way in — the pane is the feature's one trusted surface, so this is
    /// where the Touch ID prompt is asked for. Revealed: the plaintext,
    /// monospaced, under a live countdown, with the three things a revealed
    /// secret can do. `secretText` alone tells the two states apart; a nil
    /// one means locked, whatever `isSecret` says.
    @ViewBuilder
    private var secretContent: some View {
        if let secretText {
            VStack(alignment: .leading, spacing: Design.Space.roomy) {
                ScrollView {
                    SelectableText(
                        text: secretText,
                        size: bodyFontSize,
                        onSelectionChange: report,
                        monospaced: true
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollMoreHint()

                HStack(spacing: Design.Space.normal) {
                    if let secretHidesAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(loc(
                                "Hides in %d s",
                                max(0, Int(secretHidesAt.timeIntervalSince(context.date).rounded(.up)))
                            ))
                            .font(Design.Typography.meta)
                            .monospacedDigit()
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }
                    }
                    Spacer(minLength: Design.Space.normal)
                    Button(loc("Copy")) { onCopySecret?(secretText) }
                    Button(loc("Hide")) { onHideSecret?() }
                    Button(loc("Not a Secret")) { onDemoteSecret?() }
                }
                .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: Design.Space.snug) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .accessibilityHidden(true)
                Text(item.secretLabel.map(loc) ?? loc("Token"))
                    .font(.system(size: bodyFontSize, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                if let mask = item.secretMasked, !mask.isEmpty {
                    Text(mask)
                        .font(.system(size: bodyFontSize, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .textSelection(.enabled)
                }
                Text(secretByline)
                    .font(Design.Typography.meta)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                if let secretNotice {
                    Text(secretNotice)
                        .font(Design.Typography.meta)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                HStack(spacing: Design.Space.snug) {
                    Button {
                        onRevealSecret?()
                    } label: {
                        Label(loc("Show"), systemImage: "touchid")
                    }
                    Text(loc("or press Space"))
                        .font(Design.Typography.meta)
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                .controlSize(.small)
                .padding(.top, Design.Space.snug)
                Text(loc("Return pastes it, after Touch ID."))
                    .font(Design.Typography.meta)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            // The locked pane says what it is, never what it holds — the
            // mask's characters are the only plaintext on it.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(ClipDisplay.secretRowLabel(
                label: item.secretLabel.map { loc($0) },
                appName: item.sourceAppName,
                relativeTime: item.createdAt.formatted(.relative(presentation: .named)),
                expiresAt: item.expiresAt
            ))
        }
    }

    /// "from Terminal · 2 minutes ago" — the locked pane's provenance line.
    private var secretByline: String {
        let app = (item.sourceAppName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let time = item.createdAt.formatted(.relative(presentation: .named))
        return app.isEmpty ? time : loc("from %@ · %@", app, time)
    }

    /// Selectable, scrollable full text, and its translation when there is
    /// one (covers .text, .richText and .link, all of which carry their plain
    /// text in `item.text`).
    private var textContent: some View {
        let body = ClipDisplay.previewBody(item.text ?? "")
        return textPanel(.text, original: body.text, notice: body.notice)
    }

    @ViewBuilder
    private var imageContent: some View {
        // The image keeps the pane, but when OCR found something the text is
        // the reason most people opened the preview, so it gets a selectable,
        // scrollable panel of its own rather than being hidden behind search.
        VStack(alignment: .leading, spacing: Design.Space.roomy) {
            if let nsImage = fullImage ?? item.thumbnailData.flatMap(NSImage.init(data:)) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    // A floor as well as a ceiling: the picture is the reason
                    // this pane exists, and sharing 250 points with the text
                    // panel under it had shrunk it to a band nothing could be
                    // read in.
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Design.Size.previewImageMinHeight,
                        maxHeight: .infinity
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous))
            } else {
                emptyPlaceholder
            }

            // The text the translation is made from, so both tabs show the
            // same text with the same line breaks and tables.
            let source = item.clipTranslationSourceText
            if source != nil || presenter.translation != nil {
                Divider()
                textPanel(.image, original: source ?? "", notice: nil)
                    // As tall as the pane's height says and never as tall as
                    // the text: the scroll view inside takes the height it is
                    // given, so a streaming translation cannot move the
                    // picture. The priority hands the panel its height first;
                    // when the pane is too short for both, the picture keeps
                    // its floor and the panel gives up the difference.
                    .frame(maxHeight: PreviewTextPanelModel.panelHeight(paneHeight: paneHeight))
                    .layoutPriority(1)
            }
        }
    }

    /// The clip's text panel, fresh for each clip so its tab choice and its
    /// one automatic switch belong to the clip they were made on.
    private func textPanel(_ context: PreviewTextPanel.Context, original: String, notice: String?) -> some View {
        PreviewTextPanel(
            context: context,
            original: original,
            notice: notice,
            translation: presenter.translation,
            isTranslating: presenter.isTranslating,
            targetLanguage: translationTarget,
            toggleRequest: textTabToggle,
            onSelectionChange: report
        )
        .id(item.uuid)
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
        case .jwt: return loc("JWT")
        case .json: return loc("JSON")
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
    /// Called with the selected substring, or nil when the selection empties,
    /// so the pane above can offer it to ⌘C.
    var onSelectionChange: ((String?) -> Void)? = nil
    /// Monospaced face — revealed secrets are token strings, and a
    /// proportional font hides exactly the characters that matter (l/1/I).
    var monospaced: Bool = false

    func makeCoordinator() -> SelectionReporter { SelectionReporter() }

    func makeNSView(context: Context) -> PreviewTextView {
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
        view.delegate = context.coordinator
        context.coordinator.onSelectionChange = onSelectionChange
        return view
    }

    func updateNSView(_ view: PreviewTextView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        if view.string != text { view.string = text }
        // After `string`, which resets both.
        view.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.systemFont(ofSize: size)
        view.textColor = .labelColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewTextView, context _: Context) -> CGSize? {
        let proposed = proposal.width ?? nsView.bounds.width
        let width = (proposed.isFinite && proposed > 0) ? proposed : nsView.bounds.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// Passes a `SelectableText`'s selection back to SwiftUI as it changes.
@MainActor
final class SelectionReporter: NSObject, NSTextViewDelegate {
    var onSelectionChange: ((String?) -> Void)?

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = notification.object as? PreviewTextView else { return }
        onSelectionChange?(view.selectedText)
    }
}

/// The text view behind `SelectableText`.
final class PreviewTextView: NSTextView {
    /// Never becomes first responder, so the panel keeps the arrow keys,
    /// Space and Escape while a preview is open.
    ///
    /// Do not "fix" ⌘C by flipping this to true: a text view in the responder
    /// chain swallows the arrows, Space, Escape and every keystroke the
    /// type-to-filter field lives on. ⌘C goes to the first responder, so the
    /// panel handles it and asks for `selectedText` instead — see
    /// `PreviewCopy.copyTarget(selection:clipText:)`.
    override var acceptsFirstResponder: Bool { false }

    /// No menu of its own: right-clicks fall through to the pane's
    /// `.contextMenu`, so the same menu appears everywhere in the preview.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    /// The selected substring, or nil when nothing is selected.
    var selectedText: String? {
        let range = selectedRange()
        guard range.length > 0, let text = string as NSString? else { return nil }
        guard NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }

    /// A right-click inside the selection keeps it, so `Copy Selection` in the
    /// pane's menu acts on what the user is looking at. `NSTextView` would
    /// otherwise move the insertion point to the click.
    override func rightMouseDown(with event: NSEvent) {
        let range = selectedRange()
        if range.length > 0 {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if NSLocationInRange(index, range) {
                nextResponder?.rightMouseDown(with: event)
                return
            }
        }
        super.rightMouseDown(with: event)
    }

    /// Height the text lays out to at `width`.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layoutManager else { return 0 }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height.rounded(.up)
    }
}
