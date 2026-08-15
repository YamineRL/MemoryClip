import XCTest

@testable import MemoryClip

final class VimNavigatorTests: XCTestCase {
    // MARK: Key mapping

    func testSingleKeysMapToCommands() {
        var vim = VimNavigator()
        XCTAssertEqual(vim.command(for: "j"), .down)
        XCTAssertEqual(vim.command(for: "k"), .up)
        XCTAssertEqual(vim.command(for: "G"), .bottom)
        XCTAssertEqual(vim.command(for: "o"), .paste)
        XCTAssertEqual(vim.command(for: "O"), .pastePlain)
        XCTAssertEqual(vim.command(for: "p"), .pin)
        XCTAssertEqual(vim.command(for: "q"), .queueToggle)
        XCTAssertEqual(vim.command(for: "Q"), .queuePaste)
    }

    /// Space belongs to the panel's dedicated preview handler, so the
    /// navigator must not claim it.
    func testSpaceIsNotAVimBinding() {
        var vim = VimNavigator()
        XCTAssertNil(vim.command(for: " "))
        XCTAssertFalse(vim.hasPending)
    }

    func testSearchKeysEnterInsertMode() {
        var vim = VimNavigator()
        XCTAssertEqual(vim.command(for: "/"), .enterSearch)
        XCTAssertEqual(vim.command(for: "i"), .enterInsert)
    }

    /// `n` is free because the panel has no "next match" for vim's `n` to
    /// repeat — the search filters the list as it is typed. It only counts in
    /// NORMAL, where plain characters are commands; in INSERT the same key
    /// has to type an `n` into the query, which is what ⌘S is for.
    func testSaveNoteKeyIsBoundAndNormalModeOnly() {
        var vim = VimNavigator()
        XCTAssertEqual(vim.command(for: "n"), .saveNote)
        XCTAssertFalse(vim.hasPending)
        XCTAssertTrue(PanelInputMode.normal.readsVimKeys)
        XCTAssertFalse(PanelInputMode.insert.readsVimKeys, "typing `n` must reach the search field")
    }

    func testUnboundKeyReturnsNilAndLeavesNoPending() {
        var vim = VimNavigator()
        XCTAssertNil(vim.command(for: "z"))
        XCTAssertFalse(vim.hasPending)
    }

    func testDoubleGJumpsToTop() {
        var vim = VimNavigator()
        XCTAssertNil(vim.command(for: "g"))
        XCTAssertTrue(vim.hasPending)
        XCTAssertEqual(vim.command(for: "g"), .top)
        XCTAssertFalse(vim.hasPending)
    }

    func testDoubleDDeletes() {
        var vim = VimNavigator()
        XCTAssertNil(vim.command(for: "d"))
        XCTAssertEqual(vim.command(for: "d"), .delete)
    }

    func testAbortedSequenceIsSwallowedAndClearsPending() {
        var vim = VimNavigator()
        _ = vim.command(for: "g")
        XCTAssertNil(vim.command(for: "j"), "g followed by j is not a binding")
        XCTAssertFalse(vim.hasPending)
        // The next j is a normal movement again.
        XCTAssertEqual(vim.command(for: "j"), .down)
    }

    func testControlKeysArePageMovesAndClearPending() {
        var vim = VimNavigator()
        _ = vim.command(for: "g")
        XCTAssertEqual(vim.command(for: "d", modifiers: .control), .halfPageDown)
        XCTAssertFalse(vim.hasPending, "control keys abandon a pending sequence")
        XCTAssertEqual(vim.command(for: "u", modifiers: .control), .halfPageUp)
        XCTAssertNil(vim.command(for: "j", modifiers: .control))
    }

    func testResetClearsPending() {
        var vim = VimNavigator()
        _ = vim.command(for: "d")
        vim.reset()
        XCTAssertFalse(vim.hasPending)
        XCTAssertEqual(vim.command(for: "d"), nil)
        XCTAssertTrue(vim.hasPending)
    }

    // MARK: Index resolution

    func testMovementClampsToBounds() {
        XCTAssertEqual(VimNavigator.newIndex(for: .up, index: 0, count: 5), 0)
        XCTAssertEqual(VimNavigator.newIndex(for: .down, index: 4, count: 5), 4)
        XCTAssertEqual(VimNavigator.newIndex(for: .down, index: 0, count: 5), 1)
        XCTAssertEqual(VimNavigator.newIndex(for: .up, index: 3, count: 5), 2)
    }

    func testTopAndBottom() {
        XCTAssertEqual(VimNavigator.newIndex(for: .top, index: 3, count: 5), 0)
        XCTAssertEqual(VimNavigator.newIndex(for: .bottom, index: 0, count: 5), 4)
    }

    func testHalfPageMovesByPageSizeAndClamps() {
        XCTAssertEqual(VimNavigator.newIndex(for: .halfPageDown, index: 0, count: 50, pageSize: 10), 10)
        XCTAssertEqual(VimNavigator.newIndex(for: .halfPageUp, index: 12, count: 50, pageSize: 10), 2)
        XCTAssertEqual(VimNavigator.newIndex(for: .halfPageDown, index: 45, count: 50, pageSize: 10), 49)
        XCTAssertEqual(VimNavigator.newIndex(for: .halfPageUp, index: 3, count: 50, pageSize: 10), 0)
    }

    func testNonMovementCommandsLeaveIndexAlone() {
        XCTAssertEqual(VimNavigator.newIndex(for: .paste, index: 2, count: 5), 2)
        XCTAssertEqual(VimNavigator.newIndex(for: .queueToggle, index: 2, count: 5), 2)
        XCTAssertEqual(VimNavigator.newIndex(for: .saveNote, index: 2, count: 5), 2)
    }

    func testEmptyListAlwaysResolvesToZero() {
        XCTAssertEqual(VimNavigator.newIndex(for: .bottom, index: 7, count: 0), 0)
        XCTAssertEqual(VimNavigator.newIndex(for: .down, index: 7, count: 0), 0)
    }

    func testZeroPageSizeStillMovesOneRow() {
        XCTAssertEqual(VimNavigator.newIndex(for: .halfPageDown, index: 0, count: 5, pageSize: 0), 1)
    }
}
