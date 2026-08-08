import SwiftUI
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

    /// Design sizes that follow the system text-size setting instead of
    /// being frozen at their point value.
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = Design.Typography.previewBodySize
    @ScaledMetric(relativeTo: .title2) private var calcFontSize: CGFloat = Design.Typography.calcResultSize

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.roomy) {
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
        guard item.kind == .image, let data = item.imageData, !data.isEmpty else { return }
        guard !Task.isCancelled else { return }
        fullImage = NSImage(data: data)
    }

    // MARK: Content by kind

    @ViewBuilder
    private var content: some View {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous))
            } else {
                emptyPlaceholder
            }

            if let extracted = extractedText {
                Divider()
                VStack(alignment: .leading, spacing: Design.Space.snug) {
                    Text("Extracted Text")
                        .font(Design.Typography.meta)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    ScrollView {
                        Text(extracted)
                            .font(.system(size: bodyFontSize))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Bounded so a text-heavy screenshot cannot squeeze the image
                // out of the pane entirely.
                .frame(maxHeight: Design.Size.previewExtractedTextHeight)
            }
        }
    }

    /// The image clip's OCR text, or nil when Vision found nothing usable.
    private var extractedText: String? {
        guard item.kind == .image else { return nil }
        let trimmed = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
