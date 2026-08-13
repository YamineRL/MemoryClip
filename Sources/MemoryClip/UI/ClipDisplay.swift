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
    static func displayName(_ urlString: String) -> String {
        (displayPath(urlString) as NSString).lastPathComponent
    }

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
        return "\(head)… \(collapsed.count) characters"
    }

    /// The preview body: at most `limit` characters, plus a note when the
    /// text was cut. Keeps a 100MB clip from being handed to one `Text`.
    static func previewBody(_ text: String, limit: Int = previewLimit) -> (text: String, notice: String?) {
        guard text.count > limit else { return (text, nil) }
        let shown = String(text.prefix(limit))
        let notice = "Showing the first \(formatted(limit)) of \(formatted(text.count)) characters."
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
        if isScreenshot { return "Screenshot" }
        switch kind {
        case .text: return "Text"
        case .richText: return "Rich text"
        case .image: return "Image"
        case .file: return "File"
        case .link: return "Link"
        case .color: return "Color"
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
        if let calcResult { parts.append("equals \(calcResult)") }
        if let appName, !appName.isEmpty { parts.append("from \(appName)") }
        if !relativeTime.isEmpty { parts.append(relativeTime) }
        if isPinned { parts.append("pinned") }
        if let queuePosition { parts.append("queued position \(queuePosition)") }
        if hasExtractedText { parts.append("contains extracted text") }
        if hasNote { parts.append("saved as a note") }

        return parts.joined(separator: ", ")
    }
}
