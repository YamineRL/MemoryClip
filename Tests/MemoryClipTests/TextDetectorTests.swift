import XCTest

@testable import MemoryClip

final class TextDetectorTests: XCTestCase {
    // MARK: - Email

    func testEmailValid() {
        XCTAssertEqual(TextDetector.detect("user@example.com"), [.email])
        XCTAssertEqual(TextDetector.detect("first.last+tag@sub.example.co.uk"), [.email])
    }

    func testEmailTrimsSurroundingWhitespace() {
        XCTAssertEqual(TextDetector.detect("  user@example.com  "), [.email])
    }

    func testEmailInvalid() {
        XCTAssertEqual(TextDetector.detect("user@example"), [])        // no dotted domain
        XCTAssertEqual(TextDetector.detect("userexample.com"), [])     // no '@'
        XCTAssertEqual(TextDetector.detect("@example.com"), [])        // empty local part
        XCTAssertEqual(TextDetector.detect("a@@example.com"), [])      // two '@'
        XCTAssertEqual(TextDetector.detect("user name@example.com"), []) // internal space
    }

    // MARK: - URL

    func testURLValid() {
        XCTAssertEqual(TextDetector.detect("https://example.com/path?q=1"), [.url])
        XCTAssertEqual(TextDetector.detect("http://example.com"), [.url])
        XCTAssertEqual(TextDetector.detect("www.example.com"), [.url])
    }

    func testURLInvalid() {
        XCTAssertEqual(TextDetector.detect("ftp://example.com"), [])   // not http(s)
        XCTAssertEqual(TextDetector.detect("example com"), [])         // space, no dots/scheme
        XCTAssertEqual(TextDetector.detect("https://localhost"), [])   // host has no dot
    }

    // MARK: - Phone

    func testPhoneWithSeparators() {
        XCTAssertEqual(TextDetector.detect("+1 (555) 123-4567"), [.phone])
        XCTAssertEqual(TextDetector.detect("555-1234"), [.phone])
        XCTAssertEqual(TextDetector.detect("555.123.4567"), [.phone])
    }

    func testPhoneInvalid() {
        XCTAssertEqual(TextDetector.detect("12345"), [])               // too few digits
        XCTAssertEqual(TextDetector.detect("1234567890123456"), [])    // 16 digits, too many
        XCTAssertEqual(TextDetector.detect("phone: 555-1234"), [])     // letters
        XCTAssertEqual(TextDetector.detect("+1+555+1234"), [])         // '+' only allowed first
    }

    // MARK: - JWT

    func testJWTValid() {
        // Canonical jwt.io example token (HS256 header).
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
            + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ"
            + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        XCTAssertEqual(TextDetector.detect(jwt), [.jwt])
    }

    func testJWTInvalid() {
        // Header decodes to "{}" — no "alg" claim.
        XCTAssertEqual(TextDetector.detect("e30.eyJhIjoxfQ.x"), [])
        // Only two segments.
        XCTAssertEqual(TextDetector.detect("eyJhbGciOiJIUzI1NiJ9.eyJhIjoxfQ"), [])
        // Not base64url characters.
        XCTAssertEqual(TextDetector.detect("ab$.cd-.ef_"), [])
    }

    // MARK: - JSON

    func testJSONObjectAndArray() {
        XCTAssertEqual(TextDetector.detect(#"{"a":1}"#), [.json])
        XCTAssertEqual(TextDetector.detect("[1,2,3]"), [.json])
        XCTAssertEqual(TextDetector.detect("  []  "), [.json])
    }

    func testJSONScalarsDoNotCount() {
        XCTAssertEqual(TextDetector.detect("42"), [])
        XCTAssertEqual(TextDetector.detect("3.14"), [])
        XCTAssertEqual(TextDetector.detect("true"), [])
        XCTAssertEqual(TextDetector.detect(#""hello""#), [])
    }

    // MARK: - Whole-string rule, ordering, primary

    func testWholeStringOnly() {
        // Matches a kind only when the ENTIRE trimmed string matches.
        XCTAssertEqual(TextDetector.detect("email me at user@example.com"), [])
        XCTAssertEqual(TextDetector.detect("2+3*4"), []) // arithmetic is not a phone number
    }

    func testDetectOrderingIsEmailThenURL() {
        // "https://user@example.com" is both an e-mail-shaped string and a
        // URL with userinfo — email must precede url in the result.
        XCTAssertEqual(TextDetector.detect("https://user@example.com"), [.email, .url])
    }

    func testEmptyAndPlainText() {
        XCTAssertEqual(TextDetector.detect(""), [])
        XCTAssertEqual(TextDetector.detect("   \n "), [])
        XCTAssertEqual(TextDetector.detect("just some words"), [])
    }

    // MARK: - Robustness guards

    /// A string with exactly one '@' and no dot after it: the old pattern
    /// `[^@\s]+@[^@\s]+\.[^@\s]+` had to try every split of the tail between
    /// its two ambiguous quantifiers before failing. Measured end-to-end
    /// through `detect()` at 2 KB → 0.24 s, 10 KB → 6.7 s, 40 KB → 96 s.
    /// The "exactly one @" pre-check did not help — the payload satisfies it.
    private func redosPayload(length: Int) -> String {
        "a@" + String(repeating: "a", count: length)
    }

    func testPathologicalEmailInputCompletesFast() {
        // Just under the length guard, so this exercises the e-mail check
        // itself and not merely the early return. With the old regex a single
        // pass took ~1 s; 20 passes would take well over 20 s.
        let payload = redosPayload(length: 4000)
        let start = Date()
        for _ in 0..<20 {
            XCTAssertEqual(TextDetector.detect(payload), [])
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testHugePathologicalInputIsRejectedFast() {
        let start = Date()
        XCTAssertEqual(TextDetector.detect(redosPayload(length: 40_000)), [])
        XCTAssertEqual(TextDetector.detect(String(repeating: "x", count: 5_000_000)), [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testOverlongInputIsNotClassified() {
        // Valid shapes past the size guard are simply not badged.
        let longLocal = String(repeating: "a", count: 5000)
        XCTAssertEqual(TextDetector.detect("\(longLocal)@example.com"), [])
        XCTAssertEqual(TextDetector.detect("[" + String(repeating: "1,", count: 3000) + "1]"), [])
        // …but the same shapes just under the limit still are.
        XCTAssertEqual(TextDetector.detect("\(String(repeating: "a", count: 100))@example.com"), [.email])
    }

    func testEmailEdgeCasesMatchPreviousRegexSemantics() {
        XCTAssertEqual(TextDetector.detect("a@b.c"), [.email])          // minimal
        XCTAssertEqual(TextDetector.detect("user@.a.b"), [.email])      // dot inside domain
        XCTAssertEqual(TextDetector.detect("user@example."), [])        // trailing dot only
        XCTAssertEqual(TextDetector.detect("user@.com"), [])            // leading dot only
        XCTAssertEqual(TextDetector.detect("user@"), [])                // empty domain
        XCTAssertEqual(TextDetector.detect("user@a.b\tc"), [])          // internal tab
    }

    func testPrimary() {
        XCTAssertEqual(TextDetector.primary("user@example.com"), .email)
        XCTAssertEqual(TextDetector.primary("https://example.com"), .url)
        XCTAssertNil(TextDetector.primary("just some words"))
    }
}
