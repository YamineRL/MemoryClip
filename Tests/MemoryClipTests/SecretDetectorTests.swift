import XCTest
@testable import MemoryClip

/// The PRD's detection corpus. Every positive sample asserts the named
/// kind, not merely "a kind" — a slack-shaped string landing on
/// `genericToken` is a bug even though both answers are `!= nil`.
final class SecretDetectorTests: XCTestCase {

    // MARK: - Positive corpus (each with the kind it must land on)

    private let positiveCorpus: [(text: String, kind: SecretKind)] = [
        // PEM blocks, the three common headers.
        ("-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA7\n-----END RSA PRIVATE KEY-----", .privateKey),
        ("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAA\n-----END OPENSSH PRIVATE KEY-----", .privateKey),
        ("-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEINc=\n-----END EC PRIVATE KEY-----", .privateKey),

        // AWS access keys (the documented example shape).
        ("AKIAIOSFODNN7EXAMPLE", .awsAccessKey),
        ("ASIAIOSFODNN7EXAMPLE", .awsAccessKey),

        // GitHub tokens: every classic prefix plus the fine-grained PAT.
        ("ghp_16C7e42F292c6912E7710c838347Ae178B4a", .githubToken),
        ("gho_16C7e42F292c6912E7710c838347Ae178B4a", .githubToken),
        ("ghu_16C7e42F292c6912E7710c838347Ae178B4a", .githubToken),
        ("ghs_16C7e42F292c6912E7710c838347Ae178B4a", .githubToken),
        ("ghr_16C7e42F292c6912E7710c838347Ae178B4a", .githubToken),
        ("github_pat_11ABCDE0fghijklmnOpQrsTUVwxyz_0123456789abcdeFGHIJKLMNOPQ", .githubToken),

        // OpenAI and Anthropic keys share the sk- shape.
        ("sk-proj-AbCdEf0123456789GhIjKlMnOpQr", .apiKey),
        ("sk-ant-api03-AbCdEf0123456789_-GhIjKlMn", .apiKey),

        // Slack tokens.
        ("xoxb-" + "1234567890-abcdefghijklmn", .slackToken),
        ("xoxp-" + "1234567890-abcdefghijklmn", .slackToken),

        // Stripe live/test/restricted keys.
        ("sk_live_" + "4eC39HqLyjWDarjtT1zdp7dc", .stripeKey),
        ("sk_test_" + "4eC39HqLyjWDarjtT1zdp7dc", .stripeKey),
        ("rk_live_" + "4eC39HqLyjWDarjtT1zdp7dc", .stripeKey),

        // A real JWT (alg + payload + signature).
        ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c", .jwt),

        // Connection strings with credentials.
        ("postgres://admin:S3cr3tP@ssw0rd@db.internal:5432/appdb", .connectionString),
        ("mongodb+srv://appuser:p4ss-Word-9@cluster0.abcde.mongodb.net/mydb", .connectionString),
        ("amqp://guest:guestp4ss@rabbit.internal:5672/vhost", .connectionString),
        ("https://deploy:t0ken-InURL@example.internal/vault", .connectionString),

        // A generic high-entropy token (not matching any named prefix).
        ("X9k2Vb7mPqRt4wYz8nJc5Hd6Fs3Ga0Lm1CvBxW", .genericToken),
        // A Bitcoin address: decided — flagged. It matches the generic rule
        // and is only ever pasted to *pay* someone; masking costs a reveal
        // click while a miss costs a credential in the clear.
        ("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", .genericToken),
    ]

    // MARK: - Inverse corpus (real secrets that must not fall to "generic")

    func testEveryNamedSampleLandsOnItsOwnKind() {
        for (index, sample) in positiveCorpus.enumerated() {
            XCTAssertEqual(
                SecretDetector.classify(sample.text, sourceBundleID: "com.apple.MobileSMS"),
                sample.kind,
                "corpus item \(index): \(sample.text.prefix(12))…"
            )
        }
    }

    // MARK: - Negative corpus (the innocent lookalikes)

    func testNegativeCorpusIsUntouched() {
        let negatives: [(text: String, note: String)] = [
            ("https://example.com/path?q=1#section", "URL"),
            ("#A1B2C3", "hex colour"),
            ("550e8400-e29b-41d4-a716-446655440000", "UUID"),
            ("86f7e437faa5a7fce15d1ddcb9eaeaea377667b8", "git SHA-1"),
            ("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256"),
            ("/Users/yamine/Documents/dev/active/MemoryClip/Sources/main.swift", "file path"),
            ("~/Library/Application Support/app.memoryclip/MemoryClip.store", "tilde path"),
            ("a fairly long English sentence that keeps going well past the threshold", "prose"),
            ("swift test --filter SecretDetectorTests", "a command"),
            ("4785", "bare four digits"),
            ("call me at +1 415 555 0132 tomorrow morning", "a phone number in prose"),
            ("my api key is sk-proj-AbCdEf0123456789GhIjKlMnOpQr ok", "token inside a sentence"),
            ("the meeting is on Friday at 3pm bring the deck", "more prose"),
            ("postgres://admin@db.internal:5432/appdb", "connection string without password"),
        ]
        // No source: bare digits and codes only count as secrets with a
        // Messages/Mail provenance, which is exercised separately.
        for (index, sample) in negatives.enumerated() {
            XCTAssertNil(
                SecretDetector.classify(sample.text),
                "corpus item \(index) (\(sample.note)): \(sample.text.prefix(40))…"
            )
        }
    }

    func testNullSourceIsNeverAOneTimeCode() {
        // OTP requires the Messages/Mail provenance; nil means unknown.
        XCTAssertNil(SecretDetector.classify("482731"))
        XCTAssertNil(SecretDetector.classify("482731", sourceBundleID: "com.tinyspeck.slackmacgap"))
    }

    func testOneTimeCodeNeedsTheRightSource() {
        XCTAssertEqual(SecretDetector.classify("482731", sourceBundleID: "com.apple.MobileSMS"), .oneTimeCode)
        XCTAssertEqual(SecretDetector.classify("1234", sourceBundleID: "com.apple.mail"), .oneTimeCode)
        XCTAssertEqual(SecretDetector.classify("12345678", sourceBundleID: "com.apple.MobileSMS"), .oneTimeCode)
        // A Messages helper process still counts; the same digits elsewhere do not.
        XCTAssertEqual(SecretDetector.classify("482731", sourceBundleID: "com.apple.MobileSMS.helper"), .oneTimeCode)
        XCTAssertNil(SecretDetector.classify("123456789", sourceBundleID: "com.apple.MobileSMS")) // 9 digits
        XCTAssertNil(SecretDetector.classify("123", sourceBundleID: "com.apple.MobileSMS")) // 3 digits
        XCTAssertNil(SecretDetector.classify("48-27-31", sourceBundleID: "com.apple.MobileSMS")) // has dashes
    }

    // MARK: - Rules beyond the corpus

    func testSurroundingWhitespaceIsTrimmedBeforeClassifying() {
        XCTAssertEqual(SecretDetector.classify("  AKIAIOSFODNN7EXAMPLE \n"), .awsAccessKey)
        XCTAssertEqual(
            SecretDetector.classify("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n"),
            .privateKey
        )
    }

    func testGenericRuleRespectsItsSwitch() {
        let token = "X9k2Vb7mPqRt4wYz8nJc5Hd6Fs3Ga0Lm1CvBxW"
        XCTAssertEqual(SecretDetector.classify(token, allowGenericToken: false), nil)
        XCTAssertEqual(SecretDetector.classify(token, allowGenericToken: true), .genericToken)
    }

    func testGenericRuleBoundaries() {
        // 31 mixed chars: under the length floor.
        let short = "X9k2Vb7mPqRt4wYz8nJc5Hd6Fs3Ga0L"
        XCTAssertEqual(short.count, 31)
        XCTAssertNil(SecretDetector.classify(short))
        // 513 chars: over the ceiling.
        let long = String(repeating: "X9k2Vb7m", count: 64) + "P"
        XCTAssertGreaterThan(long.count, 512)
        XCTAssertNil(SecretDetector.classify(long))
        // 96 chars, single case + digits only: two character classes.
        XCTAssertNil(SecretDetector.classify(String(repeating: "a1", count: 48)))
        // A token-shaped run with a space inside it is two words of prose.
        XCTAssertNil(SecretDetector.classify("X9k2Vb7mPqRt4wYz8nJc5Hd6Fs3Ga0Lm1CvBx W9k2Vb7mPqRt"))
    }

    func testTokenRulesAreWholeClip() {
        // One character of extra alphabet-invalid text breaks the anchor.
        XCTAssertNil(SecretDetector.classify("AKIAIOSFODNN7EXAMPLE!"))
        XCTAssertNil(SecretDetector.classify("this:AKIAIOSFODNN7EXAMPLE"))
        // And a short tail does not stretch to fit.
        XCTAssertNil(SecretDetector.classify("AKIAIOSFODNN7EXA"))
        XCTAssertNil(SecretDetector.classify("sk_live_" + "4eC39HqLyjWD"))
    }

    func testMaskHidesTheMiddle() {
        XCTAssertEqual(SecretMask.mask("AKIAIOSFODNN7EXAMPLE"), "AKIA••••••••••••MPLE")
        // The vendor prefix runs to the last separator inside nine chars:
        // "sk_live_" and "github_pat_" all keep theirs.
        XCTAssertEqual(SecretMask.mask("sk_live_" + "4eC39HqLyjWDarjtT1zdp7dc"), "sk_live_••••••••••••p7dc")
        XCTAssertEqual(SecretMask.mask("ghp_16C7e42F292c6912E7710c838347Ae178B4a"), "ghp_••••••••••••8B4a")
        // Under 20 chars or a one-time code: all bullets, no real text.
        XCTAssertEqual(SecretMask.mask("short_secret_19char"), "••••••")
        XCTAssertEqual(
            SecretMask.mask("482731", kind: .oneTimeCode),
            "••••••"
        )
        XCTAssertEqual(SecretMask.mask("ghp_shortish"), "••••••")
    }
}
