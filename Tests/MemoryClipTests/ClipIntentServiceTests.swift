import AppKit
import Foundation
import XCTest

@testable import MemoryClip

/// The intents' logic, exercised through `ClipIntentService` against an
/// in-memory store — exactly the seam PRD 03 asks the `perform()`s to
/// funnel through. The metadata bundle itself is make_app.sh's concern
/// (S3 evidence), not a test's.
@MainActor
final class ClipIntentServiceTests: XCTestCase {
    private var store: ClipStore!
    private var service: ClipIntentService!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
        store = try ClipStore(inMemory: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("memoryclip-intents-\(UUID().uuidString)"))
        service = ClipIntentService(store: store, pasteboard: pasteboard, unlock: { true })
    }

    private var png: Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01]) }

    @discardableResult
    private func insert(_ item: ClipItem) -> ClipItem {
        store.context.insert(item)
        store.save()
        return item
    }

    /// `XCTAssertThrowsError` for an async call.
    private func assertThrowsLocked(_ operation: () async throws -> some Any) async {
        do {
            _ = try await operation()
            XCTFail("expected the lock gate to refuse")
        } catch {
            XCTAssertEqual(error as? ClipIntentService.IntentError, .locked)
        }
    }

    // MARK: Latest

    /// Newest first, kind-filtered: the same question the panel's type
    /// chips ask.
    func testLatestHonoursKind() async throws {
        let old = insert(ClipItem(kind: .text, text: "older", contentHash: "t:1",
                                  createdAt: Date(timeIntervalSinceNow: -100)))
        let image = insert(ClipItem(kind: .image, imageData: png, contentHash: "i:1",
                                    createdAt: Date(timeIntervalSinceNow: -50)))
        let newest = insert(ClipItem(kind: .link, text: "https://example.com", contentHash: "l:1"))

        let any = try await service.latest(kind: .any)
        let text = try await service.latest(kind: .text)
        let imageResult = try await service.latest(kind: .image)
        let fileResult = try await service.latest(kind: .file)
        XCTAssertEqual(any?.id, newest.uuid)
        XCTAssertEqual(text?.id, old.uuid)
        XCTAssertEqual(imageResult?.id, image.uuid)
        XCTAssertNil(fileResult, "no file clips yet")
    }

    /// The file a text clip returns carries its text, the file an image
    /// clip returns carries its pixels.
    func testLatestFileCarriesTheClip() async throws {
        insert(ClipItem(kind: .text, text: "plain text body", contentHash: "t:1",
                        createdAt: Date(timeIntervalSinceNow: -100)))
        insert(ClipItem(kind: .image, imageData: png, contentHash: "i:1"))

        let imageFile = try await service.latestFile(kind: .image)
        let textFile = try await service.latestFile(kind: .text)
        XCTAssertNotNil(imageFile)
        XCTAssertNotNil(textFile)
    }

    // MARK: Search

    /// Parity with the panel is the contract: for a fixed corpus the
    /// service's answer is the clips `matchesSearch` accepts, newest
    /// first — and a clip carrying none of the terms stays out. (The
    /// panel's own `refine` cannot serve as the baseline: for a single
    /// term it trusts the SQL predicate, which is the very thing under
    /// test here.)
    func testSearchMatchesThePanel() async throws {
        let matching = insert(ClipItem(kind: .text, text: "quarterly invoice for March",
                                       contentHash: "a", sourceAppName: "Safari",
                                       createdAt: Date(timeIntervalSinceNow: -300)))
        let other = insert(ClipItem(kind: .text, text: "shopping list",
                                    contentHash: "b", sourceAppName: "Notes",
                                    createdAt: Date(timeIntervalSinceNow: -200)))
        let newest = insert(ClipItem(kind: .text, text: "invoice template",
                                     contentHash: "c", sourceAppName: "TextEdit",
                                     createdAt: Date(timeIntervalSinceNow: -100)))

        let viaService = try await service.search(query: "invoice", limit: 10).map(\.id)
        let filter = ClipFilter(search: "invoice")
        let expected = store.recent(limit: 50)
            .filter { filter.matchesSearch($0) }
            .map(\.uuid)

        XCTAssertEqual(viaService, expected, "service and panel semantics disagree")
        XCTAssertEqual(viaService, [newest.uuid, matching.uuid])
        XCTAssertFalse(viaService.contains(other.uuid))
    }

    /// Limit is clamped, not honoured verbatim: 0 still gets the best row,
    /// 10_000 stops at the 100-ceiling.
    func testSearchClampsTheLimit() async throws {
        for i in 0..<5 {
            insert(ClipItem(kind: .text, text: "clip \(i)", contentHash: "n:\(i)"))
        }
        let three = try await service.search(query: "", limit: 3)
        let all = try await service.search(query: "", limit: 10_000)
        let clamped = try await service.search(query: "", limit: 0)
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(clamped.count, 1)
    }

    // MARK: Lock gate

    /// With the lock on and the gate refusing, every reading intent throws
    /// "MemoryClip is locked." — Open MemoryClip is the only gate-free one
    /// (it gates inside the panel itself).
    func testLockGateRefusesReads() async throws {
        insert(ClipItem(kind: .text, text: "anything", contentHash: "x:1"))
        let locked = ClipIntentService(store: store, pasteboard: pasteboard, unlock: { false })

        await assertThrowsLocked { try await locked.search(query: "any", limit: 10) }
        await assertThrowsLocked { try await locked.latest(kind: .any) }
        await assertThrowsLocked { try await locked.latestFile(kind: .any) }
        await assertThrowsLocked { try await locked.resolve(UUID()) }
        await assertThrowsLocked { try await locked.copy(uuid: UUID()) }
    }

    // MARK: Copy

    /// Copy Clip writes through PasteService onto the board — the payload
    /// the panel would have written, not a text-only flattening.
    func testCopyWritesTheRealPayload() async throws {
        let item = insert(ClipItem(kind: .link, text: "https://example.com/path", contentHash: "l:1"))

        let wrote = try await service.copy(uuid: item.uuid)
        XCTAssertTrue(wrote)
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/path")
        XCTAssertNotNil(pasteboard.string(forType: NSPasteboard.PasteboardType("public.url")))
    }

    /// A uuid nothing resolves to is not an error — it is "nothing to
    /// write" (the intent turns false into copyFailed).
    func testCopyOfAMissingClipIsFalse() async throws {
        let wrote = try await service.copy(uuid: UUID())
        XCTAssertFalse(wrote)
    }

    // MARK: Withheld rows

    /// The seam the feature list calls `isShareable`: a secret row is
    /// invisible to every read an intent can make — search cannot see it,
    /// latest skips it for the next real clip, resolve and copy answer
    /// "not there", and its existence, timestamp and source app never
    /// leave the store through Shortcuts or Spotlight.
    func testASecretClipIsInvisibleToIntents() async throws {
        let ordinary = insert(ClipItem(kind: .text, text: "ordinary text",
                                       contentHash: "o:1",
                                       createdAt: Date(timeIntervalSinceNow: -100)))
        let secret = insert(ClipItem(
            kind: .text,
            contentHash: "s:1",
            sourceAppName: "1Password",
            isSecret: true,
            secretMasked: "••••••"
        ))

        let found = try await service.search(query: "", limit: 10).map(\.id)
        XCTAssertEqual(found, [ordinary.uuid], "a secret row must not come back from search")
        let newest = try await service.latest(kind: .any)
        XCTAssertEqual(newest?.id, ordinary.uuid, "a newer secret must not win latest")
        let resolved = try await service.resolve(secret.uuid)
        XCTAssertNil(resolved)
        let copied = try await service.copy(uuid: secret.uuid)
        XCTAssertFalse(copied)
        // The newest text row is the secret; the file that comes back is the
        // ordinary clip's — withheld, not blocking.
        let file = try await service.latestFile(kind: .text)
        XCTAssertNotNil(file)
    }

    // MARK: Entities

    /// The entity never carries an image's absent text, a text clip's
    /// content comes through, and the title is the first-line / refined /
    /// file-name chain the card uses.
    func testEntityMapsWhatAShortcutSees() async throws {
        let text = insert(ClipItem(kind: .text, text: "first line\nsecond line",
                                   contentHash: "t:1", sourceAppName: "Safari"))
        let image = insert(ClipItem(kind: .image, imageData: png, contentHash: "i:1"))
        let refined = insert(ClipItem(kind: .text, text: "body", contentHash: "r:1"))
        refined.refinedTitle = "A tidy title"
        store.save()
        let file = insert(ClipItem(kind: .file,
                                   fileURLStrings: ["file:///Users/yamine/Documents/report.pdf"],
                                   contentHash: "f:1"))

        let entities = try await service.search(query: "", limit: 10)
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })

        XCTAssertEqual(byID[text.uuid]?.text, "first line\nsecond line")
        XCTAssertEqual(byID[text.uuid]?.title, "first line")
        XCTAssertEqual(byID[text.uuid]?.sourceApp, "Safari")
        XCTAssertNil(byID[image.uuid]?.text, "an image has no text to hand out")
        XCTAssertEqual(byID[refined.uuid]?.title, "A tidy title")
        XCTAssertEqual(byID[file.uuid]?.title, "report.pdf")
        XCTAssertEqual(byID[file.uuid]?.kind, .file)
    }
}
