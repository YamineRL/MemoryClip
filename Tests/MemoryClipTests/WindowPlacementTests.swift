import XCTest

@testable import MemoryClip

/// Where a window opened on request lands. Reported as "I click Settings and
/// nothing shows": each case below is one way a window can open somewhere the
/// user is not looking. Plain rectangles, so it runs without a window server.
final class WindowPlacementTests: XCTestCase {
    /// A laptop screen with a menu bar, and an external one to its right.
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let laptopVisible = NSRect(x: 0, y: 0, width: 1512, height: 949)
    private let external = NSRect(x: 1512, y: 0, width: 2560, height: 1440)
    private let externalVisible = NSRect(x: 1512, y: 0, width: 2560, height: 1415)

    // MARK: Which screen

    func testTheScreenUnderThePointerIsTheTarget() {
        XCTAssertEqual(WindowPlacement.targetScreen(pointer: NSPoint(x: 2000, y: 700), screenFrames: [laptop, external]), 1)
    }

    func testThePointerInTheMenuBarStillCountsAsOnThatScreen() {
        XCTAssertEqual(
            WindowPlacement.targetScreen(pointer: NSPoint(x: 2000, y: 1440), screenFrames: [laptop, external]),
            1,
            "the pointer sits on the very top edge while it is clicking the menu bar item"
        )
    }

    func testAPointerOnNoScreenFallsBackToTheMainOne() {
        XCTAssertEqual(WindowPlacement.targetScreen(pointer: NSPoint(x: -500, y: -500), screenFrames: [laptop, external]), 0)
    }

    func testNoScreensMeansNoTarget() {
        XCTAssertNil(WindowPlacement.targetScreen(pointer: .zero, screenFrames: []))
    }

    // MARK: Reachable

    func testAWindowOnScreenIsReachable() {
        XCTAssertTrue(WindowPlacement.isReachable(NSRect(x: 200, y: 100, width: 888, height: 640), visibleFrames: [laptopVisible]))
    }

    func testAWindowLeftOnAnUnpluggedDisplayIsNot() {
        XCTAssertFalse(
            WindowPlacement.isReachable(NSRect(x: 2000, y: 300, width: 888, height: 640), visibleFrames: [laptopVisible]),
            "the external display is gone; the window is on no screen at all"
        )
    }

    func testAWindowWhoseTitleBarIsUnderTheMenuBarIsNot() {
        XCTAssertFalse(
            WindowPlacement.isReachable(NSRect(x: 200, y: 400, width: 888, height: 600), visibleFrames: [laptopVisible]),
            "the body shows but there is nothing left to drag it down by"
        )
    }

    func testASliverOfTitleBarIsNotEnoughToGrab() {
        XCTAssertFalse(WindowPlacement.isReachable(NSRect(x: 1490, y: 100, width: 888, height: 640), visibleFrames: [laptopVisible]))
    }

    // MARK: Opening frame

    func testAFirstOpeningIsCentredOnTheUsersScreen() {
        let frame = WindowPlacement.openingFrame(
            current: NSRect(x: 0, y: 0, width: 888, height: 640),
            minimumSize: NSSize(width: 700, height: 480),
            keepPosition: false,
            target: externalVisible
        )
        XCTAssertEqual(frame.size, NSSize(width: 888, height: 640))
        XCTAssertEqual(frame.midX, externalVisible.midX, accuracy: 1)
        XCTAssertTrue(externalVisible.contains(frame))
        XCTAssertGreaterThan(frame.midY, externalVisible.midY, "a little above the middle, as AppKit centres")
    }

    func testAChosenPositionOnTheUsersScreenIsKept() {
        let chosen = NSRect(x: 100, y: 120, width: 888, height: 640)
        XCTAssertEqual(
            WindowPlacement.openingFrame(current: chosen, minimumSize: .zero, keepPosition: true, target: laptopVisible),
            chosen
        )
    }

    func testAChosenPositionOnAnotherScreenComesToTheUsersOne() {
        let frame = WindowPlacement.openingFrame(
            current: NSRect(x: 2000, y: 300, width: 888, height: 640),
            minimumSize: .zero,
            keepPosition: true,
            target: laptopVisible
        )
        XCTAssertTrue(laptopVisible.contains(frame), "the user is on the laptop; that is where it opens")
    }

    func testAWindowTallerThanTheScreenIsShrunkToFit() {
        let small = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let frame = WindowPlacement.openingFrame(
            current: NSRect(x: 0, y: 0, width: 888, height: 932),
            minimumSize: NSSize(width: 700, height: 480),
            keepPosition: false,
            target: small
        )
        XCTAssertTrue(small.contains(frame), "the bottom of a window cut off by the Dock is a window with no buttons")
        XCTAssertEqual(frame.height, 720)
    }
}
