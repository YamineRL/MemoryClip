import XCTest

@testable import MemoryClip

/// Which bubble the panel floats, and — the part worth pinning down — which
/// one wins when more than one could apply.
final class PanelHintTests: XCTestCase {
    // MARK: The deck

    func testNothingIsSaidWithoutAQuery() {
        XCTAssertNil(
            PanelHint.overStrip(selectedCount: 1, vimInsertMode: false, hasQuery: false, dismissed: false)
        )
    }

    func testAQueryNamesTheMovementKeys() {
        let hint = PanelHint.overStrip(
            selectedCount: 1,
            vimInsertMode: false,
            hasQuery: true,
            dismissed: false
        )
        XCTAssertEqual(hint, loc("↑ ↓ to pick · ↩ to paste"))
    }

    /// The bubble is answered by using the keys it names, so a movement
    /// silences it for the rest of that query.
    func testADismissedHintStaysDown() {
        XCTAssertNil(
            PanelHint.overStrip(selectedCount: 1, vimInsertMode: false, hasQuery: true, dismissed: true)
        )
    }

    /// Insert mode is where the letters go to the query rather than to vim,
    /// so the way back to them outranks the arrows — and is said even before
    /// anything has been typed, because `/` is what put the user there.
    func testInsertModeNamesTheWayBackToNormalMode() {
        for hasQuery in [true, false] {
            XCTAssertEqual(
                PanelHint.overStrip(
                    selectedCount: 1,
                    vimInsertMode: true,
                    hasQuery: hasQuery,
                    dismissed: false
                ),
                loc("↑ ↓ to pick · esc for h j k l"),
                "query: \(hasQuery)"
            )
        }
    }

    /// What Return is about to do to a whole range outranks everything else,
    /// and unlike the others it is a live count rather than a prompt: it
    /// survives the dismissal that silences the movement hints.
    func testAMultiSelectionOutranksTheOtherHintsAndAnyDismissal() {
        for dismissed in [true, false] {
            XCTAssertEqual(
                PanelHint.overStrip(
                    selectedCount: 3,
                    vimInsertMode: true,
                    hasQuery: true,
                    dismissed: dismissed
                ),
                loc("↩ pastes %d clips", 3),
                "dismissed: \(dismissed)"
            )
        }
    }

    /// One clip is not a multi-selection: the count only earns a bubble once
    /// Return would paste more than the card under the cursor.
    func testASingleSelectionIsNotACount() {
        XCTAssertNil(
            PanelHint.overStrip(selectedCount: 1, vimInsertMode: false, hasQuery: false, dismissed: false)
        )
    }

    // MARK: The preview pane

    func testQuickLookIsOfferedOnlyWhereItHasSomethingToShow() {
        XCTAssertEqual(
            PanelHint.overPreview(canQuickLook: true, dismissed: false),
            loc("space for Quick Look")
        )
        XCTAssertNil(PanelHint.overPreview(canQuickLook: false, dismissed: false))
    }

    func testQuickLookHintGoesOnceItHasBeenUsed() {
        XCTAssertNil(PanelHint.overPreview(canQuickLook: true, dismissed: true))
    }
}
