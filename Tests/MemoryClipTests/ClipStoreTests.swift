import XCTest

@testable import MemoryClip

@MainActor
final class ClipStoreTests: XCTestCase {
    private func makeStore(cap: Int, retentionDays: Int) throws -> ClipStore {
        UserDefaults.standard.set(cap, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(retentionDays, forKey: SettingsKeys.retentionDays)
        return try ClipStore(inMemory: true)
    }

    private func makeClip(_ text: String) -> CapturedClip {
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

    func testInsertThenRecentReturnsIt() throws {
        let store = try makeStore(cap: 100, retentionDays: 30)
        store.insert(makeClip("hello"), sourceBundleID: "com.example.test", sourceAppName: "TestApp")

        let items = store.recent(limit: 10)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.text, "hello")
        XCTAssertEqual(items.first?.sourceBundleID, "com.example.test")
        XCTAssertEqual(items.first?.sourceAppName, "TestApp")
    }

    func testDedupBringsExistingClipToTop() throws {
        let store = try makeStore(cap: 100, retentionDays: 30)
        store.insert(makeClip("a"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(makeClip("b"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(makeClip("a"), sourceBundleID: nil, sourceAppName: nil)

        let items = store.recent(limit: 10)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.text, "a")
    }

    func testCapIsEnforced() throws {
        let store = try makeStore(cap: 3, retentionDays: 30)
        for text in ["1", "2", "3", "4", "5"] {
            store.insert(makeClip(text), sourceBundleID: nil, sourceAppName: nil)
        }

        let items = store.recent(limit: 10)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.compactMap(\.text)), ["3", "4", "5"])
    }

    func testPinnedSurviveCap() throws {
        let store = try makeStore(cap: 2, retentionDays: 30)
        store.insert(makeClip("a"), sourceBundleID: nil, sourceAppName: nil)
        guard let pinned = store.recent(limit: 1).first else {
            return XCTFail("expected inserted clip")
        }
        store.togglePinned(pinned)

        store.insert(makeClip("b"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(makeClip("c"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(makeClip("d"), sourceBundleID: nil, sourceAppName: nil)

        let items = store.recent(limit: 10)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.compactMap(\.text)), ["a", "c", "d"])
        XCTAssertTrue(items.contains { $0.text == "a" && $0.isPinned })
    }

    // MARK: - Cap boundaries (the trim now uses fetchCount + a limited fetch)

    func testExactlyAtCapDeletesNothing() throws {
        let store = try makeStore(cap: 3, retentionDays: 0)
        for text in ["1", "2", "3"] {
            store.insert(makeClip(text), sourceBundleID: nil, sourceAppName: nil)
        }
        XCTAssertEqual(Set(store.recent(limit: 10).compactMap(\.text)), ["1", "2", "3"])
    }

    func testOneOverCapDropsExactlyTheOldest() throws {
        let store = try makeStore(cap: 3, retentionDays: 0)
        for text in ["1", "2", "3", "4"] {
            store.insert(makeClip(text), sourceBundleID: nil, sourceAppName: nil)
        }
        XCTAssertEqual(Set(store.recent(limit: 10).compactMap(\.text)), ["2", "3", "4"])
    }

    func testCapOfOneKeepsOnlyTheNewest() throws {
        let store = try makeStore(cap: 1, retentionDays: 0)
        for text in ["1", "2", "3"] {
            store.insert(makeClip(text), sourceBundleID: nil, sourceAppName: nil)
        }
        XCTAssertEqual(store.recent(limit: 10).compactMap(\.text), ["3"])
    }

    func testUnlimitedCapKeepsEverything() throws {
        let store = try makeStore(cap: 0, retentionDays: 0)
        for index in 0..<25 {
            store.insert(makeClip("\(index)"), sourceBundleID: nil, sourceAppName: nil)
        }
        XCTAssertEqual(store.recent(limit: 100).count, 25)
    }

    func testPinnedClipsAreExemptFromTheCapCount() throws {
        let store = try makeStore(cap: 2, retentionDays: 0)
        // Four pinned clips — far past the cap — must all survive, and the
        // cap must still be applied to the unpinned ones around them.
        for text in ["p1", "p2", "p3", "p4"] {
            store.insert(makeClip(text), sourceBundleID: nil, sourceAppName: nil)
            guard let newest = store.recent(limit: 1).first else {
                return XCTFail("expected inserted clip")
            }
            store.togglePinned(newest)
        }
        for text in ["u1", "u2", "u3", "u4"] {
            store.insert(makeClip(text), sourceBundleID: nil, sourceAppName: nil)
        }

        let texts = Set(store.recent(limit: 50).compactMap(\.text))
        XCTAssertEqual(texts, ["p1", "p2", "p3", "p4", "u3", "u4"])
    }

    func testTrimIsAppliedToABacklogFarPastTheCapInOnePass() throws {
        let store = try makeStore(cap: 100, retentionDays: 0)
        for index in 0..<50 {
            store.context.insert(ClipItem(
                kind: .text,
                text: "\(index)",
                contentHash: ContentParser.hashText("bulk:\(index)"),
                createdAt: .now.addingTimeInterval(-Double(50 - index))
            ))
        }
        store.save()

        UserDefaults.standard.set(10, forKey: SettingsKeys.historyCap)
        store.enforceCap()

        let remaining = store.recent(limit: 100)
        XCTAssertEqual(remaining.count, 10)
        XCTAssertEqual(
            Set(remaining.compactMap(\.text)),
            Set((40..<50).map(String.init)),
            "The ten newest must be the survivors"
        )
    }

    func testLargeBacklogIsBatchTrimmedToExactlyTheCap() throws {
        let store = try makeStore(cap: 0, retentionDays: 0)
        // Well past `exactTrimLimit`, so the batch-delete path runs.
        let total = ClipStore.exactTrimLimit * 5
        for index in 0..<total {
            store.context.insert(ClipItem(
                kind: .text,
                text: "\(index)",
                contentHash: ContentParser.hashText("batch:\(index)"),
                createdAt: .now.addingTimeInterval(-Double(total - index)),
                isPinned: index < 3
            ))
        }
        store.save()

        UserDefaults.standard.set(10, forKey: SettingsKeys.historyCap)
        store.enforceCap()

        let remaining = store.recent(limit: 1000)
        XCTAssertEqual(remaining.filter { !$0.isPinned }.count, 10)
        XCTAssertEqual(remaining.filter(\.isPinned).count, 3, "Pinned clips stay exempt")
        XCTAssertEqual(
            Set(remaining.filter { !$0.isPinned }.compactMap(\.text)),
            Set(((total - 10)..<total).map(String.init))
        )
    }

    func testBatchTrimIsExactWhenEveryClipSharesATimestamp() throws {
        let store = try makeStore(cap: 0, retentionDays: 0)
        let stamp = Date.now
        let total = ClipStore.exactTrimLimit * 3
        for index in 0..<total {
            store.context.insert(ClipItem(
                kind: .text,
                text: "\(index)",
                contentHash: ContentParser.hashText("tie:\(index)"),
                createdAt: stamp
            ))
        }
        store.save()

        UserDefaults.standard.set(7, forKey: SettingsKeys.historyCap)
        store.enforceCap()

        XCTAssertEqual(store.recent(limit: 1000).count, 7)
    }

    func testRetentionDropsOldUnpinnedOnly() throws {
        let store = try makeStore(cap: 100, retentionDays: 7)
        let backdated = Calendar.current.date(byAdding: .day, value: -10, to: .now)!

        let oldUnpinned = ClipItem(
            kind: .text,
            text: "old",
            contentHash: ContentParser.hashText("text:old"),
            createdAt: backdated
        )
        store.context.insert(oldUnpinned)

        let oldPinned = ClipItem(
            kind: .text,
            text: "old-pinned",
            contentHash: ContentParser.hashText("text:old-pinned"),
            createdAt: backdated,
            isPinned: true
        )
        store.context.insert(oldPinned)
        store.save()

        store.insert(makeClip("fresh"), sourceBundleID: nil, sourceAppName: nil)

        store.enforceRetention()

        let items = store.recent(limit: 10)
        XCTAssertEqual(Set(items.compactMap(\.text)), ["old-pinned", "fresh"])
    }

    func testNukeAllRemovesEverythingIncludingPinned() throws {
        let store = try makeStore(cap: 100, retentionDays: 30)
        store.insert(makeClip("a"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(makeClip("b"), sourceBundleID: nil, sourceAppName: nil)
        guard let item = store.recent(limit: 1).first else {
            return XCTFail("expected inserted clip")
        }
        store.togglePinned(item)

        store.nukeAll()

        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testBatchNukeClearsALargeHistoryAndLeavesTheStoreUsable() throws {
        let store = try makeStore(cap: 0, retentionDays: 0)
        for index in 0..<500 {
            store.context.insert(ClipItem(
                kind: .text,
                text: "\(index)",
                contentHash: ContentParser.hashText("nuke:\(index)"),
                isPinned: index % 10 == 0
            ))
        }
        store.save()
        XCTAssertEqual(store.recent(limit: 1000).count, 500)

        store.nukeAll()

        XCTAssertTrue(store.recent(limit: 1000).isEmpty, "Pinned clips go too")
        // The context must still be healthy afterwards.
        store.insert(makeClip("after nuke"), sourceBundleID: nil, sourceAppName: nil)
        XCTAssertEqual(store.recent(limit: 10).compactMap(\.text), ["after nuke"])
    }

    // MARK: - Periodic maintenance

    func testMaintenanceAppliesACapLoweredAfterTheLastCapture() throws {
        let store = try makeStore(cap: 100, retentionDays: 0)
        for text in ["1", "2", "3", "4", "5"] {
            store.insert(makeClip(text), sourceBundleID: nil, sourceAppName: nil)
        }
        XCTAssertEqual(store.recent(limit: 10).count, 5)

        // User lowers the cap in Settings and copies nothing further.
        UserDefaults.standard.set(2, forKey: SettingsKeys.historyCap)
        store.performMaintenance()

        XCTAssertEqual(Set(store.recent(limit: 10).compactMap(\.text)), ["4", "5"])
    }

    func testMaintenanceExpiresOldClipsWithoutANewCapture() throws {
        let store = try makeStore(cap: 100, retentionDays: 7)
        let backdated = Calendar.current.date(byAdding: .day, value: -10, to: .now)!
        store.context.insert(ClipItem(
            kind: .text,
            text: "old",
            contentHash: ContentParser.hashText("text:old"),
            createdAt: backdated
        ))
        store.save()

        store.performMaintenance()

        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testStartMaintenanceRunsImmediatelyAndCanBeStopped() throws {
        let store = try makeStore(cap: 2, retentionDays: 0)
        for text in ["1", "2", "3", "4"] {
            store.insert(makeClip(text), sourceBundleID: nil, sourceAppName: nil)
        }
        UserDefaults.standard.set(1, forKey: SettingsKeys.historyCap)

        store.startMaintenance(interval: 3600)
        defer { store.stopMaintenance() }

        XCTAssertEqual(store.recent(limit: 10).count, 1)
    }

    func testMarkUsedSetsLastUsedAt() throws {
        let store = try makeStore(cap: 100, retentionDays: 30)
        store.insert(makeClip("hello"), sourceBundleID: nil, sourceAppName: nil)
        guard let item = store.recent(limit: 1).first else {
            return XCTFail("expected inserted clip")
        }
        XCTAssertNil(item.lastUsedAt)

        store.markUsed(item)

        XCTAssertNotNil(item.lastUsedAt)
    }
}
