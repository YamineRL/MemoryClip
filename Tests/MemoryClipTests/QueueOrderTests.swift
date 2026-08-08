import AppKit
import XCTest

@testable import MemoryClip

final class QueueOrderTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    func testStartsEmpty() {
        let order = QueueOrder()
        XCTAssertTrue(order.isEmpty)
        XCTAssertEqual(order.count, 0)
        XCTAssertNil(order.position(of: a))
    }

    func testToggleAppendsInOrder() {
        var order = QueueOrder()
        order.toggle(a)
        order.toggle(b)
        order.toggle(c)
        XCTAssertEqual(order.ids, [a, b, c])
        XCTAssertEqual(order.position(of: a), 1)
        XCTAssertEqual(order.position(of: c), 3)
    }

    func testToggleTwiceRemovesAndRenumbers() {
        var order = QueueOrder()
        order.toggle(a)
        order.toggle(b)
        order.toggle(c)
        order.toggle(a)
        XCTAssertFalse(order.contains(a))
        XCTAssertEqual(order.position(of: b), 1)
        XCTAssertEqual(order.position(of: c), 2)
    }

    func testReQueuingAppendsAtTheEnd() {
        var order = QueueOrder()
        order.toggle(a)
        order.toggle(b)
        order.toggle(a) // remove
        order.toggle(a) // add back
        XCTAssertEqual(order.ids, [b, a])
    }

    func testRetainDropsMissingIDsAndKeepsOrder() {
        var order = QueueOrder()
        order.toggle(a)
        order.toggle(b)
        order.toggle(c)
        order.retain(existing: [c, a])
        XCTAssertEqual(order.ids, [a, c])
    }

    func testRemoveAndClear() {
        var order = QueueOrder()
        order.toggle(a)
        order.toggle(b)
        order.remove(a)
        XCTAssertEqual(order.ids, [b])
        order.clear()
        XCTAssertTrue(order.isEmpty)
    }
}

/// Runs of `QueueService.pasteAll`, exercised against a private pasteboard
/// with auto-paste off, so no synthetic keystrokes are posted and the user's
/// real clipboard is never touched.
@MainActor
final class QueueServiceRunTests: XCTestCase {
    private var store: ClipStore!
    private var queue: QueueService!

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
        UserDefaults.standard.set(false, forKey: SettingsKeys.autoPaste)

        store = try ClipStore(inMemory: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("memoryclip-queue-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let pasteService = PasteService(
            store: store,
            watcher: PasteboardWatcher(store: store),
            pasteboard: pasteboard
        )
        queue = QueueService(store: store, pasteService: pasteService)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.autoPaste)
        try await super.tearDown()
    }

    @discardableResult
    private func insertClips(_ count: Int) -> [ClipItem] {
        for index in 0..<count {
            store.insert(
                CapturedClip(
                    kind: .text,
                    text: "clip \(index)",
                    richTextData: nil,
                    imageData: nil,
                    fileURLStrings: [],
                    colorHex: nil,
                    hash: ContentParser.hashText("text:queue-\(UUID().uuidString)")
                ),
                sourceBundleID: nil,
                sourceAppName: nil
            )
        }
        return Array(store.recent(limit: count).reversed())
    }

    private func waitUntilIdle(timeout: TimeInterval = 10) async {
        var waited: TimeInterval = 0
        while queue.isPasting && waited < timeout {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
    }

    func testRunPastesEveryClipAndClearsTheQueue() async throws {
        for item in insertClips(3) { queue.toggle(item) }
        XCTAssertEqual(queue.count, 3)

        queue.pasteAll(target: nil)
        XCTAssertTrue(queue.isPasting)
        await waitUntilIdle()

        XCTAssertFalse(queue.isPasting)
        XCTAssertTrue(queue.isEmpty)
        // Every clip was actually written back (markUsed stamps lastUsedAt).
        XCTAssertEqual(store.recent(limit: 3).filter { $0.lastUsedAt != nil }.count, 3)
    }

    func testCancelStopsTheRunAndKeepsTheQueue() async throws {
        for item in insertClips(4) { queue.toggle(item) }

        queue.pasteAll(target: nil)
        queue.cancel()

        XCTAssertFalse(queue.isPasting)
        XCTAssertEqual(queue.count, 4, "A cancelled run must not clear the queue")
    }

    /// The epilogue bug: a cancelled run resuming from its interrupted sleep
    /// used to clear a NEWER run's queue and drop its task handle.
    func testCancelledRunDoesNotClobberTheNextRun() async throws {
        let items = insertClips(6)
        for item in items.prefix(3) { queue.toggle(item) }

        queue.pasteAll(target: nil)
        queue.cancel()

        // A fresh queue and a fresh run, started while the cancelled task is
        // still parked in its sleep.
        queue.clear()
        for item in items.suffix(3) { queue.toggle(item) }
        queue.pasteAll(target: nil)

        // Well past the point where the cancelled run's epilogue would have
        // fired, but before the new run can legitimately finish.
        try await Task.sleep(for: .seconds(QueueService.pasteInterval + 0.2))
        XCTAssertTrue(queue.isPasting, "The cancelled run stole the new run's state")
        XCTAssertFalse(queue.isEmpty, "The cancelled run cleared the new run's queue")

        await waitUntilIdle()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertFalse(queue.isPasting)
    }

    func testRunSkipsDeletedClips() async throws {
        let items = insertClips(3)
        for item in items { queue.toggle(item) }
        store.delete(items[1])

        queue.pasteAll(target: nil)
        await waitUntilIdle()

        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(store.recent(limit: 5).filter { $0.lastUsedAt != nil }.count, 2)
    }
}
