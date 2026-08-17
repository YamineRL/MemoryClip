import SwiftUI
import SwiftData
import AppKit

/// Pure, view-independent display logic shared by `ClipCardView` and
/// `PreviewView`: the instant-calc gate, VoiceOver label composition,
/// summary/preview truncation and file-URL prettifying.
///
/// Deliberately nonisolated and free of SwiftData/SwiftUI types so it can be
/// unit-tested directly and evaluated off the main actor.
enum ClipDisplay {
    /// Kinds that carry plain text — the only ones offered transforms, and
    /// the only ones instant-calc looks at.
    static func isTextBearing(_ kind: ClipKind) -> Bool {
        kind == .text || kind == .richText || kind == .link
    }

    /// Instant-calc result for a clip ("12*7" → "84"), or nil when the clip
    /// is not text-bearing, does not evaluate, or would just echo itself.
    ///
    /// This is the single gate used by BOTH the row and the preview; they
    /// used to disagree about `.richText`.
    static func calcResult(kind: ClipKind, text: String?) -> String? {
        guard isTextBearing(kind), let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = CalcEvaluator.evaluate(trimmed) else { return nil }
        let formatted = CalcEvaluator.format(value)
        return formatted == trimmed ? nil : formatted
    }

    // MARK: - Notes

    /// The image clip's OCR text, or nil when there is none worth offering.
    /// Whitespace-only Vision output counts as none.
    ///
    /// Screenshot clips qualify as well as pasteboard images: their kind is
    /// `.file` (they reference the picture on disk) but they carry pixels and
    /// go through the same recognition.
    static func extractedText(for item: some ClipDisplayable) -> String? {
        guard item.kind == .image || item.isScreenshot else { return nil }
        let trimmed = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether this clip has anything a note could be made of.
    ///
    /// Text-bearing clips qualify on their own text; images and screenshots
    /// qualify once recognition has found something. A colour swatch or an
    /// unreadable screenshot has nothing to write down, so the action is not
    /// offered rather than being offered and failing.
    ///
    /// It lives here rather than on the card because two paths now ask the
    /// question and they answer it differently in the UI: the context menu
    /// omits the item, while a key press has no menu to omit and can only
    /// decline silently. A copy in each would eventually drift, and the
    /// symptom would be a key that looks dead on clips the menu still offers.
    static func canSaveNote(_ item: some ClipDisplayable) -> Bool {
        if extractedText(for: item) != nil { return true }
        guard isTextBearing(item.kind) else { return false }
        return !(item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - File URLs

    /// A human-readable POSIX path for a stored file-URL string.
    /// `fileURLStrings` holds `URL.absoluteString`, so a name with spaces is
    /// stored percent-encoded (`file:///Users/me/my%20file.txt`).
    static func displayPath(_ urlString: String) -> String {
        if let url = URL(string: urlString), url.isFileURL {
            return url.path(percentEncoded: false)
        }
        return urlString.removingPercentEncoding ?? urlString
    }

    /// The last path component of `displayPath(_:)` — "my file.txt".
    ///
    /// Note that this decodes FIRST and takes the component after: doing it
    /// the other way round — `(urlString as NSString).lastPathComponent` —
    /// hands back "my%20file.txt", which is the percent-encoding leaking into
    /// the UI that this helper exists to prevent.
    static func displayName(_ urlString: String) -> String {
        (displayPath(urlString) as NSString).lastPathComponent
    }

    /// Every stored file URL as a comma-separated list of names — the one
    /// line a card, a dropdown row and a VoiceOver announcement all use to
    /// say what a file clip holds.
    ///
    /// Shared rather than repeated at those three call sites because the
    /// repetition is exactly how two of them came to be spelled
    /// `($0 as NSString).lastPathComponent` and show encoded names while the
    /// third does not.
    static func displayNames(_ urlStrings: [String]) -> String {
        urlStrings.map(displayName).joined(separator: ", ")
    }

    /// Whether a search term matches this clip's file URLs.
    ///
    /// Matched against the decoded path, so that what the user types is what
    /// they see in the row: searching "my file" has to find `my%20file.txt`,
    /// and a search in Arabic has to find a file named in Arabic, whose
    /// stored form is a run of `%D8%…` containing not one typed character.
    static func fileURLsMatch(_ urlStrings: [String], search: String) -> Bool {
        urlStrings.contains { displayPath($0).localizedStandardContains(search) }
    }

    // Everything above is for `.file` clips only. A `.link` clip is shown
    // verbatim, and deliberately so: it holds the text the user copied,
    // MemoryClip never encoded it, and there is therefore no encoding of its
    // own to undo. Decoding one anyway would change its meaning rather than
    // tidy it — `%26` and `%2F` inside a query parameter are data, and turning
    // them into `&` and `/` yields a different URL that no longer opens what
    // was copied. It is also how a hostile link disguises where it goes, so
    // the honest thing to show is the address that would actually be visited.

    // MARK: - Truncation

    /// Longest summary VoiceOver is given before it is cut short.
    static let summaryLimit = 120
    /// Longest text the preview pane hands to a single `Text`.
    static let previewLimit = 100_000

    /// A one-line, length-bounded version of `text` for a spoken label.
    /// Newlines and runs of whitespace collapse to single spaces; anything
    /// past `limit` characters is dropped and replaced with a count, so a
    /// 4000-character clip does not get read out in full.
    static func spokenSummary(_ text: String, limit: Int = summaryLimit) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let head = String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return loc("%@… %d characters", head, collapsed.count)
    }

    /// The preview body: at most `limit` characters, plus a note when the
    /// text was cut. Keeps a 100MB clip from being handed to one `Text`.
    static func previewBody(_ text: String, limit: Int = previewLimit) -> (text: String, notice: String?) {
        guard text.count > limit else { return (text, nil) }
        let shown = String(text.prefix(limit))
        let notice = loc("Showing the first %@ of %@ characters.", formatted(limit), formatted(text.count))
        return (shown, notice)
    }

    private static func formatted(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    // MARK: - Accessibility label

    /// Spoken name of a clip kind.
    ///
    /// A screenshot is stored as a `.file` clip holding a reference to the
    /// image on disk, but calling it "File" tells the listener nothing about
    /// what it is — the whole point of the flag is that this one is a picture
    /// of their screen.
    static func kindLabel(_ kind: ClipKind, isScreenshot: Bool = false) -> String {
        if isScreenshot { return loc("Screenshot") }
        switch kind {
        case .text: return loc("Text")
        case .richText: return loc("Rich text")
        case .image: return loc("Image")
        case .file: return loc("File")
        case .link: return loc("Link")
        case .color: return loc("Color")
        }
    }

    /// The composed VoiceOver label for one clip card, e.g.
    /// "Text, hello world, from Safari, 2 minutes ago, pinned,
    ///  queued position 2, contains extracted text, saved as a note".
    ///
    /// `summary` is truncated by `spokenSummary(_:)`; empty parts are skipped.
    static func rowLabel(
        kind: ClipKind,
        summary: String,
        appName: String?,
        relativeTime: String,
        isPinned: Bool = false,
        queuePosition: Int? = nil,
        hasExtractedText: Bool = false,
        calcResult: String? = nil,
        isScreenshot: Bool = false,
        hasNote: Bool = false
    ) -> String {
        var parts: [String] = [kindLabel(kind, isScreenshot: isScreenshot)]

        let spoken = spokenSummary(summary)
        if !spoken.isEmpty { parts.append(spoken) }
        if let calcResult { parts.append(loc("equals %@", calcResult)) }
        if let appName, !appName.isEmpty { parts.append(loc("from %@", appName)) }
        if !relativeTime.isEmpty { parts.append(relativeTime) }
        if isPinned { parts.append(loc("pinned")) }
        if let queuePosition { parts.append(loc("queued position %d", queuePosition)) }
        if hasExtractedText { parts.append(loc("contains extracted text")) }
        if hasNote { parts.append(loc("saved as a note")) }

        return parts.joined(separator: ", ")
    }
}
