import XCTest

@testable import MemoryClip

final class HeldKeyPacerTests: XCTestCase {
    // MARK: Throttling repeats

    /// The first press is the one the user is waiting on, so it is never
    /// throttled and the preview follows it straight away.
    func testFirstPressMovesImmediately() {
        var pacer = HeldKeyPacer()
        XCTAssertEqual(pacer.step(isRepeat: false, now: 100), .move)
    }

    func testRepeatInsideTheIntervalIsDropped() {
        var pacer = HeldKeyPacer()
        XCTAssertEqual(pacer.step(isRepeat: false, now: 0), .move)
        let tooSoon = HeldKeyPacer.minimumRepeatInterval / 2
        XCTAssertEqual(pacer.step(isRepeat: true, now: tooSoon), .drop)
    }

    func testRepeatOutsideTheIntervalMoves() {
        var pacer = HeldKeyPacer()
        XCTAssertEqual(pacer.step(isRepeat: false, now: 0), .move)
        let later = HeldKeyPacer.minimumRepeatInterval
        XCTAssertEqual(pacer.step(isRepeat: true, now: later), .moveSettlingPreview)
    }

    /// A dropped repeat must not push the window out, or a fast system
    /// key-repeat rate would starve the panel of movement entirely: the
    /// interval is measured between the steps the user actually saw.
    func testDroppedRepeatsDoNotDelayTheNextAcceptedStep() {
        var pacer = HeldKeyPacer()
        XCTAssertEqual(pacer.step(isRepeat: false, now: 0), .move)
        for event in stride(from: 0.02, to: HeldKeyPacer.minimumRepeatInterval, by: 0.02) {
            XCTAssertEqual(pacer.step(isRepeat: true, now: event), .drop, "event at \(event)")
        }
        XCTAssertEqual(
            pacer.step(isRepeat: true, now: HeldKeyPacer.minimumRepeatInterval),
            .moveSettlingPreview
        )
    }

    /// The user's own presses are their own business: tapping the key faster
    /// than the throttle still moves every time. Only the preview holds back.
    func testRealPressesAreNeverThrottled() {
        var pacer = HeldKeyPacer()
        XCTAssertEqual(pacer.step(isRepeat: false, now: 0), .move)
        XCTAssertEqual(pacer.step(isRepeat: false, now: 0.01), .moveSettlingPreview)
        XCTAssertEqual(pacer.step(isRepeat: false, now: 0.02), .moveSettlingPreview)
    }

    /// Reopening the panel starts a new run: the pace of the last one must
    /// not be held against the first keystroke of this one.
    func testResetMakesTheNextStepCountAsFresh() {
        var pacer = HeldKeyPacer()
        XCTAssertEqual(pacer.step(isRepeat: false, now: 0), .move)
        pacer.reset()
        XCTAssertEqual(pacer.step(isRepeat: true, now: 0.01), .move)
    }

    /// The whole point of the throttle: at the fastest system key-repeat
    /// setting the list still walks at a readable pace rather than a blur.
    func testFastestSystemRepeatRateIsPacedDown() {
        var pacer = HeldKeyPacer()
        // ~15 ms between events is the floor macOS will deliver.
        let eventInterval = 0.015
        var moves = 0
        for tick in 0...Int(1.0 / eventInterval) {
            let now = Double(tick) * eventInterval
            if pacer.step(isRepeat: tick > 0, now: now) != .drop { moves += 1 }
        }
        XCTAssertLessThanOrEqual(moves, 9, "a second of holding should not cross a screenful twice")
        XCTAssertGreaterThanOrEqual(moves, 7, "and it should still feel like movement")
    }

    // MARK: Settling the preview

    /// A held key must never open a gap wide enough for the preview to start
    /// loading a clip that is only being passed over, which is only true
    /// while the settle delay is the longer of the two.
    func testSettleDelayOutlastsTheRepeatInterval() {
        XCTAssertGreaterThan(HeldKeyPacer.previewSettleDelay, HeldKeyPacer.minimumRepeatInterval)
    }

    func testHeldKeyRunSettlesThePreviewThroughout() {
        var pacer = HeldKeyPacer()
        XCTAssertEqual(pacer.step(isRepeat: false, now: 0), .move)
        var now = 0.0
        for _ in 0..<40 {
            now += HeldKeyPacer.minimumRepeatInterval
            XCTAssertEqual(pacer.step(isRepeat: true, now: now), .moveSettlingPreview)
        }
    }

    /// Once the keys go quiet, the next deliberate press is a destination
    /// again and the pane is allowed to load with it.
    func testPressAfterAPauseLetsThePreviewFollowAgain() {
        var pacer = HeldKeyPacer()
        XCTAssertEqual(pacer.step(isRepeat: false, now: 0), .move)
        let afterTheRun = HeldKeyPacer.previewSettleDelay + 0.01
        XCTAssertEqual(pacer.step(isRepeat: false, now: afterTheRun), .move)
    }
}
