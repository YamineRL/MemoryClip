import XCTest

@testable import MemoryClip

/// The revision guards behind "a background result must not land on content
/// that changed underneath it" (P1.1) and the tag leg of the card-number
/// filter (P1.3).
///
/// Every background pipeline — OCR, thumbnails, refinement, notes, calendar
/// — snapshots the clip's `contentRevision` when it starts and hands it back
/// with its result. Edits, undos and secret conversions bump the revision,
/// so a result computed against content that is gone must be dropped rather
/// than stamped onto the new state. Sealed rows accept nothing at all:
/// derived fields are plaintext, and plaintext is exactly what sealing
/// removed.
@MainActor
final class StaleWriteBackTests: XCTestCase {
    private var vaultDirectory: URL!
    private var vault: SecretVault!
    private var store: ClipStore!

    override func setUp() async throws {
        vaultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memoryclip-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vaultDirectory, withIntermediateDirectories: true
        )
        vault = SecretVault(directory: vaultDirectory, sealer: SoftwareSecretSealer())
        store = try ClipStore(inMemory: true, secrets: vault)
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
    }

    override func tearDown() async throws {
        if let vaultDirectory {
            try? FileManager.default.removeItem(at: vaultDirectory)
        }
        store = nil
        vault = nil
        vaultDirectory = nil
    }

    @discardableResult
    private func insertText(_ text: String) throws -> ClipItem {
        store.insert(
            CapturedClip(
                kind: .text,
                text: text,
                richTextData: nil,
                imageData: nil,
                fileURLStrings: [],
                colorHex: nil,
                hash: ContentParser.hashText("text:\(text)")
            ),
            sourceBundleID: nil,
            sourceAppName: nil
        )
        return try XCTUnwrap(store.recent(limit: 1).first)
    }

    @discardableResult
    private func insertImage(_ marker: String) throws -> ClipItem {
        store.insert(
            CapturedClip(
                kind: .image,
                text: nil,
                richTextData: nil,
                imageData: Data(marker.utf8),
                fileURLStrings: [],
                colorHex: nil,
                hash: ContentParser.hashText("image:\(marker)")
            ),
            sourceBundleID: nil,
            sourceAppName: nil
        )
        return try XCTUnwrap(store.recent(limit: 1).first)
    }

    // MARK: - OCR

    func testOCRFromAnOlderRevisionIsDropped() throws {
        let item = try insertImage("a")
        let launchedAt = item.contentRevision
        item.contentRevision += 1 // any content change since the job started
        store.save()

        store.applyOCR("found text", toClipWith: item.uuid, revision: launchedAt)

        XCTAssertNil(item.ocrText, "OCR for content that is gone must not land")
        XCTAssertFalse(item.ocrAttempted, "A dropped result is no attempt — the row stays queued for the new content")
    }

    func testOCRToASecretClipIsDropped() throws {
        let item = try insertImage("a")
        item.isSecret = true // the watcher only seals text; force the state the guard reads
        store.save()

        store.applyOCR("found text", toClipWith: item.uuid, revision: item.contentRevision)

        XCTAssertNil(item.ocrText)
        XCTAssertFalse(item.ocrAttempted)
    }

    // MARK: - Thumbnails

    func testThumbnailFromAnOlderRevisionIsDropped() throws {
        let item = try insertImage("a")
        let launchedAt = item.contentRevision
        item.contentRevision += 1
        store.save()

        store.applyThumbnail(Data([9, 9]), toClipWith: item.uuid, revision: launchedAt)

        XCTAssertNil(item.thumbnailData)
        XCTAssertFalse(item.thumbnailAttempted)
    }

    func testThumbnailToASecretClipIsDropped() throws {
        let item = try insertImage("a")
        item.isSecret = true
        store.save()

        store.applyThumbnail(Data([9, 9]), toClipWith: item.uuid, revision: item.contentRevision)

        XCTAssertNil(item.thumbnailData)
        XCTAssertFalse(item.thumbnailAttempted)
    }

    // MARK: - Refinement

    func testRefinementFromAnOlderRevisionIsDropped() throws {
        let item = try insertText("a note")
        let launchedAt = item.contentRevision

        // The clip's content moved on — say, an edit — before the model came back.
        _ = store.applyEdit(item, newText: "a different note")
        XCTAssertNotEqual(item.contentRevision, launchedAt)

        store.applyRefinement(
            title: "Stale title",
            summary: "Stale summary",
            text: "Stale text",
            tags: ["stale"],
            toClipWith: item.uuid,
            revision: launchedAt
        )

        XCTAssertNil(item.refinedTitle)
        XCTAssertNil(item.refinedText)
        XCTAssertTrue(item.refinedTags.isEmpty)
        XCTAssertFalse(item.refineAttempted, "A dropped refinement leaves the row queued for the new content")
    }

    /// The acceptance case: refinement is in flight, the user seals the row,
    /// the model finishes — none of its plaintext may return.
    func testMarkAsSecretMakesAPendingRefinementStale() throws {
        let item = try insertText("ordinary text, soon to be a credential")
        let launchedAt = item.contentRevision

        XCTAssertTrue(store.markAsSecret(item))

        store.applyRefinement(
            title: "Recovered title",
            summary: nil,
            text: "Recovered text",
            tags: ["recovered"],
            toClipWith: item.uuid,
            revision: launchedAt
        )

        XCTAssertNil(item.refinedTitle)
        XCTAssertNil(item.refinedText)
        XCTAssertTrue(item.refinedTags.isEmpty)
        XCTAssertFalse(item.refineAttempted)
        XCTAssertNil(item.text, "Sealing must still stand after the late write-back")
    }

    func testRefinementToASecretClipIsDroppedAtTheCurrentRevision() throws {
        let item = try insertText("ordinary text, soon to be a credential")
        XCTAssertTrue(store.markAsSecret(item))

        // Even a write-back carrying the post-seal revision lands nothing —
        // a sealed row accepts no derived plaintext at all.
        store.applyRefinement(
            title: "Recovered title",
            summary: nil,
            text: "Recovered text",
            tags: [],
            toClipWith: item.uuid,
            revision: item.contentRevision
        )

        XCTAssertNil(item.refinedTitle)
        XCTAssertNil(item.refinedText)
        XCTAssertFalse(item.refineAttempted)
    }

    // MARK: - The card filter covers tags

    /// P1.3: a likely card number that the model returns ONLY as a tag must
    /// not reach `refinedTags` — tags are persisted and land in note front
    /// matter like any other derived field.
    func testACardNumberCarriedOnlyByTagsIsDropped() throws {
        UserDefaults.standard.set(true, forKey: SensitiveFilter.filteringEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: SensitiveFilter.filteringEnabledKey) }

        let item = try insertText("order confirmation")

        store.applyRefinement(
            title: "Order 1234",
            summary: "Your order shipped",
            text: "Tracking number inside",
            tags: ["order", "4242 4242 4242 4242"],
            toClipWith: item.uuid,
            revision: item.contentRevision
        )

        XCTAssertTrue(item.refinedTags.isEmpty, "The card-shaped tag must not be persisted")
        XCTAssertNil(item.refinedText, "The whole result is dropped — picking the good fields out keeps the model's leak half-shipped")
        XCTAssertTrue(item.refineAttempted)
    }

    // MARK: - Notes

    func testNoteFromAnOlderRevisionIsNotRecorded() throws {
        let item = try insertText("a note")
        let launchedAt = item.contentRevision
        item.contentRevision += 1
        store.save()

        store.applyNote(path: "/tmp/stale.md", toClipWith: item.uuid, revision: launchedAt)

        XCTAssertNil(item.notePath, "A note written for old content is not the row's note")
        XCTAssertNil(item.noteExportedAt)
    }

    func testNoteToASecretClipIsNotRecorded() throws {
        let item = try insertText("ordinary text, soon to be a credential")
        XCTAssertTrue(store.markAsSecret(item))

        store.applyNote(path: "/tmp/leak.md", toClipWith: item.uuid, revision: item.contentRevision)

        XCTAssertNil(item.notePath, "A sealed row gains no pointer to a file it was converted to stop having")
        XCTAssertNil(item.noteExportedAt)
    }

    // MARK: - Edits and undo invalidate

    func testApplyEditBumpsTheContentRevision() throws {
        let item = try insertText("before")
        let before = item.contentRevision

        _ = store.applyEdit(item, newText: "after")

        XCTAssertEqual(item.contentRevision, before + 1)
    }

    func testRestoreEditBumpsTheContentRevision() throws {
        let item = try insertText("before")
        let snapshot = try XCTUnwrap(store.applyEdit(item, newText: "after"))
        let edited = item.contentRevision

        store.restoreEdit(snapshot)

        XCTAssertEqual(item.contentRevision, edited + 1)
        XCTAssertEqual(item.text, "before")
    }

    // MARK: - Calendar events bind to a revision

    func testRecordingAnEventNeedsTheMatchingRevision() throws {
        let item = try insertText("Standup August 20, 2026 at 9:30am")
        let detectedAt = item.contentRevision
        _ = store.applyEdit(item, newText: "something with no date at all")

        XCTAssertFalse(
            store.applyCalendarEvent("EK-1", toClipWith: item.uuid, revision: detectedAt),
            "The event describes content the clip no longer holds"
        )
        XCTAssertNil(item.calendarEventID)
    }

    func testAnEventCannotBeRecordedOnASecretClip() throws {
        let item = try insertText("ordinary text, soon to be a credential")
        XCTAssertTrue(store.markAsSecret(item))

        XCTAssertFalse(
            store.applyCalendarEvent("EK-1", toClipWith: item.uuid, revision: item.contentRevision)
        )
        XCTAssertNil(item.calendarEventID)
    }

    func testClearingAnEventIsAlwaysAllowed() throws {
        let item = try insertText("Standup August 20, 2026 at 9:30am")
        XCTAssertTrue(
            store.applyCalendarEvent("EK-1", toClipWith: item.uuid, revision: item.contentRevision)
        )

        // Content moved on, even sealed — an undo must still be able to
        // un-record itself, or the clip claims an event nobody can reach.
        _ = store.applyEdit(item, newText: "edited")
        XCTAssertTrue(store.applyCalendarEvent(nil, toClipWith: item.uuid))
        XCTAssertNil(item.calendarEventID)
    }
}
