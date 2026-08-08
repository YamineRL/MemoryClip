import Foundation
import XCTest

@testable import MemoryClip

/// Maintenance (retention, cap trimming, thumbnail backfill) used to run
/// synchronously inside `applicationDidFinishLaunching`, before the menu-bar
/// item existed. These pin down that it is deferred instead — and that a quit
/// during the delay cancels it rather than starting a timer on the way out.
@MainActor
final class MaintenanceSchedulingTests: XCTestCase {
    private var previousRetention = 0
    private var previousCap = 0

    override func setUp() {
        super.setUp()
        previousRetention = UserDefaults.standard.integer(forKey: SettingsKeys.retentionDays)
        previousCap = UserDefaults.standard.integer(forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(30, forKey: SettingsKeys.retentionDays)
    }

    override func tearDown() {
        UserDefaults.standard.set(previousRetention, forKey: SettingsKeys.retentionDays)
        UserDefaults.standard.set(previousCap, forKey: SettingsKeys.historyCap)
        super.tearDown()
    }

    private func makeStore(expired: Int, fresh: Int, pinnedExpired: Int = 0) throws -> ClipStore {
        let store = try ClipStore(inMemory: true)
        let old = Date.now.addingTimeInterval(-60 * 24 * 3600)
        for i in 0..<expired {
            store.context.insert(ClipItem(
                kind: .text, text: "old \(i)",
                contentHash: "old:\(i)", createdAt: old
            ))
        }
        for i in 0..<pinnedExpired {
            store.context.insert(ClipItem(
                kind: .text, text: "pinned \(i)",
                contentHash: "pin:\(i)", createdAt: old, isPinned: true
            ))
        }
        for i in 0..<fresh {
            store.context.insert(ClipItem(
                kind: .text, text: "new \(i)",
                contentHash: "new:\(i)", createdAt: .now
            ))
        }
        store.save()
        return store
    }

    /// Nothing may be deleted before the delay elapses — that work is exactly
    /// what used to sit in front of the menu-bar item appearing.
    func testMaintenanceDoesNotRunUntilTheDelayElapses() async throws {
        let store = try makeStore(expired: 6, fresh: 2)

        let task = AppDelegate.scheduleMaintenance(for: store, after: .milliseconds(400))
        defer { task.cancel(); store.stopMaintenance() }

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.recent(limit: 100).count, 8, "maintenance ran on the launch path")
    }

    func testMaintenanceRunsAfterTheDelay() async throws {
        let store = try makeStore(expired: 6, fresh: 2, pinnedExpired: 1)

        let task = AppDelegate.scheduleMaintenance(for: store, after: .milliseconds(50))
        defer { task.cancel(); store.stopMaintenance() }

        var attempts = 0
        while store.recent(limit: 100).count > 3, attempts < 100 {
            try await Task.sleep(for: .milliseconds(20))
            attempts += 1
        }
        let remaining = store.recent(limit: 100)
        XCTAssertEqual(remaining.count, 3, "expired clips should be gone once maintenance runs")
        XCTAssertTrue(remaining.allSatisfy { $0.isPinned || $0.text?.hasPrefix("new") == true })
    }

    /// Quitting inside the delay window must not start the 15-minute timer.
    func testCancellingBeforeTheDelayLeavesTheStoreAlone() async throws {
        let store = try makeStore(expired: 5, fresh: 1)

        let task = AppDelegate.scheduleMaintenance(for: store, after: .milliseconds(300))
        task.cancel()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(store.recent(limit: 100).count, 6)
        store.stopMaintenance()
    }

    /// The launch delay must be a real one — the whole point is that nothing
    /// runs before the UI is up.
    func testMaintenanceStartDelayIsNonZero() {
        XCTAssertGreaterThan(AppDelegate.maintenanceStartDelay, .zero)
    }

    // MARK: Benchmark (MEMORYCLIP_BENCH=1)

    /// What the launch path used to wait on: one full maintenance pass over a
    /// large expiring backlog.
    func testMaintenancePassBenchmark() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEMORYCLIP_BENCH"] == "1",
            "set MEMORYCLIP_BENCH=1 to run benchmarks"
        )
        let backlog = 24_080
        let store = try makeStore(expired: backlog, fresh: 100)

        let start = DispatchTime.now().uptimeNanoseconds
        store.performMaintenance()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("BENCH | maintenance/one pass, \(backlog) expiring rows | \(elapsed) ms "
              + "(was on the launch path; now runs after it)")
        XCTAssertEqual(store.recent(limit: 100_000).count, 100)
    }
}
