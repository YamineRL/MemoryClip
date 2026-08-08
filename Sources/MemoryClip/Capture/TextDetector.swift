import Foundation

/// Kinds of structured content a plain-text clip may consist of
/// (Phase-2 "smart text detection"). Detection always considers the
/// WHOLE (trimmed) string — never substrings.
enum DetectedKind: String, CaseIterable, Sendable {
    case email, url, phone, jwt, json
}

/// Whole-string content classifier. Foundation-only, no state, nonisolated —
/// safe to call from any concurrency context.
enum TextDetector {
    /// Upper bound, in UTF-8 bytes, on a clip we will classify at all
    /// (O(1) to read on native Swift strings — no traversal, no copy).
    /// `detect` runs on a SwiftUI body path for every visible row, and every
    /// kind it checks is a *whole-string* shape: an e-mail address, a URL, a
    /// phone number and a JWT are all far shorter than this, so the guard
    /// only ever discards input that could not have matched anyway (bar
    /// enormous JSON blobs, which lose only a badge). 4 KiB is roughly the
    /// longest legal URL in practice and ~50× the longest legal e-mail
    /// address, and it keeps per-row work bounded regardless of clip size.
    private static let maxDetectableUTF8Bytes = 4096

    /// Base64URL alphabet, used by the JWT segment check.
    private static let base64URLCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        + "abcdefghijklmnopqrstuvwxyz0123456789_-")

    /// Every kind the whole trimmed string matches, in canonical order:
    /// email, url, phone, jwt, json. (The kinds are essentially mutually
    /// exclusive; the fixed order keeps results deterministic.)
    static func detect(_ text: String) -> [DetectedKind] {
        guard text.utf8.count <= maxDetectableUTF8Bytes else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var kinds: [DetectedKind] = []
        if isEmail(trimmed) { kinds.append(.email) }
        if isWebURL(trimmed) { kinds.append(.url) }
        if isPhone(trimmed) { kinds.append(.phone) }
        if isJWT(trimmed) { kinds.append(.jwt) }
        if isJSONObjectOrArray(trimmed) { kinds.append(.json) }
        return kinds
    }

    /// The first detected kind, if any — the one UI surfaces as "primary".
    static func primary(_ text: String) -> DetectedKind? {
        detect(text).first
    }

    // MARK: - Per-kind checks (whole-string, input already trimmed)

    /// Pragmatic e-mail: exactly one '@', non-empty local part, dotted
    /// domain, no whitespace anywhere.
    ///
    /// Deliberately plain string logic, not a regex: the previous pattern
    /// `[^@\s]+@[^@\s]+\.[^@\s]+` has two ambiguous quantifiers around the
    /// `\.` and backtracks catastrophically — a 40 KB crafted clip froze the
    /// main thread for ~96 s. This version is linear, single-pass, and
    /// accepts exactly the same strings.
    private static func isEmail(_ string: String) -> Bool {
        guard !string.contains(where: \.isWhitespace) else { return false }
        let halves = string.split(separator: "@", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return false } // exactly one '@'
        let local = halves[0], domain = halves[1]
        guard !local.isEmpty, !domain.isEmpty else { return false }
        // Dotted domain: a '.' with at least one character on either side,
        // i.e. somewhere strictly inside the domain half.
        return domain.dropFirst().dropLast().contains(".")
    }

    /// Mirrors `ContentParser.isWebURL(_:)` — deliberately duplicated rather
    /// than called: `ContentParser` is `@MainActor`-isolated while this
    /// detector must stay nonisolated pure logic. Keep the two in sync.
    private static func isWebURL(_ string: String) -> Bool {
        guard !string.contains(" "), !string.contains("\n") else { return false }
        // "www.example.com" has no scheme; prepend one for validation only.
        let candidate = string.lowercased().hasPrefix("www.") ? "https://" + string : string
        guard let url = URL(string: candidate) else { return false }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, host.contains(".") else { return false }
        return true
    }

    /// Phone: digits with optional leading '+', spaces, dashes, parens and
    /// dots; 7–15 digits total; must start with '+' or a digit.
    private static func isPhone(_ string: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789+ -.()")
        guard string.unicodeScalars.allSatisfy(allowed.contains),
              let first = string.unicodeScalars.first,
              first == "+" || CharacterSet.decimalDigits.contains(first)
        else { return false }
        guard !string.dropFirst().contains("+") else { return false }
        let digitCount = string.filter(\.isNumber).count
        return (7...15).contains(digitCount)
    }

    /// JWT: three Base64URL segments separated by dots (signature may be
    /// empty) whose decoded header is a JSON object containing "alg".
    ///
    /// The shape test is plain string logic rather than the previous inline
    /// literal `/[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/`, which was
    /// recompiled on every call (~15× overhead on this SwiftUI body path).
    /// Hoisting it to a `static let` is not an option under Swift 6 strict
    /// concurrency — `Regex` is not `Sendable`. Since '.' is not in the
    /// character class, splitting on '.' is exactly equivalent to the regex.
    private static func isJWT(_ string: String) -> Bool {
        let segments = string.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              !segments[0].isEmpty, !segments[1].isEmpty,
              segments.allSatisfy({ $0.allSatisfy(base64URLCharacters.contains) })
        else { return false }
        let headerSegment = string.prefix(while: { $0 != "." })
        guard let headerData = base64URLDecode(headerSegment),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] != nil
        else { return false }
        return true
    }

    /// JSON: parseable AND top level is an object or array — plain scalars
    /// ("42", "true", "\"hi\"") do not count.
    private static func isJSONObjectOrArray(_ string: String) -> Bool {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else { return false }
        return object is [String: Any] || object is [Any]
    }

    /// Decode a Base64URL segment (JWT alphabet: '-'/'_' instead of '+'/'/',
    /// padding typically omitted).
    private static func base64URLDecode(_ segment: Substring) -> Data? {
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !base64.isEmpty && base64.count % 4 != 0 {
            base64 += "="
        }
        return Data(base64Encoded: base64)
    }
}
