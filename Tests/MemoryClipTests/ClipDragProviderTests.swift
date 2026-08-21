import AppKit
import XCTest

@testable import MemoryClip

/// Covers what a clip hands to the app it is dropped on: one representation
/// per kind, and a file URL — never the bytes — for the kinds that live on
/// disk.
@MainActor
final class ClipDragProviderTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles = []
        super.tearDown()
    }

    private func makeItem(
        kind: ClipKind,
        text: String? = nil,
        richTextData: Data? = nil,
        imageData: Data? = nil,
        fileURLStrings: [String] = [],
        colorHex: String? = nil,
        isScreenshot: Bool = false
    ) -> ClipItem {
        ClipItem(
            kind: kind,
            text: text,
            richTextData: richTextData,
            imageData: imageData,
            fileURLStrings: fileURLStrings,
            colorHex: colorHex,
            contentHash: UUID().uuidString,
            isScreenshot: isScreenshot
        )
    }

    /// A real file on disk, so the file-URL path is exercised against
    /// something `NSItemProvider` can actually type by extension.
    private func makeFile(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data(Self.pngBytes).write(to: url)
        temporaryFiles.append(url)
        return url
    }

    private static let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private func rtf(_ string: String) throws -> Data {
        try XCTUnwrap(
            NSAttributedString(string: string)
                .rtf(from: NSRange(location: 0, length: string.utf16.count), documentAttributes: [:])
        )
    }

    private func loadedData(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                }
            }
        }
    }

    private func loadedString(_ provider: NSItemProvider, type: String) async throws -> String {
        String(decoding: try await loadedData(provider, type: type), as: UTF8.self)
    }

    // MARK: Text

    func testTextClipDragsPlainText() async throws {
        let provider = try XCTUnwrap(
            ClipDragProvider.itemProvider(for: makeItem(kind: .text, text: "hello world"))
        )
        XCTAssertEqual(provider.registeredTypeIdentifiers, [NSPasteboard.PasteboardType.string.rawValue])
        let loaded = try await loadedString(provider, type: NSPasteboard.PasteboardType.string.rawValue)
        XCTAssertEqual(loaded, "hello world")
    }

    func testTextClipWithoutTextHasNoProvider() {
        XCTAssertNil(ClipDragProvider.itemProvider(for: makeItem(kind: .text)))
    }

    func testLinkClipDragsTextAndURL() async throws {
        let provider = try XCTUnwrap(
            ClipDragProvider.itemProvider(for: makeItem(kind: .link, text: "https://example.com"))
        )
        XCTAssertEqual(
            provider.registeredTypeIdentifiers,
            [NSPasteboard.PasteboardType.string.rawValue, "public.url"]
        )
        let loaded = try await loadedString(provider, type: "public.url")
        XCTAssertEqual(loaded, "https://example.com")
    }

    // MARK: Rich text

    func testRichTextClipDragsRTFBeforePlainText() async throws {
        let data = try rtf("formatted")
        let provider = try XCTUnwrap(
            ClipDragProvider.itemProvider(
                for: makeItem(kind: .richText, text: "formatted", richTextData: data)
            )
        )
        XCTAssertEqual(
            provider.registeredTypeIdentifiers,
            [NSPasteboard.PasteboardType.rtf.rawValue, NSPasteboard.PasteboardType.string.rawValue],
            "RTF must come first: a destination takes the first representation it understands"
        )
        let loaded = try await loadedData(provider, type: NSPasteboard.PasteboardType.rtf.rawValue)
        XCTAssertEqual(loaded, data)
        let plain = try await loadedString(provider, type: NSPasteboard.PasteboardType.string.rawValue)
        XCTAssertEqual(plain, "formatted")
    }

    func testRichTextClipWithoutRTFDragsPlainText() throws {
        let provider = try XCTUnwrap(
            ClipDragProvider.itemProvider(for: makeItem(kind: .richText, text: "plain only"))
        )
        XCTAssertEqual(provider.registeredTypeIdentifiers, [NSPasteboard.PasteboardType.string.rawValue])
    }

    // MARK: Images

    func testImageClipDragsBytesUnderTheirSniffedType() async throws {
        let data = Data(Self.pngBytes)
        let provider = try XCTUnwrap(
            ClipDragProvider.itemProvider(for: makeItem(kind: .image, imageData: data))
        )
        XCTAssertEqual(provider.registeredTypeIdentifiers, [NSPasteboard.PasteboardType.png.rawValue])
        let loaded = try await loadedData(provider, type: NSPasteboard.PasteboardType.png.rawValue)
        XCTAssertEqual(loaded, data)
    }

    func testImageClipWithoutBytesHasNoProvider() {
        XCTAssertNil(ClipDragProvider.itemProvider(for: makeItem(kind: .image, imageData: Data())))
    }

    // MARK: Files and screenshots

    func testScreenshotClipDragsItsFileURL() async throws {
        let url = try makeFile(named: "shot.png")
        let provider = try XCTUnwrap(
            ClipDragProvider.itemProvider(
                for: makeItem(
                    kind: .file,
                    fileURLStrings: [url.absoluteString],
                    isScreenshot: true
                )
            )
        )
        XCTAssertTrue(
            provider.registeredTypeIdentifiers.contains("public.file-url"),
            "a screenshot must be dropped as a reference to the file it already is"
        )
        let loaded = try await loadedString(provider, type: "public.file-url")
        XCTAssertEqual(loaded, url.absoluteString)
    }

    /// The bytes must never win over the path: the picture on disk belongs to
    /// the user's screenshot folder, and a drop that took a copy would leave
    /// two of them.
    func testScreenshotClipPrefersItsFileURLOverInlineBytes() async throws {
        let url = try makeFile(named: "shot.png")
        let provider = try XCTUnwrap(
            ClipDragProvider.itemProvider(
                for: makeItem(
                    kind: .file,
                    imageData: Data(Self.pngBytes),
                    fileURLStrings: [url.absoluteString],
                    isScreenshot: true
                )
            )
        )
        let loaded = try await loadedString(provider, type: "public.file-url")
        XCTAssertEqual(loaded, url.absoluteString)
    }

    /// A name with a space is stored percent-encoded; the URL that leaves the
    /// panel has to be the one that still resolves.
    func testFileClipKeepsAnEncodedName() async throws {
        let url = try makeFile(named: "my file.png")
        let provider = try XCTUnwrap(
            ClipDragProvider.itemProvider(for: makeItem(kind: .file, fileURLStrings: [url.absoluteString]))
        )
        let loaded = try await loadedString(provider, type: "public.file-url")
        XCTAssertEqual(URL(string: loaded), url)
    }

    /// `onDrag` yields one provider, so a multi-file clip drags its first file.
    func testMultiFileClipDragsItsFirstFile() async throws {
        let first = try makeFile(named: "first.png")
        let second = try makeFile(named: "second.png")
        let provider = try XCTUnwrap(
            ClipDragProvider.itemProvider(
                for: makeItem(kind: .file, fileURLStrings: [first.absoluteString, second.absoluteString])
            )
        )
        let loaded = try await loadedString(provider, type: "public.file-url")
        XCTAssertEqual(loaded, first.absoluteString)
    }

    func testFileClipWithoutURLsHasNoProvider() {
        XCTAssertNil(ClipDragProvider.itemProvider(for: makeItem(kind: .file)))
    }

    // MARK: Colors

    func testColorClipDragsItsHex() async throws {
        let provider = try XCTUnwrap(
            ClipDragProvider.itemProvider(for: makeItem(kind: .color, text: "#FF0000", colorHex: "#FF0000"))
        )
        XCTAssertEqual(provider.registeredTypeIdentifiers, [NSPasteboard.PasteboardType.string.rawValue])
        let loaded = try await loadedString(provider, type: NSPasteboard.PasteboardType.string.rawValue)
        XCTAssertEqual(loaded, "#FF0000")
    }

    func testColorClipWithoutHexHasNoProvider() {
        XCTAssertNil(ClipDragProvider.itemProvider(for: makeItem(kind: .color)))
    }

    // MARK: Payload reuse

    /// The drag and the paste must not drift apart: every provider is built
    /// from the payload the pasteboard would have been given.
    func testEmptyPayloadYieldsNoProvider() {
        XCTAssertNil(ClipDragProvider.provider(for: PasteService.Payload()))
    }
}
