import AppKit
import XCTest

@testable import MemoryClip

/// What a screenshot clip is, and — more importantly — what it is not
/// allowed to do to the user's file.
@MainActor
final class ScreenshotClipTests: XCTestCase {
    /// A `let` with a `nonisolated` accessor: XCTest's `setUp`/`tearDown`
    /// overrides are nonisolated, so a main-actor `var` assigned there is a
    /// concurrency warning under Swift 6.
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ScreenshotClipTests-\(UUID().uuidString)", isDirectory: true)
    private nonisolated var directory: URL { root }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A real PNG on disk, so the thumbnail and OCR paths have something to
    /// decode.
    @discardableResult
    private func writePNG(named name: String, text: String = "HELLO") throws -> URL {
        let size = NSSize(width: 320, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(
            at: NSPoint(x: 12, y: 40),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 48, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
        )
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw XCTSkip("Could not render a PNG in this environment") }

        let url = directory.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    func testScreenshotClipReferencesTheFileAndStoresNoBlob() throws {
        let url = try writePNG(named: "Screenshot 1.png")
        let store = try ClipStore(inMemory: true)

        let item = try XCTUnwrap(store.insertScreenshot(at: url))

        XCTAssertTrue(item.isScreenshot)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.fileURLStrings, [url.absoluteString])
        // The whole point: the bytes stay on disk. A day of retina
        // screenshots would otherwise be hundreds of megabytes in the store.
        XCTAssertTrue((item.imageData ?? Data()).isEmpty)
        XCTAssertEqual(item.sourceAppName, ClipStore.screenshotSourceName)
    }

    func testDeletingAScreenshotClipLeavesTheFileAlone() throws {
        let url = try writePNG(named: "Screenshot 2.png")
        let store = try ClipStore(inMemory: true)
        let item = try XCTUnwrap(store.insertScreenshot(at: url))

        store.delete(item)

        XCTAssertTrue(store.recent(limit: 10).isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Deleting a clip must never delete the user's screenshot"
        )
    }

    func testTrimmingAndClearingHistoryLeaveTheFileAlone() throws {
        let url = try writePNG(named: "Screenshot 3.png")
        let store = try ClipStore(inMemory: true)
        store.insertScreenshot(at: url)

        store.nukeAll()

        XCTAssertTrue(store.recent(limit: 10).isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Clearing history must never delete the user's screenshots"
        )
    }

    func testSameScreenshotSeenTwiceDoesNotDuplicate() throws {
        let url = try writePNG(named: "Screenshot 4.png")
        let store = try ClipStore(inMemory: true)

        let first = try XCTUnwrap(store.insertScreenshot(at: url))
        let second = try XCTUnwrap(store.insertScreenshot(at: url))

        XCTAssertEqual(first.uuid, second.uuid)
        XCTAssertEqual(store.recent(limit: 10).count, 1)
    }

    /// A screenshot overwritten in place keeps its URL — and its dedup hash —
    /// but not its pixels. Everything derived from the old file is stale:
    /// the next capture must reset OCR, thumbnail and refinement state so the
    /// pipelines run again against the new bytes.
    func testARewrittenFileInvalidatesWhatWasDerivedFromIt() throws {
        let url = try writePNG(named: "Screenshot 5a.png", text: "FIRST")
        let store = try ClipStore(inMemory: true)
        let item = try XCTUnwrap(store.insertScreenshot(at: url))

        // Simulate the pipelines having run against the first file.
        store.applyOCR("FIRST", toClipWith: item.uuid, revision: item.contentRevision)
        store.applyThumbnail(Data([1, 2, 3]), toClipWith: item.uuid, revision: item.contentRevision)
        item.refinedTitle = "First screenshot"
        store.save()
        let before = item.contentRevision

        // macOS replaces a screenshot in place: same path, new bytes (a
        // different length also moves the signature's size half).
        try? FileManager.default.removeItem(at: url)
        let rewritten = try writePNG(named: url.lastPathComponent, text: "SECOND VERSION")
        XCTAssertEqual(rewritten, url)

        let reseen = try XCTUnwrap(store.insertScreenshot(at: url))

        XCTAssertEqual(reseen.uuid, item.uuid, "same path adopts the same row")
        XCTAssertNotEqual(reseen.contentRevision, before)
        XCTAssertNil(reseen.ocrText)
        XCTAssertFalse(reseen.ocrAttempted, "the new pixels have not been recognised")
        XCTAssertNil(reseen.thumbnailData)
        XCTAssertFalse(reseen.thumbnailAttempted)
        XCTAssertNil(reseen.refinedTitle)
        XCTAssertFalse(reseen.refineAttempted)
        XCTAssertFalse(
            store.pendingOCR(limit: 10).isEmpty,
            "the rewritten screenshot must re-enter the OCR backlog"
        )
    }

    /// Same bytes rewritten (a tool touching the file without changing it
    /// meaningfully) — signature unchanged, nothing is invalidated.
    func testAnIdenticalRewriteKeepsTheDerivedState() throws {
        let url = try writePNG(named: "Screenshot 5b.png", text: "SAME")
        let store = try ClipStore(inMemory: true)
        let item = try XCTUnwrap(store.insertScreenshot(at: url))
        store.applyOCR("SAME", toClipWith: item.uuid, revision: item.contentRevision)
        let before = item.contentRevision
        let signature = item.screenshotSignature

        // Rewrite the same bytes back — same size; force the same mtime so
        // the signature cannot differ.
        let bytes = try Data(contentsOf: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        try bytes.write(to: url)
        try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)

        let reseen = try XCTUnwrap(store.insertScreenshot(at: url))
        XCTAssertEqual(reseen.screenshotSignature, signature)
        XCTAssertEqual(reseen.contentRevision, before)
        XCTAssertEqual(reseen.ocrText, "SAME")
        XCTAssertTrue(reseen.ocrAttempted)
    }

    func testAFileClipForTheSamePathIsAdoptedRatherThanDuplicated() throws {
        let url = try writePNG(named: "Screenshot 5.png")
        let store = try ClipStore(inMemory: true)

        // The user copied the screenshot in Finder before the watcher got to
        // it: same path, same hash, so it must become the same row.
        store.insert(
            CapturedClip(
                kind: .file,
                text: nil,
                richTextData: nil,
                imageData: nil,
                fileURLStrings: [url.absoluteString],
                colorHex: nil,
                hash: ContentParser.hashText("file:" + url.absoluteString)
            ),
            sourceBundleID: "com.apple.finder",
            sourceAppName: "Finder"
        )
        let adopted = try XCTUnwrap(store.insertScreenshot(at: url))

        XCTAssertEqual(store.recent(limit: 10).count, 1)
        XCTAssertTrue(adopted.isScreenshot, "The existing file clip should join the screenshot pipeline")
    }

    func testScreenshotClipsEnterTheOCRAndThumbnailBacklogs() throws {
        let url = try writePNG(named: "Screenshot 6.png")
        let store = try ClipStore(inMemory: true)
        store.insertScreenshot(at: url)

        XCTAssertEqual(store.pendingOCR(limit: 10).count, 1)
        XCTAssertEqual(store.pendingThumbnails(limit: 10).count, 1)
    }

    func testOrdinaryFileClipsStayOutOfThoseBacklogs() throws {
        let store = try ClipStore(inMemory: true)
        store.insert(
            CapturedClip(
                kind: .file,
                text: nil,
                richTextData: nil,
                imageData: nil,
                fileURLStrings: ["file:///tmp/report.pdf"],
                colorHex: nil,
                hash: ContentParser.hashText("file:file:///tmp/report.pdf")
            ),
            sourceBundleID: nil,
            sourceAppName: nil
        )

        // Copying a folder of documents must not queue a hundred recognition
        // passes.
        XCTAssertTrue(store.pendingOCR(limit: 10).isEmpty)
        XCTAssertTrue(store.pendingThumbnails(limit: 10).isEmpty)
    }

    func testThumbnailIsBuiltFromTheFileWithoutAdoptingItsBytes() async throws {
        let url = try writePNG(named: "Screenshot 7.png")
        let store = try ClipStore(inMemory: true)
        store.insertScreenshot(at: url)

        await store.backfillThumbnails(batchSize: 4)

        let item = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertTrue(item.thumbnailAttempted)
        let thumbnail = try XCTUnwrap(item.thumbnailData)
        XCTAssertFalse(thumbnail.isEmpty)
        // Thumbnailing an inline blob rewrites it (that is how old rows move
        // to external storage); a screenshot's bytes must NOT be pulled into
        // the row on the way past.
        XCTAssertTrue((item.imageData ?? Data()).isEmpty)
    }

    func testAMissingFileIsMarkedAttemptedRatherThanRetriedForever() async throws {
        let url = try writePNG(named: "Screenshot 8.png")
        let store = try ClipStore(inMemory: true)
        store.insertScreenshot(at: url)
        try FileManager.default.removeItem(at: url)

        await store.backfillThumbnails(batchSize: 4)

        let item = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertTrue(item.thumbnailAttempted)
        XCTAssertNil(item.thumbnailData)
        XCTAssertTrue(store.pendingThumbnails(limit: 10).isEmpty)
    }

    func testRefinementQueueOnlyHoldsClipsWithRecognisedText() throws {
        let store = try ClipStore(inMemory: true)
        let url = try writePNG(named: "Screenshot 9.png")
        let item = try XCTUnwrap(store.insertScreenshot(at: url))

        // Nothing recognised yet: nothing to refine.
        XCTAssertTrue(store.pendingRefinement(limit: 10).isEmpty)

        store.applyOCR("some words on screen", toClipWith: item.uuid, revision: 0)
        XCTAssertEqual(store.pendingRefinement(limit: 10).count, 1)

        store.applyRefinement(
            title: "Some words",
            summary: "A screenshot with words.",
            text: "some words on screen",
            tags: ["screenshot"],
            toClipWith: item.uuid,
            revision: 0
        )
        XCTAssertTrue(store.pendingRefinement(limit: 10).isEmpty, "A refined clip must not be re-queued")

        let refined = try XCTUnwrap(store.item(withUUID: item.uuid))
        XCTAssertEqual(refined.refinedTitle, "Some words")
        XCTAssertEqual(refined.refinedTags, ["screenshot"])
        XCTAssertTrue(refined.refineAttempted)
        // The recognition itself is untouched — the model's output is a
        // convenience layer over it, never a replacement.
        XCTAssertEqual(refined.ocrText, "some words on screen")
    }

    func testRefinementIsDroppedWhenItCarriesACardNumber() throws {
        UserDefaults.standard.set(true, forKey: SensitiveFilter.filteringEnabledKey)
        let store = try ClipStore(inMemory: true)
        let url = try writePNG(named: "Screenshot 10.png")
        let item = try XCTUnwrap(store.insertScreenshot(at: url))
        store.applyOCR("checkout page", toClipWith: item.uuid, revision: 0)

        store.applyRefinement(
            title: "Card 4111 1111 1111 1111",
            summary: "",
            text: "Card 4111 1111 1111 1111 on file",
            tags: ["billing"],
            toClipWith: item.uuid,
            revision: 0
        )

        let refined = try XCTUnwrap(store.item(withUUID: item.uuid))
        // A note is a plaintext file outside the 0600 store — this is the
        // last place to stop a card number reaching one.
        XCTAssertNil(refined.refinedText)
        XCTAssertNil(refined.refinedTitle)
        XCTAssertTrue(refined.refinedTags.isEmpty)
        XCTAssertTrue(refined.refineAttempted, "Still attempted, so it is not retried forever")
    }
}
