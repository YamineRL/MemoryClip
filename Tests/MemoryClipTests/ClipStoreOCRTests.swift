import XCTest

@testable import MemoryClip

@MainActor
final class ClipStoreOCRTests: XCTestCase {
    private func makeStore() throws -> ClipStore {
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
        return try ClipStore(inMemory: true)
    }

    private func imageClip(_ marker: String) -> CapturedClip {
        CapturedClip(
            kind: .image,
            text: nil,
            richTextData: nil,
            imageData: Data(marker.utf8),
            fileURLStrings: [],
            colorHex: nil,
            hash: ContentParser.hashText("image:\(marker)")
        )
    }

    private func textClip(_ text: String) -> CapturedClip {
        CapturedClip(
            kind: .text,
            text: text,
            richTextData: nil,
            imageData: nil,
            fileURLStrings: [],
            colorHex: nil,
            hash: ContentParser.hashText("text:\(text)")
        )
    }

    func testPendingOCRReturnsOnlyUnprocessedImages() throws {
        let store = try makeStore()
        store.insert(imageClip("a"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(imageClip("b"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(textClip("not an image"), sourceBundleID: nil, sourceAppName: nil)

        let pending = store.pendingOCR()
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { $0.kind == .image })
    }

    func testApplyOCRStoresTextAndStopsRequeueing() throws {
        let store = try makeStore()
        store.insert(imageClip("a"), sourceBundleID: nil, sourceAppName: nil)
        let uuid = try XCTUnwrap(store.pendingOCR().first?.uuid)

        store.applyOCR("invoice total 42", toClipWith: uuid)

        XCTAssertTrue(store.pendingOCR().isEmpty)
        let item = try XCTUnwrap(store.items(withUUIDs: [uuid]).first)
        XCTAssertEqual(item.ocrText, "invoice total 42")
        XCTAssertTrue(item.ocrAttempted)
    }

    func testApplyOCRWithNoTextStillMarksAttempted() throws {
        let store = try makeStore()
        store.insert(imageClip("a"), sourceBundleID: nil, sourceAppName: nil)
        let uuid = try XCTUnwrap(store.pendingOCR().first?.uuid)

        store.applyOCR(nil, toClipWith: uuid)

        XCTAssertTrue(store.pendingOCR().isEmpty, "A fruitless run must not be retried forever")
        let item = try XCTUnwrap(store.items(withUUIDs: [uuid]).first)
        XCTAssertNil(item.ocrText)
        XCTAssertTrue(item.ocrAttempted)
    }

    func testApplyOCRToUnknownUUIDIsANoOp() throws {
        let store = try makeStore()
        store.insert(imageClip("a"), sourceBundleID: nil, sourceAppName: nil)
        store.applyOCR("ghost", toClipWith: UUID())
        XCTAssertEqual(store.pendingOCR().count, 1)
    }

    func testPendingOCRRespectsLimit() throws {
        let store = try makeStore()
        for index in 0..<5 {
            store.insert(imageClip("img\(index)"), sourceBundleID: nil, sourceAppName: nil)
        }
        XCTAssertEqual(store.pendingOCR(limit: 3).count, 3)
    }

    func testItemsWithUUIDsFetchesRequestedClipsOnly() throws {
        let store = try makeStore()
        store.insert(textClip("one"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(textClip("two"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(textClip("three"), sourceBundleID: nil, sourceAppName: nil)

        let all = store.recent(limit: 10)
        let wanted = [all[0].uuid, all[2].uuid]
        let found = store.items(withUUIDs: wanted)

        XCTAssertEqual(Set(found.map(\.uuid)), Set(wanted))
    }

    // MARK: - OCR text goes through the sensitive filter

    func testOCRTextContainingACardNumberIsDropped() throws {
        UserDefaults.standard.set(true, forKey: SensitiveFilter.filteringEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: SensitiveFilter.filteringEnabledKey) }

        let store = try makeStore()
        store.insert(imageClip("card"), sourceBundleID: nil, sourceAppName: nil)
        let uuid = try XCTUnwrap(store.pendingOCR().first?.uuid)

        store.applyOCR("VISA 4242 4242 4242 4242 03/29", toClipWith: uuid)

        let item = try XCTUnwrap(store.items(withUUIDs: [uuid]).first)
        XCTAssertNil(item.ocrText, "A screenshotted card must not become searchable plaintext")
        XCTAssertTrue(item.ocrAttempted, "It must still not be re-queued forever")
    }

    func testBenignOCRTextIsKept() throws {
        UserDefaults.standard.set(true, forKey: SensitiveFilter.filteringEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: SensitiveFilter.filteringEnabledKey) }

        let store = try makeStore()
        store.insert(imageClip("receipt"), sourceBundleID: nil, sourceAppName: nil)
        let uuid = try XCTUnwrap(store.pendingOCR().first?.uuid)

        store.applyOCR("Total 12.40 EUR", toClipWith: uuid)

        XCTAssertEqual(try XCTUnwrap(store.items(withUUIDs: [uuid]).first).ocrText, "Total 12.40 EUR")
    }

    func testOCRFilteringRespectsTheUsersOptOut() throws {
        UserDefaults.standard.set(false, forKey: SensitiveFilter.filteringEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: SensitiveFilter.filteringEnabledKey) }

        let store = try makeStore()
        store.insert(imageClip("card"), sourceBundleID: nil, sourceAppName: nil)
        let uuid = try XCTUnwrap(store.pendingOCR().first?.uuid)

        store.applyOCR("4242 4242 4242 4242", toClipWith: uuid)

        XCTAssertEqual(
            try XCTUnwrap(store.items(withUUIDs: [uuid]).first).ocrText,
            "4242 4242 4242 4242"
        )
    }

    func testItemsWithUUIDsSkipsUnknownIDsAndDeduplicates() throws {
        let store = try makeStore()
        store.insert(textClip("one"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(textClip("two"), sourceBundleID: nil, sourceAppName: nil)

        let all = store.recent(limit: 10)
        let known = all[0].uuid
        let found = store.items(withUUIDs: [known, UUID(), known])

        XCTAssertEqual(found.count, 1, "A repeated id must not yield the clip twice")
        XCTAssertEqual(found.first?.uuid, known)
    }

    func testItemsWithUUIDsReturnsEveryRequestedClip() throws {
        let store = try makeStore()
        for index in 0..<40 {
            store.insert(textClip("clip\(index)"), sourceBundleID: nil, sourceAppName: nil)
        }
        let all = store.recent(limit: 100)
        let wanted = stride(from: 0, to: all.count, by: 3).map { all[$0].uuid }

        let found = store.items(withUUIDs: wanted)

        XCTAssertEqual(Set(found.map(\.uuid)), Set(wanted))
        XCTAssertEqual(found.count, wanted.count)
    }

    func testItemsWithUUIDsIgnoresDeletedClips() throws {
        let store = try makeStore()
        store.insert(textClip("one"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(textClip("two"), sourceBundleID: nil, sourceAppName: nil)
        let all = store.recent(limit: 10)
        let uuids = all.map(\.uuid)
        store.delete(all[0])

        let found = store.items(withUUIDs: uuids)

        XCTAssertEqual(found.map(\.uuid), [all[1].uuid])
    }

    func testItemsWithEmptyUUIDListReturnsNothing() throws {
        let store = try makeStore()
        store.insert(textClip("one"), sourceBundleID: nil, sourceAppName: nil)
        XCTAssertTrue(store.items(withUUIDs: []).isEmpty)
    }
}
