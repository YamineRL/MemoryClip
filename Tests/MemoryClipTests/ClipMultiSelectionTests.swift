import AppKit
import XCTest

@testable import MemoryClip

/// A stand-in for `ClipItem`, so the selection logic is exercised without
/// SwiftData — the same reason `ClipListStateTests` carries one.
private struct FakeClip: ClipDisplayable {
    var uuid = UUID()
    var kind: ClipKind = .text
    var text: String?
    var ocrText: String?
    var colorHex: String?
    var fileURLStrings: [String] = []
    var sourceAppName: String?
}

final class ClipMultiSelectionTests: XCTestCase {
    private let ids = (0..<5).map { _ in UUID() }

    // MARK: One clip behaves as it always did

    func testAFreshSelectionIsNotExtended() {
        XCTAssertFalse(ClipSelection().isExtended)
        XCTAssertFalse(ClipSelection(id: ids[2]).isExtended)
    }

    func testASingleSelectionResolvesToOneClip() {
        let selection = ClipSelection(id: ids[3])
        XCTAssertEqual(selection.selectedIDs(in: ids), [ids[3]])
    }

    func testNothingChosenYetMeansTheTopRow() {
        XCTAssertEqual(ClipSelection().selectedIDs(in: ids), [ids[0]])
    }

    func testAnEmptyListSelectsNothing() {
        XCTAssertEqual(ClipSelection(id: ids[1]).selectedIDs(in: []), [])
    }

    // MARK: Range extension

    func testExtendingDownwardsTakesTheWholeRange() {
        var selection = ClipSelection(id: ids[1])
        selection.extend(to: 3, in: ids)
        XCTAssertEqual(selection.selectedIDs(in: ids), [ids[1], ids[2], ids[3]])
        XCTAssertTrue(selection.isExtended)
    }

    /// A range dragged upwards is the same set as one dragged downwards, and
    /// both come back in list order rather than the order they were touched.
    func testExtendingUpwardsIsTheSameRangeInListOrder() {
        var selection = ClipSelection(id: ids[3])
        selection.extend(to: 1, in: ids)
        XCTAssertEqual(selection.selectedIDs(in: ids), [ids[1], ids[2], ids[3]])
    }

    func testAnExtensionThatShrinksLeavesNothingBehind() {
        var selection = ClipSelection(id: ids[0])
        selection.extend(to: 4, in: ids)
        selection.extend(to: 1, in: ids)
        XCTAssertEqual(selection.selectedIDs(in: ids), [ids[0], ids[1]])
    }

    func testExtendingByADeltaWalksFromTheCursor() {
        var selection = ClipSelection(id: ids[1])
        selection.extend(by: 2, in: ids)
        XCTAssertEqual(selection.selectedIDs(in: ids), [ids[1], ids[2], ids[3]])
    }

    func testExtendingPastTheEndStopsAtTheEnd() {
        var selection = ClipSelection(id: ids[3])
        selection.extend(by: 99, in: ids)
        XCTAssertEqual(selection.selectedIDs(in: ids), [ids[3], ids[4]])
    }

    // MARK: Picking clips out one at a time

    func testTogglingAddsAClipAwayFromTheCursor() {
        var selection = ClipSelection(id: ids[0])
        selection.toggle(index: 3, in: ids)
        XCTAssertEqual(selection.selectedIDs(in: ids), [ids[0], ids[3]])
    }

    func testTogglingTwiceTakesItBackOut() {
        var selection = ClipSelection(id: ids[0])
        selection.toggle(index: 3, in: ids)
        selection.toggle(index: 3, in: ids)
        XCTAssertEqual(selection.selectedIDs(in: ids), [ids[0]])
    }

    /// Emptying the selection is refused: every panel key acts on a cursor,
    /// and nothing selected would leave Return and ⌘C with nothing to do.
    func testTheLastClipCannotBeToggledAway() {
        var selection = ClipSelection(id: ids[2])
        selection.toggle(index: 2, in: ids)
        XCTAssertEqual(selection.selectedIDs(in: ids), [ids[2]])
    }

    // MARK: Collapsing

    func testCollapsingDropsEverythingButTheCursor() {
        var selection = ClipSelection(id: ids[1])
        selection.extend(to: 4, in: ids)
        selection.toggle(index: 0, in: ids)
        selection.collapse()
        XCTAssertFalse(selection.isExtended)
        XCTAssertEqual(selection.selectedIDs(in: ids).count, 1)
    }

    func testASelectingMoveReplacesTheWholeSelection() {
        var selection = ClipSelection(id: ids[0])
        selection.extend(to: 3, in: ids)
        selection.select(index: 4, in: ids)
        XCTAssertFalse(selection.isExtended)
        XCTAssertEqual(selection.selectedIDs(in: ids), [ids[4]])
    }

    // MARK: Clips that leave the list

    /// The range is re-derived from the current list, so a clip filtered away
    /// drops out instead of lingering as a ghost that can still be pasted.
    func testClipsNoLongerOnScreenDropOutOfTheSelection() {
        var selection = ClipSelection(id: ids[0])
        selection.extend(to: 3, in: ids)

        let shrunk = [ids[0], ids[3]]
        XCTAssertEqual(selection.selectedIDs(in: shrunk), [ids[0], ids[3]])
    }

    func testAPickedClipThatLeavesTheListIsNotActedOn() {
        var selection = ClipSelection(id: ids[0])
        selection.toggle(index: 4, in: ids)
        XCTAssertEqual(selection.selectedIDs(in: [ids[0], ids[1]]), [ids[0]])
    }

    // MARK: Copying several clips

    func testCopyingSeveralClipsJoinsThemWithNewlines() {
        let clips = [FakeClip(text: "one"), FakeClip(text: "two"), FakeClip(text: "three")]
        XCTAssertEqual(ClipSelection.copyText(for: clips), "one\ntwo\nthree")
    }

    func testCopyingOneClipIsJustItsText() {
        XCTAssertEqual(ClipSelection.copyText(for: [FakeClip(text: "only")]), "only")
    }

    func testCopyingNothingIsEmpty() {
        XCTAssertEqual(ClipSelection.copyText(for: [FakeClip]()), "")
    }

    // MARK: What a click means

    func testAPlainClickPastes() {
        XCTAssertEqual(ClipClick.intent(for: []), .paste)
    }

    func testShiftClickExtends() {
        XCTAssertEqual(ClipClick.intent(for: .shift), .extend)
    }

    func testCommandClickToggles() {
        XCTAssertEqual(ClipClick.intent(for: .command), .toggle)
    }

    /// ⌘ wins, so a hand resting on shift cannot turn picking one clip out
    /// into replacing the whole selection.
    func testCommandBeatsShift() {
        XCTAssertEqual(ClipClick.intent(for: [.command, .shift]), .toggle)
    }

    func testModifiersThatMeanNothingHereStillPaste() {
        XCTAssertEqual(ClipClick.intent(for: [.option, .control]), .paste)
    }

    // MARK: Visual mode

    func testVisualModeReadsVimKeys() {
        XCTAssertTrue(PanelInputMode.visual.readsVimKeys)
        XCTAssertTrue(PanelInputMode.normal.readsVimKeys)
        XCTAssertFalse(PanelInputMode.insert.readsVimKeys, "typing is typing")
    }

    func testVisualModeNamesItselfInTheSearchBar() {
        XCTAssertEqual(PanelInputMode.visual.badge, "VISUAL")
    }

    func testEveryModeAnnouncesItself() {
        for mode in [PanelInputMode.normal, .visual, .insert] {
            XCTAssertFalse(mode.accessibilityName.isEmpty, "\(mode) must announce itself")
            XCTAssertFalse(mode.help.isEmpty, "\(mode) must carry help text")
        }
    }
}
