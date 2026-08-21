import AppKit
import Foundation

/// Text transforms offered on captured clips (Phase-2 "text transformations").
///
/// Pure value type — safe to enumerate from any context (menus, previews,
/// keyboard-shortcut rows). `appliesToPlainText` is true for every case;
/// applicability is decided at run time by `TransformService.apply`,
/// which returns `nil` when a transform cannot be applied.
enum Transform: String, CaseIterable, Identifiable, Sendable {
    case uppercased, lowercased, titleCase
    case snakeCase, camelCase, kebabCase, screamingSnakeCase
    case jsonFormat, jsonMinify
    case base64Encode, base64Decode
    case urlEncode, urlDecode
    case hexColor, rgbColor, hslColor
    case epochToDate, dateToEpoch
    case trimLines, stripTrailingSpace, collapseBlankLines
    case sortLines, dedupeLines, reverseLines, numberLines

    var id: String { rawValue }

    /// Human-readable label for menus / quick-action rows.
    ///
    /// The case-style rows name themselves in the style they produce, the way
    /// "UPPERCASE" and "lowercase" do: the label is the example.
    var label: String {
        switch self {
        case .uppercased: "UPPERCASE"
        case .lowercased: "lowercase"
        case .titleCase: loc("Title Case")
        case .snakeCase: loc("snake_case")
        case .camelCase: loc("camelCase")
        case .kebabCase: loc("kebab-case")
        case .screamingSnakeCase: loc("SCREAMING_SNAKE_CASE")
        case .jsonFormat: loc("Format JSON")
        case .jsonMinify: loc("Minify JSON")
        case .base64Encode: loc("Base64 Encode")
        case .base64Decode: loc("Base64 Decode")
        case .urlEncode: loc("URL Encode")
        case .urlDecode: loc("URL Decode")
        case .hexColor: loc("Color to Hex")
        case .rgbColor: loc("Color to RGB")
        case .hslColor: loc("Color to HSL")
        case .epochToDate: loc("Timestamp to Date")
        case .dateToEpoch: loc("Date to Timestamp")
        case .trimLines: loc("Trim Lines")
        case .stripTrailingSpace: loc("Strip Trailing Whitespace")
        case .collapseBlankLines: loc("Collapse Blank Lines")
        case .sortLines: loc("Sort Lines")
        case .dedupeLines: loc("Deduplicate Lines")
        case .reverseLines: loc("Reverse Lines")
        case .numberLines: loc("Number Lines")
        }
    }

    /// Every transform can be *offered* for plain text; `apply` decides
    /// at run time whether it actually succeeds.
    var appliesToPlainText: Bool { true }

    /// The submenu this transform is filed under.
    var group: TransformGroup {
        switch self {
        case .uppercased, .lowercased, .titleCase,
             .snakeCase, .camelCase, .kebabCase, .screamingSnakeCase: .caseStyle
        case .jsonFormat, .jsonMinify: .json
        case .base64Encode, .base64Decode, .urlEncode, .urlDecode: .encoding
        case .hexColor, .rgbColor, .hslColor: .color
        case .epochToDate, .dateToEpoch: .time
        case .trimLines, .stripTrailingSpace, .collapseBlankLines,
             .sortLines, .dedupeLines, .reverseLines, .numberLines: .lines
        }
    }
}

/// The submenus `Transform` is presented in.
///
/// A flat list of every case is longer than the panel is tall, and a menu that
/// has to be scrolled is one whose last rows are never read. The groups are the
/// question a clip raises — what case is this, what encoding, what colour —
/// rather than the order the cases happen to be declared in.
enum TransformGroup: String, CaseIterable, Identifiable, Sendable {
    case caseStyle, json, encoding, color, time, lines

    var id: String { rawValue }

    var label: String {
        switch self {
        case .caseStyle: loc("Case")
        case .json: loc("JSON")
        case .encoding: loc("Encoding")
        case .color: loc("Color")
        case .time: loc("Time")
        case .lines: loc("Lines")
        }
    }

    /// The cases filed here, in declaration order.
    var transforms: [Transform] {
        Transform.allCases.filter { $0.group == self }
    }
}

/// Applies `Transform`s to plain text. No UI, no state — safe to call from any
/// concurrency context. AppKit enters only for `NSColor(hexString:)`, which is
/// the one hex parser in the app and stays the one hex parser.
enum TransformService {
    /// Apply the transform, or return `nil` when it is inapplicable
    /// (invalid JSON, invalid Base64, undecodable percent-escapes, text that
    /// is not a colour, a timestamp that is not a number, …).
    static func apply(_ transform: Transform, to text: String) -> String? {
        switch transform {
        case .uppercased: return text.uppercased()
        case .lowercased: return text.lowercased()
        case .titleCase: return titleCase(text)
        case .snakeCase: return recased(text, separator: "_")
        case .camelCase: return camelCased(text)
        case .kebabCase: return recased(text, separator: "-")
        case .screamingSnakeCase: return recased(text, separator: "_")?.uppercased()
        case .jsonFormat: return reformatJSON(text, pretty: true)
        case .jsonMinify: return reformatJSON(text, pretty: false)
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode: return base64Decode(text)
        case .urlEncode: return text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        case .urlDecode: return text.removingPercentEncoding
        case .hexColor: return parseColor(text).map(hexString)
        case .rgbColor: return parseColor(text).map(rgbString)
        case .hslColor: return parseColor(text).map(hslString)
        case .epochToDate: return epochToDate(text)
        case .dateToEpoch: return dateToEpoch(text)
        case .trimLines: return trimLines(text)
        case .stripTrailingSpace: return stripTrailingSpace(text)
        case .collapseBlankLines: return collapseBlankLines(text)
        case .sortLines: return sortLines(text)
        case .dedupeLines: return dedupeLines(text)
        case .reverseLines: return reverseLines(text)
        case .numberLines: return numberLines(text)
        }
    }

    // MARK: - Case transforms

    /// Capitalize the first letter of each whitespace-separated word.
    private static func titleCase(_ text: String) -> String {
        (text as NSString).capitalized
    }

    /// The words of an identifier, lowercased.
    ///
    /// Delimiters (anything that is not a letter or a digit) and case
    /// boundaries both split, so every case style re-joins from the same list
    /// whichever style it was handed — that is what makes snake → camel →
    /// snake come back to where it started.
    private static func caseWords(in text: String) -> [String] {
        let characters = Array(text)
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
                continue
            }
            if !current.isEmpty && startsWord(at: index, in: characters) {
                words.append(current.lowercased())
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    /// True at a case boundary inside an unbroken run: "clipID" splits before
    /// "ID", "HTTPServer" before "Server", "utf8Text" before "Text".
    ///
    /// Only called with a non-empty word in hand, so `index - 1` is a letter or
    /// a digit rather than a delimiter or the start of the string.
    private static func startsWord(at index: Int, in characters: [Character]) -> Bool {
        guard characters[index].isUppercase else { return false }
        let previous = characters[index - 1]
        if previous.isLowercase || previous.isNumber { return true }
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        return previous.isUppercase && next?.isLowercase == true
    }

    /// Re-join the words with `separator`, or `nil` when the text carries no
    /// word to re-join (punctuation, whitespace, an empty clip).
    private static func recased(_ text: String, separator: String) -> String? {
        let words = caseWords(in: text)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: separator)
    }

    private static func camelCased(_ text: String) -> String? {
        let words = caseWords(in: text)
        guard let first = words.first else { return nil }
        return first + words.dropFirst().map(\.capitalized).joined()
    }

    // MARK: - JSON

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

    // MARK: - Colors

    /// sRGB channels in 0...1: the currency every colour transform converts
    /// through, so each notation only has to be read and written once.
    private struct ColorComponents {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    /// Read `#RRGGBB[AA]`, `rgb()`/`rgba()` or `hsl()`/`hsla()`.
    ///
    /// The `#` is required on hex, as it is in `ContentParser.hexColor`:
    /// without it every six-digit number in the history would be a colour.
    private static func parseColor(_ text: String) -> ColorComponents? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let functional = parseFunctionalColor(trimmed) { return functional }
        guard trimmed.hasPrefix("#"),
              let color = NSColor(hexString: trimmed)?.usingColorSpace(.sRGB)
        else { return nil }
        return ColorComponents(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }

    private static func parseFunctionalColor(_ text: String) -> ColorComponents? {
        guard let call = functionCall(text) else { return nil }
        switch call.name {
        case "rgb", "rgba": return parseRGB(call.arguments)
        case "hsl", "hsla": return parseHSL(call.arguments)
        default: return nil
        }
    }

    /// `name(a, b, c)` split into its lowercased name and trimmed arguments.
    private static func functionCall(_ text: String) -> (name: String, arguments: [String])? {
        guard text.hasSuffix(")"), let open = text.firstIndex(of: "(") else { return nil }
        let close = text.index(before: text.endIndex)
        guard open < close else { return nil }
        let arguments = text[text.index(after: open)..<close]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (text[text.startIndex..<open].lowercased(), arguments)
    }

    private static func parseRGB(_ arguments: [String]) -> ColorComponents? {
        guard (3...4).contains(arguments.count),
              let red = channelValue(arguments[0]),
              let green = channelValue(arguments[1]),
              let blue = channelValue(arguments[2]),
              let alpha = alphaValue(arguments.count == 4 ? arguments[3] : "1")
        else { return nil }
        return ColorComponents(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func parseHSL(_ arguments: [String]) -> ColorComponents? {
        guard (3...4).contains(arguments.count),
              let degrees = number(arguments[0]),
              let saturation = alphaValue(arguments[1], scale: 100),
              let lightness = alphaValue(arguments[2], scale: 100),
              let alpha = alphaValue(arguments.count == 4 ? arguments[3] : "1")
        else { return nil }
        let hue = degrees.truncatingRemainder(dividingBy: 360)
        var color = hslToRGB(hue: hue < 0 ? hue + 360 : hue, saturation: saturation, lightness: lightness)
        color.alpha = alpha
        return color
    }

    /// A `rgb()` channel: 0...255, or a percentage of it.
    private static func channelValue(_ text: String) -> Double? {
        guard let value = number(text.hasSuffix("%") ? String(text.dropLast()) : text) else { return nil }
        return clamped(text.hasSuffix("%") ? value / 100 : value / 255)
    }

    /// A 0...1 channel written either as a fraction or as a percentage;
    /// `scale` is what a bare number is divided by (1 for alpha, 100 for the
    /// `hsl()` percentages, which CSS writes with a `%` and people paste without).
    private static func alphaValue(_ text: String, scale: Double = 1) -> Double? {
        guard let value = number(text.hasSuffix("%") ? String(text.dropLast()) : text) else { return nil }
        return clamped(text.hasSuffix("%") ? value / 100 : value / scale)
    }

    /// A finite decimal, and nothing else: `Double` alone would accept "nan",
    /// "inf" and hex float literals as colour channels.
    private static func number(_ text: String) -> Double? {
        guard !text.isEmpty,
              text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }),
              let value = Double(text), value.isFinite
        else { return nil }
        return value
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> ColorComponents {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let second = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let match = lightness - chroma / 2
        let channels: (Double, Double, Double)
        switch hue {
        case ..<60: channels = (chroma, second, 0)
        case ..<120: channels = (second, chroma, 0)
        case ..<180: channels = (0, chroma, second)
        case ..<240: channels = (0, second, chroma)
        case ..<300: channels = (second, 0, chroma)
        default: channels = (chroma, 0, second)
        }
        return ColorComponents(
            red: channels.0 + match,
            green: channels.1 + match,
            blue: channels.2 + match,
            alpha: 1
        )
    }

    /// Hue in degrees, saturation and lightness in 0...1.
    private static func rgbToHSL(_ color: ColorComponents) -> (hue: Double, saturation: Double, lightness: Double) {
        let highest = max(color.red, color.green, color.blue)
        let lowest = min(color.red, color.green, color.blue)
        let lightness = (highest + lowest) / 2
        let chroma = highest - lowest
        guard chroma > 0 else { return (0, 0, lightness) }

        let saturation = chroma / (1 - abs(2 * lightness - 1))
        let hue: Double
        if highest == color.red {
            let sixths = ((color.green - color.blue) / chroma).truncatingRemainder(dividingBy: 6)
            hue = 60 * (sixths < 0 ? sixths + 6 : sixths)
        } else if highest == color.green {
            hue = 60 * ((color.blue - color.red) / chroma + 2)
        } else {
            hue = 60 * ((color.red - color.green) / chroma + 4)
        }
        return (hue, saturation, lightness)
    }

    /// `#RRGGBB`, uppercase like the hex `ContentParser` stores, and
    /// `#RRGGBBAA` only when the colour is actually transparent.
    private static func hexString(_ color: ColorComponents) -> String {
        let hex = String(
            format: "#%02X%02X%02X",
            byte(color.red),
            byte(color.green),
            byte(color.blue)
        )
        guard color.alpha < 1 else { return hex }
        return hex + String(format: "%02X", byte(color.alpha))
    }

    private static func rgbString(_ color: ColorComponents) -> String {
        let channels = "\(byte(color.red)), \(byte(color.green)), \(byte(color.blue))"
        guard color.alpha < 1 else { return "rgb(\(channels))" }
        return "rgba(\(channels), \(alphaString(color.alpha)))"
    }

    private static func hslString(_ color: ColorComponents) -> String {
        let (hue, saturation, lightness) = rgbToHSL(color)
        let angles = "\(Int(hue.rounded())), \(percent(saturation))%, \(percent(lightness))%"
        guard color.alpha < 1 else { return "hsl(\(angles))" }
        return "hsla(\(angles), \(alphaString(color.alpha)))"
    }

    private static func byte(_ value: Double) -> Int {
        Int((value * 255).rounded())
    }

    private static func percent(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }

    /// Alpha with its trailing zeros dropped, so a half-transparent colour
    /// reads as "0.5" rather than "0.500".
    private static func alphaString(_ alpha: Double) -> String {
        var text = String(format: "%.3f", alpha)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - Timestamps

    /// Seconds since 1970 that could only be milliseconds: as seconds this is
    /// the year 5138, as milliseconds it is 1973. The split has to fall
    /// somewhere and nothing on a clipboard sits near either side of it.
    private static let millisecondThreshold: Double = 100_000_000_000

    /// One second past the last instant ISO 8601 has a four-digit year for.
    private static let epochLimit: Double = 253_402_300_800

    /// A Unix epoch — seconds, or milliseconds when the magnitude says so —
    /// written back as ISO 8601.
    ///
    /// UTC rather than the Mac's own zone, because the transform has to be a
    /// pure function of its input: a stamp that read differently after a trip
    /// abroad would not survive the round-trip back through `dateToEpoch`.
    private static func epochToDate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = number(trimmed) else { return nil }
        let seconds = abs(value) >= millisecondThreshold ? value / 1000 : value
        guard abs(seconds) < epochLimit else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: seconds.rounded()))
    }

    /// A written date back to seconds since 1970, or `nil` when the text is
    /// not one of the shapes below.
    ///
    /// Rounded down rather than to nearest, because Unix time names the second
    /// an instant falls in: a stamp written with fractional seconds has to come
    /// back as the epoch it was formatted from, not the one after it.
    private static func dateToEpoch(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = parseDate(trimmed) else { return nil }
        return String(Int(date.timeIntervalSince1970.rounded(.down)))
    }

    /// ISO 8601 date-times first, then the space-separated shapes people paste
    /// out of logs and database clients, then a bare calendar date.
    ///
    /// Both parsers match a prefix and stop, which is what fixes the order: a
    /// bare-date pass tried early would match the "2023-11-14" at the front of
    /// "2023-11-14 22:13:20" and throw the time away.
    private static func parseDate(_ text: String) -> Date? {
        if let date = isoDate(text, [.withInternetDateTime, .withFractionalSeconds]) { return date }
        if let date = isoDate(text, [.withInternetDateTime]) { return date }
        if let date = fixedFormatDate(text) { return date }
        return isoDate(text, [.withFullDate])
    }

    private static func isoDate(_ text: String, _ options: ISO8601DateFormatter.Options) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = options
        return formatter.date(from: text)
    }

    /// The non-ISO shapes, read in UTC for the reason `epochToDate` gives.
    ///
    /// en_US_POSIX or the format string is at the mercy of the user's locale:
    /// a Japanese or Buddhist calendar renders `yyyy` as 2569.
    private static func fixedFormatDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        // Longest first: DateFormatter matches a prefix, so "yyyy-MM-dd HH:mm"
        // would swallow a stamp that carries seconds and drop them.
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Whitespace

    /// Whitespace off both ends of every line. The line count is untouched:
    /// a blank line stays, as an empty one.
    private static func trimLines(_ text: String) -> String {
        lines(in: text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    /// Whitespace off the end of every line only — indentation survives.
    private static func stripTrailingSpace(_ text: String) -> String {
        lines(in: text).map { line in
            var line = line
            while let last = line.last, last.isWhitespace { line.removeLast() }
            return line
        }
        .joined(separator: "\n")
    }

    /// A run of blank lines becomes a single empty one. Whitespace-only counts
    /// as blank: a line of spaces is one to the eye, and leaving it would make
    /// the transform look like it had missed a gap.
    private static func collapseBlankLines(_ text: String) -> String {
        var kept: [String] = []
        var previousWasBlank = false
        for line in lines(in: text) {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if !isBlank {
                kept.append(line)
            } else if !previousWasBlank {
                kept.append("")
            }
            previousWasBlank = isBlank
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Line transforms

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

    private static func reverseLines(_ text: String) -> String {
        lines(in: text).reversed().joined(separator: "\n")
    }

    /// Number the lines from 1, right-aligned on the widest number so the text
    /// still lines up once the count reaches two digits.
    private static func numberLines(_ text: String) -> String {
        let all = lines(in: text)
        let width = String(all.count).count
        return all.enumerated().map { index, line in
            let number = String(index + 1)
            return String(repeating: " ", count: width - number.count) + "\(number). \(line)"
        }
        .joined(separator: "\n")
    }

    /// Line splitter shared by the line-oriented transforms.
    private static func lines(in text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }
}
