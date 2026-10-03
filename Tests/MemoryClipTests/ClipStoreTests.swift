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

    // MARK: - History limits (the pane's preview and the store's delete share one count)

    /// The fresh-install promise: the registered default cap keeps 5,000
    /// clips, so a 6,000-clip backlog trims to exactly 5,000 through the
    /// batch path, since the surplus is far past `exactTrimLimit`.
    func testDefaultCapTrimsSixThousandClipsToFiveThousand() throws {
        let store = try makeStore(cap: SettingsKeys.defaultHistoryCap, retentionDays: 0)
        XCTAssertEqual(
            SettingsKeys.defaultHistoryCap, 5_000,
            "the fresh-install cap the product promises"
        )

        for index in 0..<6_000 {
            store.context.insert(ClipItem(
                kind: .text,
                text: "\(index)",
                contentHash: ContentParser.hashText("defaults:\(index)"),
                createdAt: .now.addingTimeInterval(-Double(6_000 - index))
            ))
        }
        store.save()

        store.enforceCap()

        let remaining = store.recent(limit: 10_000)
        XCTAssertEqual(remaining.count, 5_000)
        XCTAssertEqual(
            Set(remaining.compactMap(\.text)),
            Set((1_000..<6_000).map(String.init)),
            "the 5,000 newest must be the survivors"
        )
    }

    /// The confirmation sheet's "Delete N" and the deletion itself must be
    /// one number: `deletionCount(under:)` is the single function the sheet
    /// counts with and enforcement counts with. A preview computed any other
    /// way, or a delete that counts differently, is the regression that
    /// would make the sheet lie.
    func testDeletionCountEqualsWhatEnforcementDeletes() throws {
        let store = try makeStore(cap: 0, retentionDays: 0)

        // Ten unpinned clips and two pinned ones, each its own timestamp.
        for index in 0..<12 {
            store.context.insert(ClipItem(
                kind: .text,
                text: "\(index)",
                contentHash: ContentParser.hashText("count:\(index)"),
                createdAt: .now.addingTimeInterval(-Double(12 - index)),
                isPinned: index < 2
            ))
        }
        store.save()

        // The zero sentinels never preview a deletion: cap 0 is Unlimited,
        // retention 0 is Forever.
        XCTAssertEqual(store.deletionCount(under: .cap(0)), 0)
        XCTAssertEqual(store.deletionCount(under: .retentionDays(0)), 0)

        // Cap side: ten unpinned under a cap of 4 previews 6 doomed…
        let capPreview = store.deletionCount(under: .cap(4))
        XCTAssertEqual(capPreview, 6)
        let unpinnedBefore = store.recent(limit: 100).filter { !$0.isPinned }.count
        // …and enforcing that cap deletes exactly those 6, pins aside.
        UserDefaults.standard.set(4, forKey: SettingsKeys.historyCap)
        store.enforceCap()
        let unpinnedAfter = store.recent(limit: 100).filter { !$0.isPinned }.count
        XCTAssertEqual(unpinnedBefore - unpinnedAfter, capPreview,
                       "the sheet's number and the enforce pass disagree")
        XCTAssertEqual(unpinnedAfter, 4)
        XCTAssertEqual(store.recent(limit: 100).filter(\.isPinned).count, 2,
                       "pinned clips are never in the count or the delete")
        XCTAssertEqual(store.deletionCount(under: .cap(4)), 0,
                       "a second count after enforcement must be zero")

        // Retention side: one stale unpinned clip and one stale pinned clip.
        let stale = ClipItem(
            kind: .text, text: "stale",
            contentHash: ContentParser.hashText("count:stale"),
            createdAt: Calendar.current.date(byAdding: .day, value: -10, to: .now)!
        )
        let stalePinned = ClipItem(
            kind: .text, text: "stale-pinned",
            contentHash: ContentParser.hashText("count:stale-pinned"),
            createdAt: Calendar.current.date(byAdding: .day, value: -10, to: .now)!,
            isPinned: true
        )
        store.context.insert(stale)
        store.context.insert(stalePinned)
        store.save()

        // The preview counts the stale unpinned clip alone; the pinned one
        // aged out by date but pins are exempt.
        let retentionPreview = store.deletionCount(under: .retentionDays(7))
        XCTAssertEqual(retentionPreview, 1)
        let before = store.clipCount()
        UserDefaults.standard.set(7, forKey: SettingsKeys.retentionDays)
        store.enforceRetention()
        XCTAssertEqual(before - store.clipCount(), retentionPreview,
                       "the sheet's number and the enforce pass disagree")
        XCTAssertEqual(store.deletionCount(under: .retentionDays(7)), 0)
        XCTAssertEqual(
            Set(store.recent(limit: 100).compactMap(\.text)),
            ["0", "1", "8", "9", "10", "11", "stale-pinned"],
            "the stale unpinned clip went; pins and in-window clips stayed"
        )
    }

    /// The Storage readout's bytes: the store file, its -wal sidecar and the
    /// hidden `.NAME_SUPPORT` external-storage folder all live beside each
    /// other in the store directory, so one recursive walk covers them. A
    /// symlink inside that directory (a screenshot's shape: a link to a file
    /// macOS saved elsewhere) must contribute nothing.
    func testHistoryDiskUsageSumsStoreAndExternalStorage() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("memoryclip-diskusage-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let storeFile = root.appendingPathComponent("MemoryClip.store")
        try Data(count: 100).write(to: storeFile)
        try Data(count: 40).write(to: URL(fileURLWithPath: storeFile.path + "-wal"))

        // The hidden external-storage folder Core Data keeps beside the
        // store, with a nested subdirectory inside it.
        let support = ClipStore.externalStorageDirectory(forStoreAt: storeFile)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(count: 23).write(to: support.appendingPathComponent("blob.bin"))
        let nested = support.appendingPathComponent("deep", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 7).write(to: nested.appendingPathComponent("nested.bin"))

        // A link whose target lives outside the store directory: the shape
        // of a screenshot clip's file reference. Its bytes are the user's
        // file elsewhere and must not land in the readout.
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("memoryclip-outside-\(UUID().uuidString)")
        try Data(count: 10_000).write(to: outside)
        defer { try? fileManager.removeItem(at: outside) }
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("screenshot-link.png"),
            withDestinationURL: outside
        )

        XCTAssertEqual(ClipStore.historyDiskUsage(storeAt: storeFile), 170,
                       "store + sidecar + external storage, symlink excluded")
    }
}
