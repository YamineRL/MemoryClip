import XCTest

@testable import MemoryClip

/// A plain stand-in for `ClipItem`, so the menu logic can be exercised
/// without a SwiftData container.
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

/// Covers which strings the preview pane's right-click menu offers per clip
/// kind.
final class PreviewCopyTests: XCTestCase {
    private func titles(_ options: [PreviewCopyOption]) -> [String] {
        options.map(\.title)
    }

    private func text(_ options: [PreviewCopyOption], _ title: String) -> String? {
        options.first { $0.title == title }?.text
    }

    // MARK: - Text-bearing kinds

    func testTextKindsOfferTheirBody() {
        for kind in [ClipKind.text, .richText, .link] {
            let options = PreviewCopy.options(for: FakeClip(kind: kind, text: "hello"))
            XCTAssertEqual(titles(options), ["Copy Text"], "expected body copy for \(kind)")
            XCTAssertEqual(options.first?.text, "hello")
        }
    }

    func testBodyIsOfferedVerbatim() {
        let options = PreviewCopy.options(for: FakeClip(text: "  padded\n\nlines  "))
        XCTAssertEqual(text(options, "Copy Text"), "  padded\n\nlines  ")
    }

    func testEmptyBodyOffersNothing() {
        XCTAssertTrue(PreviewCopy.options(for: FakeClip(text: nil)).isEmpty)
        XCTAssertTrue(PreviewCopy.options(for: FakeClip(text: "")).isEmpty)
        XCTAssertTrue(PreviewCopy.options(for: FakeClip(text: "   \n ")).isEmpty)
    }

    // MARK: - Translation

    func testTranslationIsASeparateEntryUnderTheBody() {
        let options = PreviewCopy.options(
            for: FakeClip(text: "bonjour"),
            translation: "hello"
        )
        XCTAssertEqual(titles(options), ["Copy Text", "Copy Translation"])
        XCTAssertEqual(text(options, "Copy Translation"), "hello")
    }

    func testNoTranslationEntryWhenNoneIsShown() {
        let options = PreviewCopy.options(for: FakeClip(text: "bonjour"), translation: nil)
        XCTAssertFalse(titles(options).contains("Copy Translation"))
        let blank = PreviewCopy.options(for: FakeClip(text: "bonjour"), translation: "  ")
        XCTAssertFalse(titles(blank).contains("Copy Translation"))
    }

    func testTranslationIsOfferedForAScreenshotToo() {
        let clip = FakeClip(
            kind: .file,
            ocrText: "recognised",
            fileURLStrings: ["file:///tmp/shot.png"],
            isScreenshot: true
        )
        let options = PreviewCopy.options(for: clip, translation: "translated")
        XCTAssertEqual(
            titles(options),
            ["Copy Extracted Text", "Copy Translation", "Copy File Path", "Copy File Name"]
        )
    }

    // MARK: - Images and screenshots

    func testImageOffersItsExtractedText() {
        let options = PreviewCopy.options(for: FakeClip(kind: .image, ocrText: " recognised "))
        XCTAssertEqual(titles(options), ["Copy Extracted Text"])
        XCTAssertEqual(options.first?.text, "recognised")
    }

    func testImageWithoutRecognitionOffersNothing() {
        XCTAssertTrue(PreviewCopy.options(for: FakeClip(kind: .image, ocrText: nil)).isEmpty)
        XCTAssertTrue(PreviewCopy.options(for: FakeClip(kind: .image, ocrText: "  ")).isEmpty)
    }

    func testImageNeverOffersItsOwnTextField() {
        let clip = FakeClip(kind: .image, text: "not shown", ocrText: "recognised")
        XCTAssertEqual(titles(PreviewCopy.options(for: clip)), ["Copy Extracted Text"])
    }

    // MARK: - Files

    func testFileClipOffersDecodedPathsAndNames() {
        let clip = FakeClip(kind: .file, fileURLStrings: ["file:///Users/me/my%20file.txt"])
        let options = PreviewCopy.options(for: clip)
        XCTAssertEqual(titles(options), ["Copy File Path", "Copy File Name"])
        XCTAssertEqual(text(options, "Copy File Path"), "/Users/me/my file.txt")
        XCTAssertEqual(text(options, "Copy File Name"), "my file.txt")
    }

    func testSeveralFilesArePluralAndOnePathPerLine() {
        let clip = FakeClip(kind: .file, fileURLStrings: [
            "file:///Users/me/one.txt",
            "file:///Users/me/two%20three.txt"
        ])
        let options = PreviewCopy.options(for: clip)
        XCTAssertEqual(titles(options), ["Copy File Paths", "Copy File Names"])
        XCTAssertEqual(
            text(options, "Copy File Paths"),
            "/Users/me/one.txt\n/Users/me/two three.txt"
        )
        XCTAssertEqual(text(options, "Copy File Names"), "one.txt, two three.txt")
    }

    func testNoPathIsEverOfferedPercentEncoded() {
        let clip = FakeClip(kind: .file, fileURLStrings: ["file:///Users/me/caf%C3%A9%20menu.pdf"])
        for option in PreviewCopy.options(for: clip) {
            XCTAssertFalse(option.text.contains("%"), "\(option.title) leaked an encoded path")
        }
    }

    func testFileClipWithNoURLsOffersNothing() {
        XCTAssertTrue(PreviewCopy.options(for: FakeClip(kind: .file)).isEmpty)
    }

    func testScreenshotOffersRecognisedTextBeforeItsPath() {
        let clip = FakeClip(
            kind: .file,
            ocrText: "on the screen",
            fileURLStrings: ["file:///Users/me/Screenshot%202026.png"],
            isScreenshot: true
        )
        let options = PreviewCopy.options(for: clip)
        XCTAssertEqual(titles(options), ["Copy Extracted Text", "Copy File Path", "Copy File Name"])
        XCTAssertEqual(text(options, "Copy Extracted Text"), "on the screen")
        XCTAssertEqual(text(options, "Copy File Path"), "/Users/me/Screenshot 2026.png")
    }

    // MARK: - Colour

    func testColorOffersItsHex() {
        let options = PreviewCopy.options(for: FakeClip(kind: .color, colorHex: "#FF8800"))
        XCTAssertEqual(titles(options), ["Copy Hex"])
        XCTAssertEqual(options.first?.text, "#FF8800")
    }

    func testColorWithoutHexOffersNothing() {
        XCTAssertTrue(PreviewCopy.options(for: FakeClip(kind: .color, colorHex: nil)).isEmpty)
    }
}
