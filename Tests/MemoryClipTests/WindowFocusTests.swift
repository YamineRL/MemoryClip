import XCTest

@testable import MemoryClip

/// Which of MemoryClip's windows a system prompt is allowed to hand focus
/// back to. The rule is three booleans wide on purpose: the version that took
/// an `NSWindow` could only be exercised against a window server, and the one
/// failure that matters here — ordering the clip panel back in after the user
/// dismissed it — is a behaviour nobody would notice until it shipped.
@MainActor
final class WindowFocusTests: XCTestCase {
    func testATitledVisibleWindowIsRestored() {
        XCTAssertTrue(
            WindowFocus.isRestorable(isVisible: true, isTitled: true, isPanel: false),
            "Settings and the tour are exactly this, and they are the whole point"
        )
    }

    func testAPanelIsNeverRestored() {
        XCTAssertFalse(
            WindowFocus.isRestorable(isVisible: true, isTitled: true, isPanel: true),
            "the clip deck, Quick Look and the QR window hide themselves on resign — ordering one back in undoes a dismissal the user meant"
        )
    }

    func testAnUnseenWindowIsNotSummoned() {
        XCTAssertFalse(
            WindowFocus.isRestorable(isVisible: false, isTitled: true, isPanel: false),
            "answering a permission prompt must not open a window that was not already on screen"
        )
    }

    func testAnUntitledWindowIsNotRestored() {
        XCTAssertFalse(
            WindowFocus.isRestorable(isVisible: true, isTitled: false, isPanel: false),
            "borderless windows are chrome, not somewhere the user was reading"
        )
    }
}
