import XCTest

@testable import MemoryClip

/// The watcher's decision surface, tested without a folder, a screenshot or
/// a file-system event: which files a pass picks up, when a file is finished
/// being written, how far the "already seen" watermark may move, and how a
/// lost folder is retried.
final class ScreenshotWatcherTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ name: String, offset: TimeInterval, size: Int = 1024) -> ScreenshotWatcher.Entry {
        ScreenshotWatcher.Entry(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            timestamp: base.addingTimeInterval(offset),
            size: size
        )
    }

    // MARK: - Selection

    func testOnlyFilesNewerThanTheMarkAreCaptured() {
        let entries = [entry("old.png", offset: -60), entry("new.png", offset: 60)]
        let picked = ScreenshotWatcher.entriesToCapture(from: entries, after: base, limit: 10)
        XCTAssertEqual(picked.map(\.url.lastPathComponent), ["new.png"])
    }

    func testAFileExactlyAtTheMarkIsNotRecaptured() {
        // `>=` here would re-capture the newest screenshot on every single
        // file-system event for the rest of the session.
        let entries = [entry("same.png", offset: 0)]
        XCTAssertTrue(ScreenshotWatcher.entriesToCapture(from: entries, after: base, limit: 10).isEmpty)
    }

    func testEmptyFilesAreSkipped() {
        // A screenshot exists as a zero-byte file for a moment before the
        // encoder writes to it.
        let entries = [entry("half-written.png", offset: 10, size: 0)]
        XCTAssertTrue(ScreenshotWatcher.entriesToCapture(from: entries, after: base, limit: 10).isEmpty)
    }

    func testABacklogYieldsTheNewestFilesFirstAndIsBounded() {
        let entries = (1...10).map { entry("shot\($0).png", offset: TimeInterval($0)) }
        let picked = ScreenshotWatcher.entriesToCapture(from: entries.shuffled(), after: base, limit: 3)
        XCTAssertEqual(picked.map(\.url.lastPathComponent), ["shot10.png", "shot9.png", "shot8.png"])
    }

    func testAZeroLimitCapturesNothing() {
        let entries = [entry("new.png", offset: 60)]
        XCTAssertTrue(ScreenshotWatcher.entriesToCapture(from: entries, after: base, limit: 0).isEmpty)
    }

    // MARK: - Stability

    func testStabilityRequiresTwoEqualNonZeroMeasurements() {
        XCTAssertTrue(ScreenshotWatcher.isStable(previousSize: 4096, currentSize: 4096))
        // Still growing.
        XCTAssertFalse(ScreenshotWatcher.isStable(previousSize: 2048, currentSize: 4096))
        // Vanished between the two looks.
        XCTAssertFalse(ScreenshotWatcher.isStable(previousSize: 4096, currentSize: nil))
        // Truncated to nothing.
        XCTAssertFalse(ScreenshotWatcher.isStable(previousSize: 0, currentSize: 0))
    }

    // MARK: - The watermark

    func testMarkAdvancesToTheNewestCapturedFile() {
        let mark = ScreenshotWatcher.advancedMark(
            from: base,
            captured: [base.addingTimeInterval(10), base.addingTimeInterval(30)],
            deferred: []
        )
        XCTAssertEqual(mark, base.addingTimeInterval(30))
    }

    func testMarkNeverMovesPastAFileThatIsStillSettling() {
        // The 30s file was captured, but the 20s one is still being written.
        // Moving the mark to 30 would strand it behind the watermark and it
        // would never be looked at again.
        let mark = ScreenshotWatcher.advancedMark(
            from: base,
            captured: [base.addingTimeInterval(30)],
            deferred: [base.addingTimeInterval(20)]
        )
        XCTAssertEqual(mark, base, "The mark must stay put until the older file settles")
    }

    func testMarkNeverMovesBackwards() {
        let mark = ScreenshotWatcher.advancedMark(
            from: base,
            captured: [base.addingTimeInterval(-500)],
            deferred: []
        )
        XCTAssertEqual(mark, base)
    }

    func testMarkIsUnchangedWhenNothingHappened() {
        XCTAssertEqual(
            ScreenshotWatcher.advancedMark(from: base, captured: [], deferred: []),
            base
        )
    }

    // MARK: - Reopening a lost folder

    func testReopenDelayBacksOffExponentiallyAndThenPlateaus() {
        XCTAssertEqual(ScreenshotWatcher.reopenDelay(forAttempt: 1), .seconds(1))
        XCTAssertEqual(ScreenshotWatcher.reopenDelay(forAttempt: 2), .seconds(2))
        XCTAssertEqual(ScreenshotWatcher.reopenDelay(forAttempt: 3), .seconds(4))
        XCTAssertEqual(ScreenshotWatcher.reopenDelay(forAttempt: 5), .seconds(16))
        // An unmounted volume can be gone for a day; the retry must not
        // become a busy loop or grow without bound.
        XCTAssertEqual(ScreenshotWatcher.reopenDelay(forAttempt: 20), ScreenshotWatcher.maxReopenDelay)
        XCTAssertEqual(ScreenshotWatcher.reopenDelay(forAttempt: 5000), ScreenshotWatcher.maxReopenDelay)
    }

    // MARK: - Defaults

    func testCaptureIsOffUntilTheUserAsksForIt() {
        // It needs access to a folder macOS guards, so it cannot be on by
        // default without the app reaching somewhere it was never granted.
        UserDefaults.standard.removeObject(forKey: ScreenshotWatcher.enabledKey)
        NoteSettingsKeys.registerDefaults()
        XCTAssertFalse(ScreenshotWatcher.isEnabled)
    }
}
