import AppKit
import XCTest

@testable import MemoryClip

@MainActor
final class ContentParserTests: XCTestCase {
    /// Each test gets its own pasteboard so runs never interfere with each
    /// other (or with the user's real clipboard).
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("memoryclip-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    func testPlainText() {
        let pasteboard = makePasteboard()
        pasteboard.setString("  hello MemoryClip  ", forType: .string)

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .text)
        // The stored text must be the ORIGINAL (untrimmed) string.
        XCTAssertEqual(clip?.text, "  hello MemoryClip  ")
        XCTAssertNil(clip?.colorHex)
        XCTAssertTrue(clip?.fileURLStrings.isEmpty ?? false)
    }

    func testWhitespaceOnlyStringIsIgnored() {
        let pasteboard = makePasteboard()
        pasteboard.setString("   \n\t  ", forType: .string)

        XCTAssertNil(ContentParser.parse(pasteboard))
    }

    func testHexColorString() {
        let pasteboard = makePasteboard()
        pasteboard.setString("#ff8800", forType: .string)

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .color)
        XCTAssertEqual(clip?.text, "#FF8800")
        XCTAssertEqual(clip?.colorHex, "#FF8800")
    }

    func testBareHexWithoutHashIsPlainText() {
        let pasteboard = makePasteboard()
        pasteboard.setString("1a2b3c", forType: .string)

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .text)
        XCTAssertEqual(clip?.text, "1a2b3c")
        XCTAssertNil(clip?.colorHex)
    }

    func testWebURLWithScheme() {
        let pasteboard = makePasteboard()
        pasteboard.setString("https://example.com/path?q=1", forType: .string)

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .link)
        XCTAssertEqual(clip?.text, "https://example.com/path?q=1")
    }

    func testBareWWWDomainIsLink() {
        let pasteboard = makePasteboard()
        pasteboard.setString("www.example.com", forType: .string)

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .link)
        XCTAssertEqual(clip?.text, "www.example.com")
    }

    func testMultiLineStringWithURLIsPlainText() {
        let pasteboard = makePasteboard()
        pasteboard.setString("https://a.com\nmore text", forType: .string)

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .text)
        XCTAssertEqual(clip?.text, "https://a.com\nmore text")
    }

    func testRichText() {
        let pasteboard = makePasteboard()
        let rtf = NSAttributedString(string: "styled").rtf(
            from: NSRange(location: 0, length: 6),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )!
        pasteboard.setString("styled", forType: .string)
        pasteboard.setData(rtf, forType: .rtf)

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .richText)
        XCTAssertEqual(clip?.text, "styled")
        XCTAssertEqual(clip?.richTextData, rtf)
    }

    /// A link copied out of a rich editor carries RTF next to the string; it
    /// must still capture as `.link` so the cleaner runs on it.
    func testRichTextCarryingBareURLIsALink() {
        let pasteboard = makePasteboard()
        let dirty = "https://www.instagram.com/reel/DbGys85Oyxx/?igsh=MXhkbjFxcjlxNHJvdQ=="
        let attributed = NSAttributedString(
            string: dirty,
            attributes: [.link: URL(string: dirty)!]
        )
        let rtf = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )!
        pasteboard.setString(dirty, forType: .string)
        pasteboard.setData(rtf, forType: .rtf)

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .link)
        XCTAssertNil(clip?.richTextData)
    }

    func testRichTextWithURLAmongWordsStaysRichText() {
        let pasteboard = makePasteboard()
        let text = "see https://example.com/?utm_source=x for details"
        let attributed = NSAttributedString(string: text)
        let rtf = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )!
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(rtf, forType: .rtf)

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .richText)
        XCTAssertEqual(clip?.text, text)
        XCTAssertEqual(clip?.richTextData, rtf)
    }

    func testMultiLineRichTextStaysRichText() {
        let pasteboard = makePasteboard()
        let text = "https://example.com/?utm_source=x\nsecond line"
        let attributed = NSAttributedString(string: text)
        let rtf = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )!
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(rtf, forType: .rtf)

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .richText)
        XCTAssertEqual(clip?.text, text)
        XCTAssertEqual(clip?.richTextData, rtf)
    }

    func testImage() {
        let pasteboard = makePasteboard()
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 4,
                pixelsHigh: 4,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 16,
                bitsPerPixel: 32
            ),
            let png = rep.representation(using: .png, properties: [:])
        else {
            return XCTFail("Could not build test bitmap")
        }
        pasteboard.setData(png, forType: .png)

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .image)
        XCTAssertNotNil(clip?.imageData)
        if let data = clip?.imageData {
            XCTAssertNotNil(NSImage(data: data))
        }
    }

    /// P3.11: a pasteboard image has a budget. Past `maxImageBytes` the clip
    /// is skipped entirely — captured "for free" was the old behaviour, and
    /// a multi-hundred-megabyte photo is better handled as the file it
    /// usually also is on the board.
    func testAnImageOverTheByteCapIsSkipped() {
        let pasteboard = makePasteboard()
        let oversized = Data(repeating: 0x89, count: ContentParser.maxImageBytes + 1)
        pasteboard.setData(oversized, forType: .png)

        XCTAssertNil(
            ContentParser.parse(pasteboard),
            "an image over \(ContentParser.maxImageBytes) bytes must not be captured"
        )
    }

    /// The encoded-type preference: a board offering both PNG data and an
    /// NSImage representation keeps the encoded bytes — no TIFF decode, no
    /// PNG re-encode on the main actor.
    func testImagePrefersTheEncodedRepresentation() {
        let pasteboard = makePasteboard()
        let encoded = Data("pretend-png".utf8)
        pasteboard.setData(encoded, forType: .png)

        XCTAssertEqual(ContentParser.imageData(from: pasteboard), encoded)
    }

    /// `pixelSize` answers from the header — the guard that enforces
    /// `maxImagePixels` never decodes a bitmap.
    func testPixelSizeReadsTheHeaderOnly() throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 6,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 16,
            bitsPerPixel: 32
        )
        let png = try XCTUnwrap(rep?.representation(using: .png, properties: [:]))

        let size = try XCTUnwrap(ContentParser.pixelSize(of: png))
        XCTAssertEqual(size.width, 4)
        XCTAssertEqual(size.height, 6)
        XCTAssertEqual(size.pixels, 24)
    }

    /// Garbage under an image type is data, not pixels — still bounded by
    /// bytes, tolerated by the pixel check rather than rejected for being
    /// unparseable.
    func testNonImageBytesAreCapturedWithinTheByteCap() {
        let pasteboard = makePasteboard()
        let bytes = Data("not really a png".utf8)
        pasteboard.setData(bytes, forType: .png)

        XCTAssertEqual(ContentParser.imageData(from: pasteboard), bytes)
    }

    func testFileURLs() {
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/memoryclip-test.txt")])

        let clip = ContentParser.parse(pasteboard)

        XCTAssertEqual(clip?.kind, .file)
        XCTAssertEqual(clip?.fileURLStrings, ["file:///tmp/memoryclip-test.txt"])
    }

    /// Loops the REAL set rather than naming one marker, so deleting any
    /// line from `ContentParser.excludedTypes` — `ConcealedType` above all,
    /// which is what password managers actually set — fails the suite.
    func testEveryExcludedTypeIsSkipped() {
        XCTAssertFalse(ContentParser.excludedTypes.isEmpty)
        for type in ContentParser.excludedTypes {
            let pasteboard = makePasteboard()
            pasteboard.declareTypes([.string, type], owner: nil)
            pasteboard.setString("secret", forType: .string)

            XCTAssertNil(ContentParser.parse(pasteboard), "\(type.rawValue) must be excluded")
        }
    }

    func testExcludedTypesCoverTheKnownOptOutMarkers() {
        let expected: Set<String> = [
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType",
            "org.nspasteboard.ConcealedType",
            "com.typeit4me.clipping",
        ]
        XCTAssertTrue(
            expected.isSubset(of: Set(ContentParser.excludedTypes.map(\.rawValue))),
            "An opt-out marker was removed from ContentParser.excludedTypes"
        )
    }

    func testHashStability() {
        let first = makePasteboard()
        first.setString("same text", forType: .string)
        let second = makePasteboard()
        second.setString("same text", forType: .string)
        let third = makePasteboard()
        third.setString("other text", forType: .string)

        let hash1 = ContentParser.parse(first)?.hash
        let hash2 = ContentParser.parse(second)?.hash
        let hash3 = ContentParser.parse(third)?.hash

        XCTAssertNotNil(hash1)
        XCTAssertEqual(hash1, hash2)
        XCTAssertNotEqual(hash1, hash3)
    }
}
