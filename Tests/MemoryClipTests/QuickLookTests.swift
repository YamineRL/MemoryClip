import AppKit
import XCTest

@testable import MemoryClip

/// A plain stand-in for `ClipItem`, so the Quick Look decisions can be
/// exercised without a SwiftData container — and without a window server,
/// which `QLPreviewPanel` itself would need.
private struct FakeClip: ClipDisplayable {
    var uuid = UUID()
    var kind: ClipKind = .text
    var text: String?
    var ocrText: String?
    var colorHex: String?
    var fileURLStrings: [String] = []
    var sourceAppName: String?
    var refinedTitle: String?
    var isScreenshot = false
}

private func fileClip(path: String, isScreenshot: Bool = false) -> FakeClip {
    FakeClip(
        kind: .file,
        fileURLStrings: [URL(fileURLWithPath: path).absoluteString],
        isScreenshot: isScreenshot
    )
}

/// Which clips Quick Look can show, in what order, where Space lands, and
/// where the temp files for pasteboard images go.
final class QuickLookTests: XCTestCase {
    // MARK: - What qualifies

    func testPasteboardImageClipsQualify() {
        XCTAssertTrue(QuickLook.canPreview(FakeClip(kind: .image)))
        XCTAssertEqual(QuickLook.source(for: FakeClip(kind: .image)), .pasteboardImage)
    }

    func testScreenshotClipsQualifyThroughTheirFile() {
        let clip = fileClip(path: "/tmp/Screenshot 2026-08-16.png", isScreenshot: true)
        XCTAssertEqual(
            QuickLook.source(for: clip),
            .file(URL(fileURLWithPath: "/tmp/Screenshot 2026-08-16.png"))
        )
    }

    func testOrdinaryFileClipsQualify() {
        XCTAssertTrue(QuickLook.canPreview(fileClip(path: "/tmp/report.pdf")))
    }

    /// The kinds the preview pane keeps: Space closes it again rather than
    /// escalating.
    func testTextRichTextLinkAndColorDoNotQualify() {
        for kind in [ClipKind.text, .richText, .link, .color] {
            XCTAssertFalse(
                QuickLook.canPreview(FakeClip(kind: kind, text: "hello")),
                "expected \(kind) to stay in the preview pane"
            )
        }
    }

    func testFileClipWithoutAUsableURLDoesNotQualify() {
        XCTAssertFalse(QuickLook.canPreview(FakeClip(kind: .file)))
        // A remote URL is a file clip in name only; there is nothing on disk.
        XCTAssertFalse(QuickLook.canPreview(FakeClip(kind: .file, fileURLStrings: ["https://example.com/a.pdf"])))
    }

    /// `fileURLStrings` holds `absoluteString`, so a name with spaces is
    /// stored percent-encoded and only the encoded form survives the trip back
    /// to the filesystem.
    func testPercentEncodedNamesRoundTripToTheRealPath() {
        let clip = fileClip(path: "/tmp/my file.png")
        guard case .file(let url)? = QuickLook.source(for: clip) else {
            return XCTFail("expected a file source")
        }
        XCTAssertEqual(url.path(percentEncoded: false), "/tmp/my file.png")
    }

    // MARK: - Titles

    func testFileClipsAreTitledWithTheirName() {
        XCTAssertEqual(QuickLook.title(for: fileClip(path: "/tmp/my file.png")), "my file.png")
    }

    func testPasteboardImagesFallBackToTheRefinedTitleThenTheKind() {
        XCTAssertEqual(
            QuickLook.title(for: FakeClip(kind: .image, refinedTitle: "Build log")),
            "Build log"
        )
        XCTAssertEqual(QuickLook.title(for: FakeClip(kind: .image)), "Image")
        XCTAssertEqual(
            QuickLook.title(for: FakeClip(kind: .image, refinedTitle: "   ")),
            "Image"
        )
    }

    // MARK: - The list Quick Look pages through

    func testPlanKeepsOnlyPreviewableClipsInListOrder() {
        let text = FakeClip(kind: .text, text: "note")
        let image = FakeClip(kind: .image)
        let color = FakeClip(kind: .color, colorHex: "#FF0000")
        let shot = fileClip(path: "/tmp/a.png", isScreenshot: true)

        let plan = QuickLook.plan(for: [text, image, color, shot], startingAt: shot.uuid)
        XCTAssertEqual(plan?.items.map(\.uuid), [image.uuid, shot.uuid])
    }

    func testPlanPositionsOnTheInvokedClip() {
        let clips = (0..<4).map { _ in FakeClip(kind: .image) }
        for (index, clip) in clips.enumerated() {
            XCTAssertEqual(QuickLook.plan(for: clips, startingAt: clip.uuid)?.index, index)
        }
    }

    /// The index counts previewable clips, not rows: a text clip between two
    /// pictures must not shift the picture Quick Look opens on.
    func testPlanIndexIgnoresSkippedClips() {
        let first = FakeClip(kind: .image)
        let text = FakeClip(kind: .text, text: "in between")
        let second = FakeClip(kind: .image)
        XCTAssertEqual(QuickLook.plan(for: [first, text, second], startingAt: second.uuid)?.index, 1)
    }

    func testPlanIsNilWhenTheInvokedClipCannotBePreviewed() {
        let text = FakeClip(kind: .text, text: "note")
        let image = FakeClip(kind: .image)
        XCTAssertNil(QuickLook.plan(for: [text, image], startingAt: text.uuid))
    }

    func testPlanIsNilWhenTheInvokedClipIsNoLongerInTheList() {
        XCTAssertNil(QuickLook.plan(for: [FakeClip(kind: .image)], startingAt: UUID()))
        XCTAssertNil(QuickLook.plan(for: [FakeClip](), startingAt: UUID()))
    }

    // MARK: - What Space does

    func testSpaceOpensThePaneWhenItIsClosed() {
        XCTAssertEqual(
            QuickLook.spaceAction(previewVisible: false, canQuickLook: true), .openPreview
        )
        XCTAssertEqual(
            QuickLook.spaceAction(previewVisible: false, canQuickLook: false), .openPreview
        )
    }

    func testSpaceEscalatesToQuickLookOnAnOpenPane() {
        XCTAssertEqual(
            QuickLook.spaceAction(previewVisible: true, canQuickLook: true), .openQuickLook
        )
    }

    func testSpaceStillClosesThePaneOnClipsQuickLookCannotShow() {
        XCTAssertEqual(
            QuickLook.spaceAction(previewVisible: true, canQuickLook: false), .closePreview
        )
    }

    // MARK: - Temp files for pasteboard images

    private func makeImage(width: Int = 40, height: Int = 30) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: 0.1, green: 0.6, blue: 0.3, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "QuickLookTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// The extension follows the bytes. A JPEG named `.png` is a preview that
    /// renders through the wrong generator, or not at all.
    func testExtensionIsReadOutOfTheImageRatherThanAssumed() throws {
        let rep = try makeImage()
        XCTAssertEqual(
            QuickLookCache.fileExtension(forImageData: try XCTUnwrap(rep.representation(using: .png, properties: [:]))),
            "png"
        )
        XCTAssertEqual(
            QuickLookCache.fileExtension(forImageData: try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))),
            "jpeg"
        )
        XCTAssertEqual(
            QuickLookCache.fileExtension(forImageData: try XCTUnwrap(rep.representation(using: .tiff, properties: [:]))),
            "tiff"
        )
    }

    func testUnidentifiableBytesGetNoExtensionAndNoFile() throws {
        XCTAssertNil(QuickLookCache.fileExtension(forImageData: Data()))
        XCTAssertNil(QuickLookCache.fileExtension(forImageData: Data("not a picture".utf8)))

        let directory = try makeScratchDirectory()
        XCTAssertNil(try QuickLookCache.fileURL(
            forClip: UUID(), imageData: Data("not a picture".utf8), in: directory
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFileIsNamedAfterTheClipAndHoldsTheBytes() throws {
        let data = try XCTUnwrap(makeImage().representation(using: .png, properties: [:]))
        let uuid = UUID()
        let directory = try makeScratchDirectory()

        let url = try XCTUnwrap(try QuickLookCache.fileURL(forClip: uuid, imageData: data, in: directory))
        XCTAssertEqual(url.lastPathComponent, "\(uuid.uuidString).png")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    /// Second invocation reuses the file rather than writing another copy of a
    /// retina screenshot. Proved by leaving a sentinel in the file: a rewrite
    /// would replace it.
    func testAnExistingFileIsReusedRatherThanRewritten() throws {
        let data = try XCTUnwrap(makeImage().representation(using: .png, properties: [:]))
        let uuid = UUID()
        let directory = try makeScratchDirectory()

        let first = try XCTUnwrap(try QuickLookCache.fileURL(forClip: uuid, imageData: data, in: directory))
        let sentinel = Data("already here".utf8)
        try sentinel.write(to: first)

        let second = try XCTUnwrap(try QuickLookCache.fileURL(forClip: uuid, imageData: data, in: directory))
        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: second), sentinel)
    }

    /// A zero-byte file is the trace of a write that died half way; rewriting
    /// it costs less than a blank preview that never heals.
    func testAnEmptyFileIsWrittenAgain() throws {
        let data = try XCTUnwrap(makeImage().representation(using: .png, properties: [:]))
        let uuid = UUID()
        let directory = try makeScratchDirectory()

        let first = try XCTUnwrap(try QuickLookCache.fileURL(forClip: uuid, imageData: data, in: directory))
        try Data().write(to: first)

        let second = try XCTUnwrap(try QuickLookCache.fileURL(forClip: uuid, imageData: data, in: directory))
        XCTAssertEqual(try Data(contentsOf: second), data)
    }

    func testTwoClipsGetTwoFiles() throws {
        let data = try XCTUnwrap(makeImage().representation(using: .png, properties: [:]))
        let directory = try makeScratchDirectory()

        let first = try QuickLookCache.fileURL(forClip: UUID(), imageData: data, in: directory)
        let second = try QuickLookCache.fileURL(forClip: UUID(), imageData: data, in: directory)
        XCTAssertNotEqual(first, second)
    }

    /// The clips being spilled here are copies of whatever was on the user's
    /// clipboard, and the caches directory they land in is world-readable.
    func testTheDirectoryIsOwnerOnly() throws {
        let data = try XCTUnwrap(makeImage().representation(using: .png, properties: [:]))
        let directory = try makeScratchDirectory()
        _ = try QuickLookCache.fileURL(forClip: UUID(), imageData: data, in: directory)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testTheDefaultDirectoryIsNamespacedInsideCaches() {
        let path = QuickLookCache.directory.path
        XCTAssertTrue(path.hasSuffix("/app.memoryclip/QuickLook"), path)
        XCTAssertTrue(path.contains("/Caches/"), path)
    }
}
