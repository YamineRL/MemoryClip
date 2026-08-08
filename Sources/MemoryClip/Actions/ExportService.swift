import Foundation

/// A flat, serialization-friendly snapshot of a `ClipItem`.
///
/// The SwiftData model is mapped to this record before export, so this layer
/// stays free of any SwiftData dependency. Binary payloads are carried as
/// Base64 strings; `richTextBase64` and `imageBase64` are JSON-only — the CSV
/// format intentionally excludes them (see `ExportService.csv(from:)`).
struct ClipExport: Codable, Sendable {
    var kind: String            // ClipKind.rawValue
    var text: String?
    var colorHex: String?
    var fileURLs: [String]
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var createdAt: Date
    var lastUsedAt: Date?
    var isPinned: Bool
    // NOTE: richTextData/imageData are intentionally omitted from CSV;
    // they travel as Base64 in JSON ONLY (kept out of the CSV columns below).
    var richTextBase64: String? // JSON-only field; excluded from CSV columns
    var imageBase64: String?    // JSON-only field; excluded from CSV columns
}

/// Serializes clip history to JSON or CSV.
///
/// Pure functions only — no UI, no SwiftData, no pasteboard access. Dates are
/// rendered as whole-second ISO 8601 strings (`2026-08-07T12:34:56Z`) in both
/// formats; sub-second precision is deliberately dropped so JSON and CSV agree.
enum ExportService {
    /// Errors thrown while producing an export string.
    enum ExportError: Error {
        /// The encoder produced data that could not be interpreted as UTF-8.
        case utf8EncodingFailed
    }

    // MARK: Mapping

    /// Flatten a stored clip into its export record.
    ///
    /// Kept here (rather than inline at the call site) so the field-by-field
    /// mapping — which is easy to get subtly wrong, e.g. swapping bundle id
    /// and app name — is covered by tests.
    static func export(from item: ClipItem) -> ClipExport {
        ClipExport(
            kind: item.kind.rawValue,
            text: item.text,
            colorHex: item.colorHex,
            fileURLs: item.fileURLStrings,
            sourceAppBundleID: item.sourceBundleID,
            sourceAppName: item.sourceAppName,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned,
            richTextBase64: Self.base64(item.richTextData),
            imageBase64: Self.base64(item.imageData)
        )
    }

    /// Base64 for a payload, treating empty as absent.
    ///
    /// `imageData` carries `@Attribute(.externalStorage)`. Rows written before
    /// that attribute existed, whose column was NULL, read back through the
    /// external-storage accessor as an EMPTY `Data` rather than `nil` — so a
    /// plain `?.base64EncodedString()` would emit `""` for every pre-existing
    /// text clip instead of `null`. Every other consumer already guards with
    /// `!isEmpty`; this keeps the export format honest too.
    private static func base64(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        return data.base64EncodedString()
    }

    /// Flatten a history, preserving order.
    static func exports(from items: [ClipItem]) -> [ClipExport] {
        items.map(export(from:))
    }

    /// The CSV header row, in exact column order.
    static let csvHeader = [
        "kind",
        "text",
        "colorHex",
        "fileURLs",
        "sourceAppName",
        "createdAt",
        "lastUsedAt",
        "isPinned",
    ].joined(separator: ",")

    // MARK: Streaming

    /// Emits an export document one clip at a time.
    ///
    /// Building the whole document first is an out-of-memory risk: 500 image
    /// clips (642 MB of blobs) become ~856 MB of Base64 strings, all live at
    /// once, plus the encoded document on top. A caller that fetches clips in
    /// pages and appends each `chunk` to a file never holds more than one page.
    ///
    /// The output is byte-identical to `json(from:)` / `csv(from:)` — those
    /// are implemented on top of this type so the two cannot drift apart.
    struct Stream {
        enum Format { case json, csv }

        let format: Format
        private var wroteAny = false
        private let encoder: JSONEncoder
        private let dateFormatter = ISO8601DateFormatter()

        init(format: Format) {
            self.format = format
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            self.encoder = encoder
        }

        /// Text to write before any clip: the CSV header row, nothing for JSON
        /// (whose opening bracket rides along with the first record so an
        /// empty export can still be the canonical `[]`).
        var header: String {
            switch format {
            case .json: return ""
            case .csv: return csvHeader
            }
        }

        /// Text for the next clip, including whatever separator precedes it.
        mutating func chunk(for clip: ClipExport) throws -> String {
            defer { wroteAny = true }
            switch format {
            case .json:
                let data = try encoder.encode(clip)
                guard let object = String(data: data, encoding: .utf8) else {
                    throw ExportError.utf8EncodingFailed
                }
                // Objects nested in a pretty-printed array carry one extra
                // level of indentation.
                let indented = object
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "  " + $0 }
                    .joined(separator: "\n")
                return (wroteAny ? ",\n" : "[\n") + indented
            case .csv:
                let fields = [
                    clip.kind,
                    clip.text ?? "",
                    clip.colorHex ?? "",
                    clip.fileURLs.joined(separator: "; "),
                    clip.sourceAppName ?? "",
                    dateFormatter.string(from: clip.createdAt),
                    clip.lastUsedAt.map(dateFormatter.string(from:)) ?? "",
                    clip.isPinned ? "true" : "false",
                ]
                return "\n" + fields.map { csvEscaped(csvDefused($0)) }.joined(separator: ",")
            }
        }

        /// Text closing the document.
        var footer: String {
            switch format {
            // The pretty-printing encoder renders an empty array as "[\n\n]";
            // emit the canonical compact form instead.
            case .json: return wroteAny ? "\n]" : "[]"
            case .csv: return ""
            }
        }
    }

    /// Render a whole batch through `Stream`, for callers small enough not to
    /// care (tests, and the in-memory `json`/`csv` entry points).
    static func document(from clips: [ClipExport], format: Stream.Format) throws -> String {
        var stream = Stream(format: format)
        var output = stream.header
        for clip in clips {
            output += try stream.chunk(for: clip)
        }
        return output + stream.footer
    }

    // MARK: JSON

    /// Pretty-printed JSON with stable (alphabetically sorted) keys and
    /// ISO 8601 dates. Includes `richTextBase64` / `imageBase64` when present.
    static func json(from clips: [ClipExport]) throws -> String {
        try document(from: clips, format: .json)
    }

    // MARK: CSV

    /// RFC-4180-ish CSV: header row, records separated by `\n`, fields
    /// containing comma/quote/newline wrapped in double quotes with internal
    /// quotes doubled. Columns match `csvHeader`; binary payloads are omitted.
    /// `nil` optional fields become empty columns; full text is emitted
    /// (never truncated).
    static func csv(from clips: [ClipExport]) -> String {
        // The CSV branch of `Stream.chunk` cannot throw (only the JSON
        // encoder can), so this stays non-throwing.
        (try? document(from: clips, format: .csv)) ?? csvHeader
    }

    /// Leading characters that make Excel / Numbers / LibreOffice treat a
    /// cell as a formula rather than text.
    static let formulaTriggers: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// Neutralise CSV formula injection: a clip such as `=HYPERLINK("http://evil")`
    /// would otherwise execute when the export is opened in a spreadsheet.
    /// Prefixing with an apostrophe forces the cell to be read as text.
    /// (Side effect: a field like `-5` exports as `'-5`.)
    static func csvDefused(_ field: String) -> String {
        guard let first = field.first, formulaTriggers.contains(first) else { return field }
        return "'" + field
    }

    /// Quote a CSV field when it contains a comma, double quote, CR or LF;
    /// double any embedded quotes per RFC 4180.
    static func csvEscaped(_ field: String) -> String {
        let needsQuoting = field.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
