import XCTest

@testable import MemoryClip

/// A plain stand-in for `ClipItem`, so the shared predicates can be
/// exercised without a SwiftData container.
private struct FakeClip: ClipDisplayable {
    var uuid = UUID()
    var kind: ClipKind = .text
    var text: String?
    var ocrText: String?
    var colorHex: String?
    var fileURLStrings: [String] = []
    var sourceAppName: String?
    var isScreenshot = false
}

/// Covers the pure display logic shared by ClipRowView and PreviewView:
/// the instant-calc gate, VoiceOver label composition, truncation and
/// file-URL prettifying.
final class ClipDisplayTests: XCTestCase {
    // MARK: - Instant-calc gate (must be identical in row and preview)

    func testCalcAppliesToEveryTextBearingKind() {
        for kind in [ClipKind.text, .richText, .link] {
            XCTAssertEqual(
                ClipDisplay.calcResult(kind: kind, text: "12*7"), "84",
                "expected calc for \(kind)"
            )
        }
    }

    func testCalcIgnoresNonTextKinds() {
        for kind in [ClipKind.image, .file, .color] {
            XCTAssertNil(ClipDisplay.calcResult(kind: kind, text: "12*7"))
        }
    }

    func testCalcSuppressesBareNumberEcho() {
        XCTAssertNil(ClipDisplay.calcResult(kind: .text, text: "42"))
        XCTAssertNil(ClipDisplay.calcResult(kind: .text, text: "  42  "))
    }

    func testCalcIgnoresNonExpressions() {
        XCTAssertNil(ClipDisplay.calcResult(kind: .text, text: "hello world"))
        XCTAssertNil(ClipDisplay.calcResult(kind: .text, text: nil))
        XCTAssertNil(ClipDisplay.calcResult(kind: .text, text: "2026-08-07"))
    }

    func testCalcTrimsSurroundingWhitespace() {
        XCTAssertEqual(ClipDisplay.calcResult(kind: .text, text: "\n 2+3 \n"), "5")
    }

    func testTextBearingKinds() {
        XCTAssertTrue(ClipDisplay.isTextBearing(.text))
        XCTAssertTrue(ClipDisplay.isTextBearing(.richText))
        XCTAssertTrue(ClipDisplay.isTextBearing(.link))
        XCTAssertFalse(ClipDisplay.isTextBearing(.image))
        XCTAssertFalse(ClipDisplay.isTextBearing(.file))
        XCTAssertFalse(ClipDisplay.isTextBearing(.color))
    }

    // MARK: - Note guard (must be identical in the card menu and the ⌘S / n keys)

    func testAnyTextBearingClipCanSaveANote() {
        for kind in [ClipKind.text, .richText, .link] {
            XCTAssertTrue(
                ClipDisplay.canSaveNote(FakeClip(kind: kind, text: "worth keeping")),
                "expected a note for \(kind)"
            )
        }
    }

    /// The key press has no menu item to hide, so these are the clips where
    /// it must do nothing at all rather than start an export that can only
    /// fail: nothing was copied that a note could be made of.
    func testClipWithNothingToWriteCannotSaveANote() {
        XCTAssertFalse(ClipDisplay.canSaveNote(FakeClip(kind: .color, colorHex: "#FF00AA")))
        XCTAssertFalse(ClipDisplay.canSaveNote(FakeClip(kind: .text, text: nil)))
        XCTAssertFalse(ClipDisplay.canSaveNote(FakeClip(kind: .text, text: " \n ")))
        XCTAssertFalse(
            ClipDisplay.canSaveNote(FakeClip(kind: .file, fileURLStrings: ["/tmp/report.pdf"])),
            "a copied file is a reference, not text"
        )
    }

    func testImagesAndScreenshotsCanSaveANoteOnceVisionFindsText() {
        XCTAssertTrue(ClipDisplay.canSaveNote(FakeClip(kind: .image, ocrText: "INVOICE 2024")))
        XCTAssertTrue(
            ClipDisplay.canSaveNote(FakeClip(kind: .file, ocrText: "TOTAL 42.00", isScreenshot: true)),
            "a screenshot is a .file clip carrying pixels"
        )
        XCTAssertFalse(ClipDisplay.canSaveNote(FakeClip(kind: .image)))
        XCTAssertFalse(
            ClipDisplay.canSaveNote(FakeClip(kind: .file, ocrText: "  ", isScreenshot: true)),
            "whitespace-only recognition is nothing recognised"
        )
    }

    func testExtractedTextIsTrimmedAndOnlyForPictures() {
        XCTAssertEqual(ClipDisplay.extractedText(for: FakeClip(kind: .image, ocrText: " hi \n")), "hi")
        XCTAssertEqual(
            ClipDisplay.extractedText(for: FakeClip(kind: .file, ocrText: "hi", isScreenshot: true)), "hi"
        )
        XCTAssertNil(ClipDisplay.extractedText(for: FakeClip(kind: .file, ocrText: "hi")))
        XCTAssertNil(ClipDisplay.extractedText(for: FakeClip(kind: .text, ocrText: "hi")))
    }

    // MARK: - Spoken summary truncation

    func testShortSummaryIsSpokenWhole() {
        XCTAssertEqual(ClipDisplay.spokenSummary("hello world"), "hello world")
    }

    func testSummaryCollapsesWhitespaceAndNewlines() {
        XCTAssertEqual(ClipDisplay.spokenSummary("a\n\nb\t  c"), "a b c")
    }

    func testLongSummaryIsTruncatedWithCharacterCount() {
        let long = String(repeating: "x", count: 4000)
        let spoken = ClipDisplay.spokenSummary(long)

        XCTAssertLessThan(spoken.count, 200, "VoiceOver must not read 4000 characters")
        XCTAssertTrue(spoken.hasPrefix(String(repeating: "x", count: ClipDisplay.summaryLimit)))
        XCTAssertTrue(spoken.hasSuffix("4000 characters"), spoken)
        XCTAssertTrue(spoken.contains("…"))
    }

    func testSummaryAtLimitIsNotTruncated() {
        let exact = String(repeating: "y", count: ClipDisplay.summaryLimit)
        XCTAssertEqual(ClipDisplay.spokenSummary(exact), exact)
    }

    func testCustomSummaryLimit() {
        XCTAssertEqual(ClipDisplay.spokenSummary("abcdef", limit: 3), "abc… 6 characters")
    }

    // MARK: - Preview truncation

    func testShortPreviewIsUntouched() {
        let body = ClipDisplay.previewBody("hello")
        XCTAssertEqual(body.text, "hello")
        XCTAssertNil(body.notice)
    }

    func testHugePreviewIsTruncatedWithNotice() {
        let huge = String(repeating: "z", count: ClipDisplay.previewLimit + 5_000)
        let body = ClipDisplay.previewBody(huge)

        XCTAssertEqual(body.text.count, ClipDisplay.previewLimit)
        XCTAssertNotNil(body.notice)
        XCTAssertTrue(body.notice?.contains("characters") == true)
    }

    func testPreviewLimitBoundary() {
        let exact = String(repeating: "z", count: 10)
        XCTAssertNil(ClipDisplay.previewBody(exact, limit: 10).notice)
        XCTAssertNotNil(ClipDisplay.previewBody(exact, limit: 9).notice)
        XCTAssertEqual(ClipDisplay.previewBody(exact, limit: 4).text, "zzzz")
    }

    // MARK: - File URL display

    func testFileURLIsPercentDecoded() {
        let stored = "file:///Users/me/Documents/my%20file.txt"
        XCTAssertEqual(ClipDisplay.displayPath(stored), "/Users/me/Documents/my file.txt")
        XCTAssertEqual(ClipDisplay.displayName(stored), "my file.txt")
    }

    func testPlainPathPassesThrough() {
        XCTAssertEqual(ClipDisplay.displayPath("/tmp/plain.txt"), "/tmp/plain.txt")
        XCTAssertEqual(ClipDisplay.displayName("/tmp/plain.txt"), "plain.txt")
    }

    func testNonFileURLFallsBackToDecodedString() {
        XCTAssertEqual(
            ClipDisplay.displayPath("https://example.com/a%20b"),
            "https://example.com/a b"
        )
    }

    /// The name from the bug report, spelled exactly as `insertScreenshot`
    /// stores it. Every space is three characters on disk and one on screen.
    func testScreenshotNameLosesItsPercentEncoding() {
        let stored = "file:///Users/me/Desktop/Screenshot%202026-08-16%20at%2019.16.06.png"
        XCTAssertEqual(ClipDisplay.displayName(stored), "Screenshot 2026-08-16 at 19.16.06.png")
    }

    /// Non-ASCII is where the encoding stops being merely ugly: an Arabic
    /// name is stored as a run of `%D8%…` bytes with not one readable
    /// character left in it.
    func testNonASCIINameIsDecodedBackToItsOwnScript() {
        let url = URL(fileURLWithPath: "/Users/me/Documents/تقرير سنوي.pdf")
        XCTAssertTrue(url.absoluteString.contains("%D8"), "precondition: the stored form is encoded")
        XCTAssertEqual(ClipDisplay.displayName(url.absoluteString), "تقرير سنوي.pdf")
        XCTAssertEqual(ClipDisplay.displayPath(url.absoluteString), "/Users/me/Documents/تقرير سنوي.pdf")
    }

    func testAccentedNameIsDecoded() {
        let url = URL(fileURLWithPath: "/Users/me/Café/Menü été.txt")
        XCTAssertEqual(ClipDisplay.displayName(url.absoluteString), "Menü été.txt")
    }

    /// A literal `%` in a name survives the round trip: it is stored as `%25`
    /// and must come back as one sign, not vanish or break the decode.
    func testPercentSignInNameSurvives() {
        let url = URL(fileURLWithPath: "/tmp/100% done.txt")
        XCTAssertEqual(url.absoluteString, "file:///tmp/100%25%20done.txt")
        XCTAssertEqual(ClipDisplay.displayName(url.absoluteString), "100% done.txt")
    }

    func testDisplayNamesJoinsEveryFileDecoded() {
        XCTAssertEqual(
            ClipDisplay.displayNames(["file:///tmp/my%20file.txt", "file:///Users/me/b.png"]),
            "my file.txt, b.png"
        )
        XCTAssertEqual(ClipDisplay.displayNames([]), "")
    }

    // MARK: - File URL search

    func testSearchMatchesTheDecodedName() {
        let stored = ["file:///Users/me/Documents/my%20file.txt"]
        XCTAssertTrue(ClipDisplay.fileURLsMatch(stored, search: "my file"))
        XCTAssertTrue(ClipDisplay.fileURLsMatch(stored, search: "MY FILE"), "search is case-insensitive")
        XCTAssertFalse(ClipDisplay.fileURLsMatch(stored, search: "my%20file"), "nobody types the encoding")
        XCTAssertFalse(ClipDisplay.fileURLsMatch(stored, search: "absent"))
    }

    func testSearchMatchesANonASCIIName() {
        let stored = [URL(fileURLWithPath: "/Users/me/تقرير سنوي.pdf").absoluteString]
        XCTAssertTrue(ClipDisplay.fileURLsMatch(stored, search: "تقرير"))
    }

    // MARK: - Row accessibility label

    func testFullRowLabelOrder() {
        let label = ClipDisplay.rowLabel(
            kind: .image,
            summary: "receipt",
            appName: "Safari",
            relativeTime: "2 minutes ago",
            isPinned: true,
            queuePosition: 2,
            hasExtractedText: true
        )
        XCTAssertEqual(
            label,
            "Image, receipt, from Safari, 2 minutes ago, pinned, queued position 2, contains extracted text"
        )
    }

    func testMinimalRowLabelSkipsEmptyParts() {
        let label = ClipDisplay.rowLabel(
            kind: .text,
            summary: "",
            appName: nil,
            relativeTime: "now"
        )
        XCTAssertEqual(label, "Text, now")
    }

    func testRowLabelIncludesCalcResult() {
        let label = ClipDisplay.rowLabel(
            kind: .text,
            summary: "12*7",
            appName: "Notes",
            relativeTime: "now",
            calcResult: "84"
        )
        XCTAssertEqual(label, "Text, 12*7, equals 84, from Notes, now")
    }

    func testRowLabelTruncatesLongSummary() {
        let label = ClipDisplay.rowLabel(
            kind: .text,
            summary: String(repeating: "a", count: 4000),
            appName: "Notes",
            relativeTime: "now"
        )
        XCTAssertTrue(label.contains("4000 characters"), label)
        XCTAssertLessThan(label.count, 250)
        XCTAssertTrue(label.hasSuffix("from Notes, now"))
    }

    func testRowLabelKindNames() {
        XCTAssertEqual(ClipDisplay.kindLabel(.richText), "Rich text")
        XCTAssertEqual(ClipDisplay.kindLabel(.link), "Link")
        XCTAssertEqual(ClipDisplay.kindLabel(.color), "Color")
        XCTAssertEqual(ClipDisplay.kindLabel(.file), "File")
    }

    func testUnpinnedUnqueuedRowLabelOmitsStateWords() {
        let label = ClipDisplay.rowLabel(
            kind: .link,
            summary: "https://example.com",
            appName: "Safari",
            relativeTime: "1 hour ago"
        )
        XCTAssertFalse(label.contains("pinned"))
        XCTAssertFalse(label.contains("queued"))
        XCTAssertFalse(label.contains("extracted"))
    }
}
