import Foundation

/// A recognised class of clipboard secret, in the order the detector tries
/// them: the first match wins, so the most distinctive signatures are first.
enum SecretKind: String, Sendable, CaseIterable {
    case privateKey
    case awsAccessKey
    case githubToken
    case apiKey
    case slackToken
    case stripeKey
    case jwt
    case connectionString
    case oneTimeCode
    case genericToken

    /// The fixed English name stored on the row's `secretLabel`.
    ///
    /// Stored rather than derived so the label is searchable in SQL, and a
    /// catalogue string rather than user data so it may be stored at all;
    /// every place it is shown runs it back through the `loc` catalogue.
    var label: String {
        switch self {
        case .privateKey: return "Private key"
        case .awsAccessKey: return "AWS access key"
        case .githubToken: return "GitHub token"
        case .apiKey: return "API key"
        case .slackToken: return "Slack token"
        case .stripeKey: return "Stripe key"
        case .jwt: return "JWT"
        case .connectionString: return "Connection string"
        case .oneTimeCode: return "One-time code"
        case .genericToken: return "Token"
        }
    }
}

/// Whole-clip secret classifier.
///
/// Pure and nonisolated — it runs on the capture path, in the Settings pane's
/// "already in your history" scan and in tests, none of which may block or
/// prompt. Everything it decides is a deterministic pattern match against
/// `text`: no service is asked to validate a value and no payload is decoded
/// beyond what `TextDetector.isJWT` already did, so classification cannot
/// leak the thing it looked at.
///
/// v1 matches a clip that *is* a secret (the whole trimmed string is one
/// credential), plus the multi-line PEM case — a key buried inside a
/// paragraph is out of scope, as are screenshots' OCR text.
enum SecretDetector {
    /// The kind `text` is a sample of, or nil when nothing matches.
    ///
    /// - Parameters:
    ///   - sourceBundleID: the app the copy came from. Only consulted for
    ///     one-time codes: a bare run of 4–8 digits is a code when Messages or
    ///     Mail produced it and ordinary data everywhere else.
    ///   - allowGenericToken: the Settings toggle's own switch — the generic
    ///     rule is the false-positive risk, so it answers to its own setting.
    static func classify(
        _ text: String,
        sourceBundleID: String? = nil,
        allowGenericToken: Bool = true
    ) -> SecretKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // PEM private key: the armour line names it. A whole block is what
        // is copied, so the clip starts with BEGIN and carries END too.
        if trimmed.hasPrefix("-----BEGIN"),
           trimmed.contains("PRIVATE KEY-----"),
           trimmed.contains("-----END") {
            return .privateKey
        }

        if isToken(trimmed, prefixes: ["AKIA", "ASIA"], tailLength: 16, alphabet: Self.upperAndDigits) {
            return .awsAccessKey
        }
        if isToken(trimmed, prefixes: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"], tailMinLength: 36, alphabet: Self.alphaNumeric)
            || isToken(trimmed, prefixes: ["github_pat_"], tailMinLength: 50, alphabet: Self.alphaNumericUnderscore) {
            return .githubToken
        }
        // OpenAI (sk-, sk-proj-) and Anthropic (sk-ant-) keys share one shape;
        // the middle marker is just characters of the tail alphabet.
        if isToken(trimmed, prefixes: ["sk-"], tailMinLength: 20, alphabet: Self.tokenCharacters) {
            return .apiKey
        }
        if isToken(trimmed, prefixes: ["xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-"], tailMinLength: 10, alphabet: Self.tokenCharacters) {
            return .slackToken
        }
        if isToken(trimmed, prefixes: ["sk_live_", "sk_test_", "rk_live_", "rk_test_"], tailMinLength: 16, alphabet: Self.alphaNumeric) {
            return .stripeKey
        }
        if TextDetector.isJWT(trimmed) {
            return .jwt
        }
        // scheme://user:password@host — the credential is the non-empty
        // password inside the authority; a URL without one is just a link.
        if isConnectionString(trimmed) {
            return .connectionString
        }
        if isOneTimeCode(trimmed, sourceBundleID: sourceBundleID) {
            return .oneTimeCode
        }

        guard allowGenericToken, isGenericToken(trimmed) else { return nil }
        return .genericToken
    }

    // MARK: - Named tokens

    /// `text` is `prefix` plus a tail of exactly `length`/`>= minLength`
    /// characters drawn from `alphabet` — the anchored, whole-clip form of
    /// the detection table's token rules.
    private static func isToken(
        _ text: String,
        prefixes: [String],
        tailMinLength: Int,
        tailMaxLength: Int? = nil,
        alphabet: Set<Character>
    ) -> Bool {
        prefixes.contains { prefix in
            guard text.hasPrefix(prefix) else { return false }
            let tail = text.dropFirst(prefix.count)
            guard tail.count >= tailMinLength,
                  tailMaxLength == nil || tail.count == tailMaxLength
            else { return false }
            return tail.allSatisfy(alphabet.contains)
        }
    }

    /// Convenience for the fixed-length rule (AWS access keys).
    private static func isToken(
        _ text: String,
        prefixes: [String],
        tailLength: Int,
        alphabet: Set<Character>
    ) -> Bool {
        isToken(text, prefixes: prefixes, tailMinLength: tailLength, tailMaxLength: tailLength, alphabet: alphabet)
    }

    private static let upperAndDigits = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let alphaNumeric = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    private static let alphaNumericUnderscore = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
    /// Base64's own alphabet minus '=' — the characters service tokens are
    /// written in (the Stripe/Slack/OpenAI tails all draw from it).
    private static let tokenCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    // MARK: - Connection strings

    /// A URL carrying credentials: `scheme://user:password@host` with a
    /// non-empty password. `postgres://…`, `mongodb+srv://…`, `redis://…`,
    /// `amqp://…` and `https://user:pass@…` all land here.
    private static func isConnectionString(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
              components.scheme != nil,
              let password = components.password, !password.isEmpty,
              let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    // MARK: - One-time codes

    /// The bundle identifiers a bare run of digits is a one-time code from:
    /// Messages and Mail, per the detection table. The same digits copied
    /// out of a spreadsheet or a terminal are data, not a code.
    static let oneTimeCodeSources: Set<String> = [
        "com.apple.MobileSMS",
        "com.apple.mail",
    ]

    private static func isOneTimeCode(_ text: String, sourceBundleID: String?) -> Bool {
        guard let sourceBundleID,
              Self.oneTimeCodeSources.contains(where: {
                  SensitiveFilter.matchesBundleID(sourceBundleID, entry: $0)
              })
        else { return false }
        guard (4...8).contains(text.count) else { return false }
        return text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - Generic high-entropy token

    private static let genericMinLength = 32
    private static let genericMaxLength = 512
    /// Shannon entropy floor, in bits per character, per the detection table.
    private static let genericMinEntropy = 4.0
    /// Character classes a generic token must draw on at least three of.
    private static let genericMinClasses = 3

    /// The fallback rule: one whitespace-free run that is long, mixed and
    /// high-entropy — the shape of a token no named rule knows — provided it
    /// is not one of the lookalikes the corpus established.
    private static func isGenericToken(_ text: String) -> Bool {
        guard (genericMinLength...genericMaxLength).contains(text.count) else { return false }
        guard !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        guard characterClasses(of: text) >= genericMinClasses else { return false }
        // The lookalikes: a URL, a hex colour or digest, a UUID, a file
        // path, or base64 that opens as an image/document.
        if TextDetector.isWebURL(text)
            || isAnyURLWithHost(text)
            || isAllHexDigits(text)
            || UUID(uuidString: text) != nil
            || isFilePath(text)
            || isBase64Image(text) {
            return false
        }
        return shannonEntropy(of: text) >= genericMinEntropy
    }

    /// Any `scheme://host` string — a credential-bearing connection string
    /// is caught by its own rule earlier; one without a password (or a URL
    /// on another scheme entirely) is a locator, not a secret, and long
    /// ones would otherwise sail through the generic rule.
    private static func isAnyURLWithHost(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
              components.scheme != nil,
              let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    /// How many of the four classes (upper, lower, digit, symbol) `text`
    /// uses. A long English word or a run of digits never gets past this.
    private static func characterClasses(of text: String) -> Int {
        var upper = false, lower = false, digit = false, symbol = false
        for character in text {
            if character.isUppercase {
                upper = true
            } else if character.isLowercase {
                lower = true
            } else if character.isNumber {
                digit = true
            } else {
                symbol = true
            }
        }
        return [upper, lower, digit, symbol].filter { $0 }.count
    }

    /// Every character a hexadecimal digit — optionally a `#RRGGBB` colour,
    /// but also a git SHA, a fingerprint or a hex digest: all high-entropy,
    /// all not credentials.
    private static func isAllHexDigits(_ text: String) -> Bool {
        let body = text.hasPrefix("#") ? text.dropFirst() : text[...]
        return !body.isEmpty && body.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private static func isFilePath(_ text: String) -> Bool {
        text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("file:")
    }

    /// Base64 that decodes into a document or image header — a pasted "icon"
    /// is random-looking and is not a credential.
    private static func isBase64Image(_ text: String) -> Bool {
        guard text.allSatisfy(Self.base64Alphabet.contains),
              let data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]),
              data.count >= 4
        else { return false }
        return Self.fileSignatures.contains { data.prefix($0.count).elementsEqual($0) }
    }

    private static let base64Alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    private static let fileSignatures: [[UInt8]] = [
        [0x89, 0x50, 0x4E, 0x47],       // PNG
        [0xFF, 0xD8, 0xFF],             // JPEG
        [0x47, 0x49, 0x46, 0x38],       // GIF87a/89a
        [0x49, 0x49, 0x2A, 0x00],       // TIFF little-endian
        [0x4D, 0x4D, 0x00, 0x2A],       // TIFF big-endian
        [0x25, 0x50, 0x44, 0x46],       // %PDF
        [0x50, 0x4B, 0x03, 0x04],       // ZIP (docx, xlsx, archives)
    ]

    /// Shannon entropy of the string's characters, bits per character.
    private static func shannonEntropy(of text: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let length = Double(text.count)
        return counts.values.reduce(0.0) { entropy, count in
            let probability = Double(count) / length
            return entropy - probability * log2(probability)
        }
    }
}

/// The one plaintext-derived string a secret row keeps: enough of the value
/// to recognise *which* secret it is, never enough to use it.
enum SecretMask {
    /// A fixed-length bullet run, so the mask says nothing about how long
    /// the plaintext was. Twelve, per the PRD's example (`AKIA•…•7Q2X`).
    private static let bullets = String(repeating: "•", count: 12)

    /// The mask for values too short to show characters of, and for
    /// one-time codes, whose digits are the whole secret.
    private static let shortBullets = "••••••"

    /// How much of a masked value may be real characters — "keys of at
    /// least 20 chars" per the PRD.
    private static let minimumMaskableLength = 20

    /// `AKIA••••••••••••7Q2X`: the vendor prefix up to the first `_` or `-`
    /// (or the first four characters when there is none), twelve bullets,
    /// then the last four characters.
    static func mask(_ plaintext: String, kind: SecretKind? = nil) -> String {
        let trimmed = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .oneTimeCode || trimmed.count < minimumMaskableLength {
            return shortBullets
        }
        // The vendor prefix is the part that says which service the secret
        // belongs to: through the LAST '_' or '-' inside the first nine
        // characters ("sk_live_…", "ghp_…", "github_…"), or the first four
        // characters when there is none ("AKIA…"). A value that opens with
        // punctuation — a PEM block's "-----BEGIN" — has no vendor prefix,
        // so it takes the four characters.
        let prefix: String
        let startsWithWord = trimmed.first?.isLetter == true || trimmed.first?.isNumber == true
        let lastSeparator = trimmed.indices.last {
            let offset = trimmed.distance(from: trimmed.startIndex, to: $0)
            return offset <= 8 && offset > 0 && (trimmed[$0] == "_" || trimmed[$0] == "-")
        }
        if startsWithWord, let separator = lastSeparator {
            prefix = String(trimmed[...separator])
        } else {
            prefix = String(trimmed.prefix(4))
        }
        return prefix + bullets + trimmed.suffix(4)
    }
}
