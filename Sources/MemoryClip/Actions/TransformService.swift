import Foundation

/// Text transforms offered on captured clips (Phase-2 "text transformations").
///
/// Pure value type — safe to enumerate from any context (menus, previews,
/// keyboard-shortcut rows). `appliesToPlainText` is true for every case;
/// applicability is decided at run time by `TransformService.apply`,
/// which returns `nil` when a transform cannot be applied.
enum Transform: String, CaseIterable, Identifiable, Sendable {
    case uppercased, lowercased, titleCase
    case jsonFormat, jsonMinify
    case base64Encode, base64Decode
    case urlEncode, urlDecode
    case sortLines, dedupeLines

    var id: String { rawValue }

    /// Human-readable label for menus / quick-action rows.
    var label: String {
        switch self {
        case .uppercased: "UPPERCASE"
        case .lowercased: "lowercase"
        case .titleCase: "Title Case"
        case .jsonFormat: "Format JSON"
        case .jsonMinify: "Minify JSON"
        case .base64Encode: "Base64 Encode"
        case .base64Decode: "Base64 Decode"
        case .urlEncode: "URL Encode"
        case .urlDecode: "URL Decode"
        case .sortLines: "Sort Lines"
        case .dedupeLines: "Deduplicate Lines"
        }
    }

    /// Every transform can be *offered* for plain text; `apply` decides
    /// at run time whether it actually succeeds.
    var appliesToPlainText: Bool { true }
}

/// Applies `Transform`s to plain text. Foundation-only, no UI, no state —
/// safe to call from any concurrency context.
enum TransformService {
    /// Apply the transform, or return `nil` when it is inapplicable
    /// (invalid JSON, invalid Base64, undecodable percent-escapes, …).
    static func apply(_ transform: Transform, to text: String) -> String? {
        switch transform {
        case .uppercased: return text.uppercased()
        case .lowercased: return text.lowercased()
        case .titleCase: return titleCase(text)
        case .jsonFormat: return reformatJSON(text, pretty: true)
        case .jsonMinify: return reformatJSON(text, pretty: false)
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode: return base64Decode(text)
        case .urlEncode: return text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        case .urlDecode: return text.removingPercentEncoding
        case .sortLines: return sortLines(text)
        case .dedupeLines: return dedupeLines(text)
        }
    }

    // MARK: - Individual transforms

    /// Capitalize the first letter of each whitespace-separated word.
    private static func titleCase(_ text: String) -> String {
        (text as NSString).capitalized
    }

    /// Parse as JSON (any fragment JSONSerialization accepts) and re-emit it.
    /// `pretty` uses `.prettyPrinted`; both variants sort keys and keep
    /// slashes unescaped for a stable, readable round-trip.
    private static func reformatJSON(_ text: String, pretty: Bool) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else { return nil }

        var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let output = try? JSONSerialization.data(withJSONObject: object, options: options) else {
            return nil
        }
        return String(data: output, encoding: .utf8)
    }

    /// Strict Base64 decode: rejects invalid characters / lengths, and the
    /// payload must be valid UTF-8 text (clipboard transforms are text-in/text-out).
    private static func base64Decode(_ text: String) -> String? {
        guard let data = Data(base64Encoded: text),
              let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        return decoded
    }

    /// Split into lines (CRLF is normalised to LF; all lines are kept,
    /// including empty ones), sort case-insensitively, rejoin with "\n".
    private static func sortLines(_ text: String) -> String {
        lines(in: text)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .joined(separator: "\n")
    }

    /// Drop exact (case-sensitive) duplicate lines, preserving the first
    /// occurrence of each line.
    private static func dedupeLines(_ text: String) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for line in lines(in: text) where seen.insert(line).inserted {
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Line splitter shared by the line-oriented transforms.
    private static func lines(in text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }
}
