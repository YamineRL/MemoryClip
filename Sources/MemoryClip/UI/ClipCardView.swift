import SwiftUI
import SwiftData
import AppKit

/// Source-app icons, resolved once per bundle identifier.
///
/// `NSWorkspace.icon(forFile:)` hits the filesystem, and the card strip asks
/// for the same handful of apps over and over as it scrolls — so the answer is
/// memoised rather than re-derived per card, per render.
@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

/// One clip, drawn as a square card in the panel's horizontal deck.
///
/// The shape is the point: a 200-point square split into a 40-point header
/// band (app icon, app name, relative time, type glyph) over a content well
/// that shows the clip itself and closes with a one-line stat ("66
/// characters"). A row of these reads as a *deck* you scan sideways, which is
/// the whole reason the panel stopped being a vertical list.
struct ClipCardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorSchemeContrast) private var contrast

    let item: ClipItem
    let index: Int
    let isSelected: Bool
    /// 1-based place in the paste queue, or nil when not queued.
    let queuePosition: Int?
    let onPaste: (Bool) -> Void
    let onCopyOnly: () -> Void
    let onCopyExtractedText: () -> Void
    let onTransform: (Transform) -> Void
    let onShowQR: () -> Void
    let onToggleQueue: () -> Void
    let onSaveNote: () -> Void
    let onOpenNote: () -> Void
    let onRevealInFinder: () -> Void

    @State private var isHovering = false
    /// Cached instant-calc result. Computed once per content change off the
    /// main actor rather than on every body pass (hover, selection, scroll).
    @State private var calcSuffix: String?

    init(
        item: ClipItem,
        index: Int,
        isSelected: Bool,
        queuePosition: Int? = nil,
        onPaste: @escaping (Bool) -> Void,
        onCopyOnly: @escaping () -> Void,
        onCopyExtractedText: @escaping () -> Void = {},
        onTransform: @escaping (Transform) -> Void,
        onShowQR: @escaping () -> Void,
        onToggleQueue: @escaping () -> Void = {},
        onSaveNote: @escaping () -> Void = {},
        onOpenNote: @escaping () -> Void = {},
        onRevealInFinder: @escaping () -> Void = {}
    ) {
        self.item = item
        self.index = index
        self.isSelected = isSelected
        self.queuePosition = queuePosition
        self.onPaste = onPaste
        self.onCopyOnly = onCopyOnly
        self.onCopyExtractedText = onCopyExtractedText
        self.onTransform = onTransform
        self.onShowQR = onShowQR
        self.onToggleQueue = onToggleQueue
        self.onSaveNote = onSaveNote
        self.onOpenNote = onOpenNote
        self.onRevealInFinder = onRevealInFinder
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            contentWell
        }
        .frame(width: Design.Size.card, height: Design.Size.card)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        // The wash sits *over* the card so it tints header and content well
        // alike; it must never intercept the tap that pastes the clip.
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(wash)
                .allowsHitTesting(false)
        }
        .overlay { selectionOutline }
        .shadow(color: Design.Palette.cardShadow, radius: 3, x: 0, y: 1)
        .onHover { isHovering = $0 }
        .task(id: contentKey) { await refreshCalc() }
        .contextMenu {
            Button("Paste") { onPaste(false) }
            Button("Paste as Plain Text") { onPaste(true) }
            Button("Copy Only") { onCopyOnly() }
            Divider()
            if item.kind == .link {
                Button("Show QR Code") { onShowQR() }
            }
            if extractedText != nil {
                Button("Copy Extracted Text") { onCopyExtractedText() }
            }
            if isTextBearing {
                Menu("Transform") {
                    ForEach(Transform.allCases) { transform in
                        Button(transform.label) { onTransform(transform) }
                    }
                }
            }
            if item.isScreenshot {
                Button("Reveal in Finder") { onRevealInFinder() }
            }
            if canSaveNote {
                Button(item.notePath == nil ? "Save as Note" : "Update Note") { onSaveNote() }
            }
            if item.notePath != nil {
                Button("Open Note") { onOpenNote() }
            }
            Divider()
            Button(queuePosition == nil ? "Add to Queue" : "Remove from Queue") { onToggleQueue() }
            Button(item.isPinned ? "Unpin" : "Pin") { togglePinned() }
            Button("Delete", role: .destructive) { deleteItem() }
        }
        // One element per card: the default leaf-by-leaf exposure made a card
        // an unlabelled pile of glyphs.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: item.isPinned ? "Unpin" : "Pin") { togglePinned() }
        .accessibilityAction(named: "Delete") { deleteItem() }
        .accessibilityAction(named: queuePosition == nil ? "Add to Queue" : "Remove from Queue") {
            onToggleQueue()
        }
        .accessibilityActions {
            if canSaveNote {
                Button(item.notePath == nil ? "Save as Note" : "Update Note") { onSaveNote() }
            }
            if item.notePath != nil {
                Button("Open Note") { onOpenNote() }
            }
        }
        .accessibilityActions {
            if isTextBearing {
                ForEach(Transform.allCases) { transform in
                    Button(transform.label) { onTransform(transform) }
                }
            }
            if item.kind == .link {
                Button("Show QR Code") { onShowQR() }
            }
            if extractedText != nil {
                Button("Copy Extracted Text") { onCopyExtractedText() }
            }
            Button("Copy Only") { onCopyOnly() }
        }
    }

    // MARK: Header band

    private var header: some View {
        HStack(spacing: Design.Space.normal) {
            if let icon = AppIconCache.icon(forBundleID: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: Design.Size.cardAppIcon, height: Design.Size.cardAppIcon)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: Design.Size.cardAppIcon, height: Design.Size.cardAppIcon)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(appName)
                    .font(Design.Typography.cardAppName)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                Text(item.createdAt, format: .relative(presentation: .named))
                    .font(Design.Typography.cardTime)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
            }

            Spacer(minLength: Design.Space.tight)

            headerTrailing
        }
        .padding(.horizontal, Design.Space.roomy)
        .padding(.vertical, Design.Space.snug)
        .frame(height: Design.Size.cardHeader)
        .background(Design.Palette.cardHeaderFill)
    }

    /// The header's trailing slot. At rest it carries the queue badge, the pin
    /// and the kind glyph; on hover or selection it becomes the pin/delete
    /// controls instead.
    ///
    /// Swapping in place rather than appearing beside them keeps the card's
    /// geometry fixed, and rendering for *selection* (not hover alone) is what
    /// keeps the controls reachable by keyboard, Full Keyboard Access and
    /// VoiceOver.
    @ViewBuilder
    private var headerTrailing: some View {
        if isHovering || isSelected {
            HStack(spacing: Design.Space.hair) {
                cardActionButton(
                    systemImage: item.isPinned ? "pin.slash" : "pin",
                    label: item.isPinned ? "Unpin" : "Pin",
                    action: togglePinned
                )
                cardActionButton(systemImage: "trash", label: "Delete", action: deleteItem)
            }
        } else {
            HStack(spacing: Design.Space.tight) {
                if let queuePosition {
                    Text("\(queuePosition)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        // Semantic pair: legible over every system accent,
                        // unlike a hardcoded white.
                        .foregroundStyle(Design.Palette.onAccent)
                        .frame(width: Design.Size.queueBadge, height: Design.Size.queueBadge)
                        .background(Circle().fill(Design.Palette.accent))
                        .help("Queued at position \(queuePosition)")
                }
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        // The system orange, which macOS retunes per
                        // appearance — plain `.orange` is the same washed-out
                        // hue on white.
                        .foregroundStyle(Design.Palette.pin)
                        // "pinned" is part of the card label.
                        .accessibilityHidden(true)
                }
                Image(systemName: kindSymbol)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .accessibilityHidden(true)
            }
        }
    }

    private func cardActionButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: Design.Size.rowActionButton, height: Design.Size.rowActionButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private var appName: String {
        let name = (item.sourceAppName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Unknown" : name
    }

    private var kindSymbol: String {
        if item.isScreenshot { return "camera.viewfinder" }
        switch item.kind {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
        case .color: return "paintpalette"
        }
    }

    // MARK: Content well

    private var contentWell: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            kindContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(spacing: Design.Space.snug) {
                Text(statLine)
                    .font(Design.Typography.cardStat)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                if let calc = calcSuffix {
                    // Weight and label colour, not the accent: accent text on
                    // this background measures ~3.5:1 and would fail AA here.
                    Text("= \(calc)")
                        .font(Design.Typography.cardStat.weight(.semibold))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .lineLimit(1)
                }
                Spacer(minLength: Design.Space.tight)
                if index < 9 {
                    // A keycap rather than grey text: it reads as a key you
                    // can press.
                    KeyCap(text: "⌘\(index + 1)")
                }
            }
        }
        .padding(Design.Space.roomy)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Design.Palette.cardContentFill)
    }

    @ViewBuilder
    private var kindContent: some View {
        switch item.kind {
        case .image:
            imageContent
        case .color:
            colorContent
        case .file:
            // A screenshot is a file clip that draws as its picture: the
            // thumbnail is already there (the backfill treats it as an
            // image), and a row showing only a path would waste it.
            if item.isScreenshot {
                imageContent
            } else {
                fileContent
            }
        default:
            Text(previewText)
                .font(.system(size: Design.Typography.cardBodySize))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(6)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        // Deliberately the THUMBNAIL, never `imageData`: SwiftData
        // materializes Data attributes on fetch, so reading the full blob
        // here costs the panel ~1.4 GB per 500 screenshots.
        if let data = item.thumbnailData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous))
                .accessibilityHidden(true)
        } else {
            placeholder("photo")
        }
    }

    @ViewBuilder
    private var colorContent: some View {
        RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
            .fill(colorFill)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                    .strokeBorder(Design.Palette.hairline, lineWidth: Design.Stroke.hairline)
            )
            .accessibilityHidden(true)
    }

    private var fileContent: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            ForEach(item.fileURLStrings.prefix(4), id: \.self) { urlString in
                HStack(spacing: Design.Space.snug) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: ClipDisplay.displayPath(urlString)))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(ClipDisplay.displayName(urlString))
                        .font(.system(size: Design.Typography.cardBodySize))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func placeholder(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .light))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var colorFill: Color {
        if let hex = item.colorHex, let nsColor = NSColor(hexString: hex) {
            return Color(nsColor: nsColor)
        }
        return .clear
    }

    // MARK: Text derivation

    /// What the card shows in its well. Bounded: a multi-megabyte clip must
    /// never be handed to a `Text` that only has room for six lines.
    private var previewText: String {
        String(summaryText.prefix(Self.previewPrefix))
    }

    private static let previewPrefix = 500

    private var summaryText: String {
        switch item.kind {
        case .file:
            return ClipDisplay.displayNames(item.fileURLStrings)
        case .color:
            return item.colorHex ?? ""
        default:
            return (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The card's closing stat line — Deck's "66 characters".
    ///
    /// "· noted" is the only confirmation ⌘S gets: the export runs off the
    /// key press so the panel stays live, and only failure interrupts with an
    /// alert. It is appended for every kind a note can be made from — not
    /// just screenshots, as it was — because the clip whose note went missing
    /// without a word was the pasted picture and the copied paragraph.
    ///
    /// It replaces "text found" rather than joining it: a clip that has been
    /// noted obviously had text in it, and a three-part stat line is a stat
    /// line that truncates on a narrow panel.
    private var statLine: String {
        let noted = item.notePath != nil
        // Checked before the kind switch: a screenshot IS a file clip, and
        // "1 file" is the least informative thing the row could say about it.
        if item.isScreenshot {
            if noted { return "Screenshot · noted" }
            if !(item.ocrText ?? "").isEmpty { return "Screenshot · text found" }
            return "Screenshot"
        }
        switch item.kind {
        case .file:
            let count = item.fileURLStrings.count
            return count == 1 ? "1 file" : "\(count) files"
        case .color:
            return item.colorHex ?? "Color"
        case .image:
            if noted { return "Image · noted" }
            if let ocr = item.ocrText, !ocr.isEmpty {
                return "Image · text found"
            }
            return "Image"
        default:
            let count = summaryText.count
            let characters = count == 1
                ? "1 character"
                : "\(count.formatted(.number.grouping(.automatic))) characters"
            return noted ? "\(characters) · noted" : characters
        }
    }

    /// The image clip's OCR text, or nil when there is none worth offering.
    private var extractedText: String? {
        ClipDisplay.extractedText(for: item)
    }

    /// Whether this clip has anything a note could be made of.
    ///
    /// Shared with the panel's ⌘S / `n` keys, which have to offer the action
    /// on exactly the clips this menu does.
    private var canSaveNote: Bool {
        ClipDisplay.canSaveNote(item)
    }

    /// Kinds that carry plain text — the only ones offered transforms.
    private var isTextBearing: Bool {
        ClipDisplay.isTextBearing(item.kind)
    }

    /// Identity of the card's *content*: re-running the calc scan when this
    /// changes (rather than every body pass) is the whole point.
    private var contentKey: String {
        "\(item.contentHash)-\(item.text?.count ?? 0)"
    }

    private func refreshCalc() async {
        let kind = item.kind
        let text = item.text
        let result = await Task.detached(priority: .utility) {
            ClipDisplay.calcResult(kind: kind, text: text)
        }.value
        guard !Task.isCancelled else { return }
        calcSuffix = result
    }

    // MARK: Accessibility

    private var accessibilityLabel: String {
        ClipDisplay.rowLabel(
            kind: item.kind,
            summary: summaryText,
            appName: item.sourceAppName,
            relativeTime: item.createdAt.formatted(.relative(presentation: .named)),
            isPinned: item.isPinned,
            queuePosition: queuePosition,
            hasExtractedText: !(item.ocrText ?? "").isEmpty,
            calcResult: calcSuffix,
            isScreenshot: item.isScreenshot,
            hasNote: item.notePath != nil
        )
    }

    // MARK: Selection presentation

    /// Deck draws selection as a neutral outline and nothing else. MemoryClip keeps
    /// the outline — it is the cue that survives greyscale — *and* adds an
    /// accent wash, because outline-only selection sits too close to MemoryClip's
    /// hover treatment to be read at a glance.
    @ViewBuilder
    private var selectionOutline: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(
                    Design.Palette.cardSelectedBorder(increasedContrast: contrast == .increased),
                    lineWidth: 2
                )
                .accessibilityHidden(true)
        }
    }

    private var wash: Color {
        let increased = contrast == .increased
        if isSelected {
            return Design.Palette.cardSelectedTint(increasedContrast: increased)
        }
        if isHovering {
            return Design.Palette.cardHover(increasedContrast: increased)
        }
        return .clear
    }

    // MARK: Mutations

    private func togglePinned() {
        item.isPinned.toggle()
        try? modelContext.save()
    }

    private func deleteItem() {
        modelContext.delete(item)
        try? modelContext.save()
    }
}
