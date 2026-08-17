import AppKit

/// One "Copy …" entry in the preview pane's context menu.
struct PreviewCopyOption: Equatable, Identifiable {
    /// Menu title.
    let title: String
    /// What lands on the pasteboard.
    let text: String

    var id: String { title }
}

/// What the preview pane's right-click menu offers, and what a chosen entry
/// does.
enum PreviewCopy {
    /// The copy entries for one clip, in menu order: the previewed body
    /// first, then the translation on screen, then the file paths and names.
    ///
    /// Pure and view-free so it can be tested directly.
    static func options(
        for item: some ClipDisplayable,
        translation: String? = nil
    ) -> [PreviewCopyOption] {
        var options: [PreviewCopyOption] = []

        if item.kind == .image || item.isScreenshot {
            if let extracted = ClipDisplay.extractedText(for: item) {
                options.append(PreviewCopyOption(title: "Copy Extracted Text", text: extracted))
            }
        } else {
            switch item.kind {
            case .text, .richText, .link:
                if let text = present(item.text) {
                    options.append(PreviewCopyOption(title: "Copy Text", text: text))
                }
            case .color:
                if let hex = present(item.colorHex) {
                    options.append(PreviewCopyOption(title: "Copy Hex", text: hex))
                }
            case .image, .file:
                break
            }
        }

        if let translation = present(translation) {
            options.append(PreviewCopyOption(title: "Copy Translation", text: translation))
        }

        // Decoded, never `URL.absoluteString`: what goes on the pasteboard is
        // the path the user is reading, not `my%20file.txt`.
        let paths = item.fileURLStrings.map(ClipDisplay.displayPath)
        if item.kind == .file, !paths.isEmpty {
            options.append(PreviewCopyOption(
                title: paths.count == 1 ? "Copy File Path" : "Copy File Paths",
                text: paths.joined(separator: "\n")
            ))
            options.append(PreviewCopyOption(
                title: paths.count == 1 ? "Copy File Name" : "Copy File Names",
                text: ClipDisplay.displayNames(item.fileURLStrings)
            ))
        }

        return options
    }

    /// The string when it has something in it, nil when it is absent or blank.
    private static func present(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Put an option's text on the pasteboard through `onCopy`, which routes
    /// to the app's own copy path so the write is not read back as a new clip.
    ///
    /// Writes the pasteboard directly when absent (SwiftUI previews, tests).
    static func perform(_ option: PreviewCopyOption, using onCopy: ((String) -> Void)?) {
        guard let onCopy else {
            PasteService.Payload(entries: [.string(.string, option.text)]).apply(to: .general)
            return
        }
        onCopy(option.text)
    }
}
