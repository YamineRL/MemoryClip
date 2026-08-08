import AppKit
import XCTest

@testable import MemoryClip

@MainActor
final class PasteServiceTests: XCTestCase {
    /// Every test writes to its own private pasteboard, so a run never
    /// touches (or is disturbed by) the user's real clipboard.
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("memoryclip-paste-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func makeService() throws -> PasteService {
        let store = try ClipStore(inMemory: true)
        return PasteService(store: store, watcher: PasteboardWatcher(store: store), pasteboard: makePasteboard())
    }

    private func makeItem(
        kind: ClipKind,
        text: String? = nil,
        richTextData: Data? = nil,
        imageData: Data? = nil,
        fileURLStrings: [String] = [],
        colorHex: String? = nil
    ) -> ClipItem {
        ClipItem(
            kind: kind,
            text: text,
            richTextData: richTextData,
            imageData: imageData,
            fileURLStrings: fileURLStrings,
            colorHex: colorHex,
            contentHash: UUID().uuidString
        )
    }

    // MARK: writeText (image clips' extracted text)

    func testWriteTextPutsStringOnPasteboard() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()

        XCTAssertTrue(service.writeText("hello from a screenshot", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "hello from a screenshot")
    }

    /// Empty extracted text must leave the clipboard alone rather than
    /// clearing whatever the user already had — same contract as `write`.
    func testWriteTextRejectsEmptyAndPreservesClipboard() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("previous clipboard", forType: .string)

        XCTAssertFalse(service.writeText("", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "previous clipboard")
    }

    private func rtf(_ string: String) throws -> Data {
        let attributed = NSAttributedString(string: string)
        return try XCTUnwrap(
            attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])
        )
    }

    // MARK: Round trips

    func testWritesPlainText() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()

        XCTAssertTrue(service.write(makeItem(kind: .text, text: "hello MemoryClip"), plainOnly: false, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "hello MemoryClip")
    }

    func testWritesLinkAsStringAndURL() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()

        XCTAssertTrue(
            service.write(makeItem(kind: .link, text: "https://example.com"), plainOnly: false, to: pasteboard)
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com")
        XCTAssertEqual(
            pasteboard.string(forType: NSPasteboard.PasteboardType("public.url")),
            "https://example.com"
        )
    }

    func testWritesRichTextWithPlainCompanion() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()
        let data = try rtf("styled")

        XCTAssertTrue(
            service.write(
                makeItem(kind: .richText, text: "styled", richTextData: data),
                plainOnly: false,
                to: pasteboard
            )
        )
        XCTAssertEqual(pasteboard.data(forType: .rtf), data)
        XCTAssertEqual(pasteboard.string(forType: .string), "styled")
    }

    func testPlainOnlyDropsRichData() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()

        XCTAssertTrue(
            service.write(
                makeItem(kind: .richText, text: "styled", richTextData: try rtf("styled")),
                plainOnly: true,
                to: pasteboard
            )
        )
        XCTAssertNil(pasteboard.data(forType: .rtf))
        XCTAssertEqual(pasteboard.string(forType: .string), "styled")
    }

    func testWritesFileURLs() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()

        XCTAssertTrue(
            service.write(
                makeItem(kind: .file, fileURLStrings: ["file:///tmp/a.txt", "file:///tmp/b.txt"]),
                plainOnly: false,
                to: pasteboard
            )
        )
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(urls?.map(\.path), ["/tmp/a.txt", "/tmp/b.txt"])
    }

    func testWritesColorHex() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()

        XCTAssertTrue(
            service.write(makeItem(kind: .color, colorHex: "#FF8800"), plainOnly: false, to: pasteboard)
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "#FF8800")
    }

    // MARK: Failure must not destroy the clipboard

    /// The regression this suite exists for: `write` used to clear the
    /// pasteboard before validating, so every failure path wiped whatever
    /// the user had copied.
    func testWriteReturningFalseLeavesThePasteboardUntouched() throws {
        let service = try makeService()

        let unwritable: [ClipItem] = [
            makeItem(kind: .text, text: nil),
            makeItem(kind: .link, text: nil),
            makeItem(kind: .richText, text: nil, richTextData: nil),
            makeItem(kind: .image, imageData: nil),
            makeItem(kind: .image, imageData: Data()),
            makeItem(kind: .file, fileURLStrings: []),
            makeItem(kind: .color, colorHex: nil),
        ]

        for item in unwritable {
            let pasteboard = makePasteboard()
            pasteboard.setString("PRECIOUS", forType: .string)
            let changeCount = pasteboard.changeCount

            XCTAssertFalse(
                service.write(item, plainOnly: false, to: pasteboard),
                "\(item.kind) with no payload must not report success"
            )
            XCTAssertEqual(
                pasteboard.string(forType: .string),
                "PRECIOUS",
                "\(item.kind) failure destroyed the clipboard"
            )
            XCTAssertEqual(pasteboard.changeCount, changeCount)
        }
    }

    func testPlainOnlyFailureAlsoLeavesThePasteboardUntouched() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()
        pasteboard.setString("PRECIOUS", forType: .string)

        XCTAssertFalse(
            service.write(makeItem(kind: .richText, text: nil), plainOnly: true, to: pasteboard)
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "PRECIOUS")
    }

    // MARK: plainOnly consistency

    /// ⇧Return on a rich clip with no plain text used to "succeed" while
    /// pasting an empty string. Both branches must now agree.
    func testRichTextWithoutAnyTextFailsInBothModes() throws {
        let service = try makeService()
        let item = makeItem(kind: .richText, text: nil, richTextData: nil)

        XCTAssertFalse(service.write(item, plainOnly: true, to: makePasteboard()))
        XCTAssertFalse(service.write(item, plainOnly: false, to: makePasteboard()))
    }

    /// A rich clip that only stored RTF still pastes something readable in
    /// plain mode: the text is derived from the RTF.
    func testPlainOnlyDerivesTextFromRTFWhenPlainTextIsMissing() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()
        let item = makeItem(kind: .richText, text: nil, richTextData: try rtf("derived body"))

        XCTAssertTrue(service.write(item, plainOnly: true, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "derived body")
    }

    // MARK: Image type sniffing

    func testImageTypeSniffing() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 8)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 8)
        let gif = Data("GIF89a".utf8) + Data(repeating: 0, count: 8)
        let tiff = Data([0x49, 0x49, 0x2A, 0x00]) + Data(repeating: 0, count: 8)
        let unknown = Data(repeating: 0xAB, count: 12)

        XCTAssertEqual(PasteService.imageType(for: png), .png)
        XCTAssertEqual(PasteService.imageType(for: jpeg), NSPasteboard.PasteboardType("public.jpeg"))
        XCTAssertEqual(PasteService.imageType(for: gif), NSPasteboard.PasteboardType("com.compuserve.gif"))
        XCTAssertEqual(PasteService.imageType(for: tiff), .tiff)
        XCTAssertEqual(PasteService.imageType(for: unknown), .tiff)
    }

    /// A JPEG used to be written under the TIFF UTI, which receivers cannot
    /// decode.
    func testJPEGIsWrittenAsJPEGNotTIFF() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()
        let jpeg = try XCTUnwrap(makeJPEG())

        XCTAssertTrue(service.write(makeItem(kind: .image, imageData: jpeg), plainOnly: false, to: pasteboard))
        // Declared as JPEG, not mislabelled as TIFF. (AppKit advertises — and
        // converts to — TIFF as a derived flavor, so assert on the type we
        // actually declared: the first one.)
        XCTAssertEqual(pasteboard.types?.first, NSPasteboard.PasteboardType("public.jpeg"))
        XCTAssertEqual(pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")), jpeg)
        // Round trip: the receiver can actually decode what we declared.
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
    }

    func testPNGIsWrittenAsPNG() throws {
        let service = try makeService()
        let pasteboard = makePasteboard()
        let png = try XCTUnwrap(makePNG())

        XCTAssertTrue(service.write(makeItem(kind: .image, imageData: png), plainOnly: false, to: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), png)
    }

    private func makeBitmap() -> NSBitmapImageRep? {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private func makeJPEG() -> Data? {
        makeBitmap()?.representation(using: .jpeg, properties: [:])
    }

    private func makePNG() -> Data? {
        makeBitmap()?.representation(using: .png, properties: [:])
    }
}
