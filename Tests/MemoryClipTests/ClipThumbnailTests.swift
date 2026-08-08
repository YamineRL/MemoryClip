import AppKit
import XCTest

@testable import MemoryClip

/// Thumbnails: generation, and the lazy backfill that gives pre-existing
/// image clips one without reading every blob at launch.
@MainActor
final class ClipThumbnailTests: XCTestCase {
    private func makeStore(cap: Int = 1000, retentionDays: Int = 0) throws -> ClipStore {
        UserDefaults.standard.set(cap, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(retentionDays, forKey: SettingsKeys.retentionDays)
        return try ClipStore(inMemory: true)
    }

    /// A PNG big enough that a thumbnail is a real reduction.
    private func makePNG(width: Int = 1200, height: Int = 800, seed: Int = 0) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for row in 0..<40 {
            NSColor(calibratedWhite: Double((row + seed) % 10) / 10.0, alpha: 1).setFill()
            NSRect(x: 0, y: row * 20, width: width, height: 8).fill()
        }
        ("thumbnail fixture \(seed)" as NSString).draw(
            at: NSPoint(x: 20, y: 20),
            withAttributes: [.font: NSFont.systemFont(ofSize: 42)]
        )
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func imageClip(_ marker: String, data: Data) -> CapturedClip {
        CapturedClip(
            kind: .image,
            text: nil,
            richTextData: nil,
            imageData: data,
            fileURLStrings: [],
            colorHex: nil,
            hash: ContentParser.hashText("image:\(marker)")
        )
    }

    // MARK: - Generation

    func testThumbnailIsMuchSmallerThanTheOriginalAndFitsTheBox() throws {
        let png = try makePNG()
        let thumbnail = try XCTUnwrap(ClipThumbnail.make(from: png))

        XCTAssertLessThan(
            thumbnail.count, png.count / 10,
            "A row thumbnail must be a fraction of the blob it replaces"
        )
        let decoded = try XCTUnwrap(NSImage(data: thumbnail))
        let rep = try XCTUnwrap(decoded.representations.first)
        XCTAssertLessThanOrEqual(max(rep.pixelsWide, rep.pixelsHigh), ClipThumbnail.maxPixelSize)
        XCTAssertGreaterThan(min(rep.pixelsWide, rep.pixelsHigh), 0)
    }

    func testThumbnailHonoursAnExplicitMaxPixelSize() throws {
        let png = try makePNG()
        let thumbnail = try XCTUnwrap(ClipThumbnail.make(from: png, maxPixelSize: 32))
        let rep = try XCTUnwrap(NSImage(data: thumbnail)?.representations.first)
        XCTAssertLessThanOrEqual(max(rep.pixelsWide, rep.pixelsHigh), 32)
    }

    func testThumbnailOfNonImageDataIsNil() {
        XCTAssertNil(ClipThumbnail.make(from: Data("not an image".utf8)))
        XCTAssertNil(ClipThumbnail.make(from: Data()))
    }

    func testAspectRatioIsPreserved() throws {
        let png = try makePNG(width: 1200, height: 300)
        let rep = try XCTUnwrap(
            NSImage(data: try XCTUnwrap(ClipThumbnail.make(from: png)))?.representations.first
        )
        XCTAssertEqual(Double(rep.pixelsWide) / Double(rep.pixelsHigh), 4, accuracy: 0.35)
    }

    // MARK: - Backfill

    func testCapturedImageGetsAThumbnail() async throws {
        let store = try makeStore()
        let png = try makePNG()
        store.insert(imageClip("a", data: png), sourceBundleID: nil, sourceAppName: nil)

        await store.backfillThumbnails()

        let item = try XCTUnwrap(store.recent(limit: 1).first)
        let thumbnail = try XCTUnwrap(item.thumbnailData)
        XCTAssertTrue(item.thumbnailAttempted)
        XCTAssertLessThan(thumbnail.count, png.count / 10)
        XCTAssertNotNil(NSImage(data: thumbnail))
    }

    func testBackfillFillsPreExistingImageClips() async throws {
        let store = try makeStore()
        // Rows as an older build wrote them: image data, no thumbnail.
        for index in 0..<5 {
            store.context.insert(ClipItem(
                kind: .image,
                imageData: try makePNG(width: 600, height: 400, seed: index),
                contentHash: ContentParser.hashText("legacy:\(index)"),
                createdAt: .now.addingTimeInterval(-Double(index))
            ))
        }
        store.save()
        XCTAssertEqual(store.pendingThumbnails(limit: 50).count, 5)

        // A batch smaller than the backlog: the drain must loop until empty.
        await store.backfillThumbnails(batchSize: 2)

        XCTAssertTrue(store.pendingThumbnails(limit: 50).isEmpty)
        let items = store.recent(limit: 50)
        XCTAssertEqual(items.count, 5)
        XCTAssertTrue(items.allSatisfy { $0.thumbnailData != nil && $0.thumbnailAttempted })
        XCTAssertTrue(
            items.allSatisfy { ($0.imageData?.count ?? 0) > 0 },
            "Rewriting the blob into external storage must not lose it"
        )
    }

    func testUndecodableImageIsMarkedAttemptedAndNotRetriedForever() async throws {
        let store = try makeStore()
        store.insert(imageClip("junk", data: Data("nope".utf8)), sourceBundleID: nil, sourceAppName: nil)

        await store.backfillThumbnails()

        let item = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertNil(item.thumbnailData)
        XCTAssertTrue(item.thumbnailAttempted)
        XCTAssertTrue(store.pendingThumbnails().isEmpty, "A failed decode must not be requeued")
    }

    func testTextClipsAreNeverQueuedForThumbnails() async throws {
        let store = try makeStore()
        store.insert(
            CapturedClip(
                kind: .text,
                text: "hello",
                richTextData: nil,
                imageData: nil,
                fileURLStrings: [],
                colorHex: nil,
                hash: ContentParser.hashText("text:hello")
            ),
            sourceBundleID: nil,
            sourceAppName: nil
        )

        XCTAssertTrue(store.pendingThumbnails().isEmpty)
        await store.backfillThumbnails()
        XCTAssertNil(store.recent(limit: 1).first?.thumbnailData)
    }

    func testPendingThumbnailsRespectsLimitAndSkipsFinishedClips() async throws {
        let store = try makeStore()
        for index in 0..<4 {
            store.context.insert(ClipItem(
                kind: .image,
                imageData: try makePNG(width: 400, height: 300, seed: index),
                contentHash: ContentParser.hashText("pending:\(index)"),
                createdAt: .now.addingTimeInterval(-Double(index))
            ))
        }
        store.save()

        XCTAssertEqual(store.pendingThumbnails(limit: 2).count, 2)

        let uuid = try XCTUnwrap(store.pendingThumbnails(limit: 1).first?.uuid)
        store.applyThumbnail(Data("x".utf8), toClipWith: uuid)
        XCTAssertEqual(store.pendingThumbnails(limit: 50).count, 3)
        XCTAssertFalse(store.pendingThumbnails(limit: 50).contains { $0.uuid == uuid })
    }

    func testApplyThumbnailToUnknownUUIDIsANoOp() async throws {
        let store = try makeStore()
        store.insert(imageClip("a", data: try makePNG()), sourceBundleID: nil, sourceAppName: nil)
        store.applyThumbnail(Data("x".utf8), toClipWith: UUID())
        XCTAssertEqual(store.pendingThumbnails().count, 1)
    }
}
