import Foundation
import SwiftData
import XCTest

@testable import MemoryClip

/// The pinboard model and the ordering helpers (PRD 06), exercised against a
/// real in-memory store: a create that cannot see the context's pending rows
/// would pass against stubs and still write a duplicate name to disk.
@MainActor
final class PinboardTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema([ClipItem.self, Pinboard.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    @discardableResult
    private func clip(text: String, pinned: Bool = false) -> ClipItem {
        let item = ClipItem(kind: .text, text: text, contentHash: UUID().uuidString, isPinned: pinned)
        context.insert(item)
        return item
    }

    // MARK: Naming

    func testCreateTrimsAndRejectsBlankNames() throws {
        XCTAssertNil(Pinboard.create(named: "   ", in: context))
        XCTAssertNil(Pinboard.create(named: "\n\t", in: context))
        let board = try XCTUnwrap(Pinboard.create(named: "  Addresses  ", in: context))
        XCTAssertEqual(board.name, "Addresses", "the stored name is the trimmed one")
    }

    func testCreateRejectsANameOverTheLimit() {
        let tooLong = String(repeating: "a", count: Pinboard.maximumNameLength + 1)
        XCTAssertNil(Pinboard.create(named: tooLong, in: context))
        XCTAssertNotNil(Pinboard.create(named: String(tooLong.prefix(Pinboard.maximumNameLength)), in: context))
    }

    /// The duplicate guard is case-insensitive: "addresses" and "Addresses"
    /// are the same chip twice over.
    func testCreateRejectsDuplicateNamesCaseInsensitively() throws {
        try XCTUnwrap(Pinboard.create(named: "Addresses", in: context))
        try context.save()
        XCTAssertNil(Pinboard.create(named: "addresses", in: context))
        XCTAssertNil(Pinboard.create(named: "ADDRESSES", in: context))
        XCTAssertNotNil(Pinboard.create(named: "Commands", in: context))
    }

    /// `create` must see rows still pending a save: two creates inside one
    /// transaction are how the strip and the picker both work.
    func testCreateSeesUnsavedBoards() throws {
        try XCTUnwrap(Pinboard.create(named: "Addresses", in: context))
        XCTAssertNil(Pinboard.create(named: "addresses", in: context), "no save happened yet")
    }

    func testBoardsTakeDistinctColoursAndSequentialPositions() throws {
        let first = try XCTUnwrap(Pinboard.create(named: "One", in: context))
        let second = try XCTUnwrap(Pinboard.create(named: "Two", in: context))
        XCTAssertEqual(first.order, 0)
        XCTAssertEqual(second.order, 1)
        XCTAssertNotEqual(
            first.colorName, second.colorName,
            "a new board takes the first colour nothing is using"
        )
    }

    // MARK: Rename and reorder

    func testRenameAppliesTheSameRulesAsCreate() throws {
        let board = try XCTUnwrap(Pinboard.create(named: "Addresses", in: context))
        let other = try XCTUnwrap(Pinboard.create(named: "Commands", in: context))
        XCTAssertFalse(board.rename(to: "commands", in: context), "another board's name is taken")
        XCTAssertFalse(board.rename(to: "   ", in: context))
        XCTAssertTrue(board.rename(to: board.name, in: context), "renaming to its own name is a no-op that passes")
        XCTAssertTrue(board.rename(to: "  Canned Replies ", in: context))
        XCTAssertEqual(board.name, "Canned Replies")
        XCTAssertEqual(other.name, "Commands")
    }

    func testMoveKeepsTheStripDense() throws {
        let a = try XCTUnwrap(Pinboard.create(named: "A", in: context))
        let b = try XCTUnwrap(Pinboard.create(named: "B", in: context))
        let c = try XCTUnwrap(Pinboard.create(named: "C", in: context))
        c.move(by: -1, in: context)
        XCTAssertEqual(Pinboard.all(in: context).map(\.name), ["A", "C", "B"])
        XCTAssertEqual(Pinboard.all(in: context).map(\.order), [0, 1, 2], "orders renumber to match")
        a.move(by: -1, in: context)
        b.move(by: 4, in: context)
        XCTAssertEqual(Pinboard.all(in: context).map(\.name), ["A", "C", "B"], "off-edge moves do nothing")
    }

    // MARK: Filing

    /// Filing pins: a board member must survive the cap and the retention
    /// sweep, which is what `isPinned` already guarantees.
    func testFilingAClipPinsItAndAppends() throws {
        let board = try XCTUnwrap(Pinboard.create(named: "Addresses", in: context))
        let item = clip(text: "42 Shipping Lane")
        XCTAssertFalse(item.isPinned)
        item.file(into: board)
        XCTAssertTrue(item.isPinned)
        XCTAssertEqual(item.pinboard?.uuid, board.uuid)
        XCTAssertEqual(item.pinboardOrder, 0, "the first member lands at the head")

        let second = clip(text: "7 Wharf Road", pinned: true)
        second.file(into: board)
        XCTAssertEqual(second.pinboardOrder, 1, "a filed clip appends past the tail")
    }

    /// One clip, at most one board: filing again moves rather than copies.
    func testFilingElsewhereMovesTheClip() throws {
        let a = try XCTUnwrap(Pinboard.create(named: "A", in: context))
        let b = try XCTUnwrap(Pinboard.create(named: "B", in: context))
        let item = clip(text: "moved")
        item.file(into: a)
        item.file(into: b)
        try context.save()
        XCTAssertEqual(item.pinboard?.uuid, b.uuid)
        XCTAssertEqual(item.pinboardOrder, 0)
        XCTAssertTrue(a.clips.isEmpty, "the clip left the old board")
        XCTAssertEqual(b.orderedClips.map(\.uuid), [item.uuid])
    }

    /// Pinned is a board of its own kind: `pinToPinned` rather than a bare
    /// `isPinned` write, so a clip filed somewhere leaves its board behind.
    func testPinToPinnedClearsTheBoard() throws {
        let board = try XCTUnwrap(Pinboard.create(named: "A", in: context))
        let item = clip(text: "back to pinned")
        item.file(into: board)
        item.pinToPinned()
        XCTAssertTrue(item.isPinned)
        XCTAssertNil(item.pinboard)
        XCTAssertNil(item.pinboardOrder)
    }

    /// The invariant the panel relies on: no `isPinned` without the board
    /// going too. A bare `isPinned = false` would orphan the membership.
    func testUnpinClearsTheBoard() throws {
        let board = try XCTUnwrap(Pinboard.create(named: "A", in: context))
        let item = clip(text: "unpin me")
        item.file(into: board)
        item.unpin()
        XCTAssertFalse(item.isPinned)
        XCTAssertNil(item.pinboard)
        XCTAssertNil(item.pinboardOrder)
    }

    /// A board is a grouping, not ownership: deleting it must never delete
    /// the clips, which land back in Pinned.
    func testDeletingABoardReturnsItsClipsToPinned() throws {
        let board = try XCTUnwrap(Pinboard.create(named: "Addresses", in: context))
        let keep = clip(text: "keep me")
        keep.file(into: board)
        try context.save()

        board.delete(in: context)
        try context.save()

        XCTAssertTrue(Pinboard.all(in: context).isEmpty)
        XCTAssertTrue(keep.isPinned, "the clip stays pinned")
        XCTAssertNil(keep.pinboard)
        XCTAssertNil(keep.pinboardOrder)
        let remaining = try context.fetch(FetchDescriptor<ClipItem>())
        XCTAssertEqual(remaining.count, 1, "the clip was not deleted with the board")
    }

    // MARK: Manual order

    func testOrderedClipsSortByPinboardOrderThenRecency() throws {
        let board = try XCTUnwrap(Pinboard.create(named: "A", in: context))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = clip(text: "first")
        let second = clip(text: "second")
        second.createdAt = base
        first.createdAt = base.addingTimeInterval(60)
        first.file(into: board, order: 2)
        second.file(into: board, order: 1)
        XCTAssertEqual(board.orderedClips.map(\.uuid), [second.uuid, first.uuid])

        // A member that never got an order sorts after every ordered one,
        // newest first among itself.
        let unordered = clip(text: "unordered")
        unordered.createdAt = base.addingTimeInterval(120)
        unordered.file(into: board, order: nil)
        unordered.pinboardOrder = nil
        XCTAssertEqual(board.orderedClips.last?.uuid, unordered.uuid)
    }

    func testMoveWritesTheMidpoint() throws {
        let board = try XCTUnwrap(Pinboard.create(named: "A", in: context))
        let a = clip(text: "a")
        let b = clip(text: "b")
        let c = clip(text: "c")
        for item in [a, b, c] { item.file(into: board) }
        // a:0 b:1 c:2 -> move c between a and b
        c.move(within: board, to: 1)
        XCTAssertEqual(board.orderedClips.map(\.uuid), [a.uuid, c.uuid, b.uuid])
        XCTAssertEqual(c.pinboardOrder, 0.5)
        // One step back along the strip restores it.
        c.move(within: board, by: 1)
        XCTAssertEqual(board.orderedClips.map(\.uuid), [a.uuid, b.uuid, c.uuid])
    }

    /// When the gap between two members falls under `minimumGap`, halving
    /// would write a collision: the move renumbers the board instead, so no
    /// two clips can ever tie.
    func testMoveRenumbersWhenTheGapCollapses() throws {
        let board = try XCTUnwrap(Pinboard.create(named: "A", in: context))
        let a = clip(text: "a")
        let b = clip(text: "b")
        let c = clip(text: "c")
        // a and b sit closer together than a midpoint can split; c lands
        // between them only by renumbering the board.
        a.file(into: board, order: 0)
        b.file(into: board, order: PinboardOrder.minimumGap / 2)
        c.file(into: board, order: 1)
        c.move(within: board, to: 1)
        XCTAssertEqual(board.orderedClips.map(\.uuid), [a.uuid, c.uuid, b.uuid])
        XCTAssertEqual(
            Set(board.orderedClips.compactMap(\.pinboardOrder)).count,
            board.clips.count,
            "no two members may share an order"
        )
    }

    /// A clip filed before orders existed (order nil, mid-board) still
    /// answers a move: the board renumbers first so the move has ordinals
    /// to work with.
    func testMoveRenumbersWhenAMemberLacksAnOrder() throws {
        let board = try XCTUnwrap(Pinboard.create(named: "A", in: context))
        let a = clip(text: "a")
        let b = clip(text: "b")
        a.file(into: board, order: 0)
        b.file(into: board, order: 1)
        a.pinboardOrder = nil
        b.move(within: board, to: 0)
        XCTAssertEqual(board.orderedClips.map(\.uuid), [b.uuid, a.uuid])
        XCTAssertEqual(
            Set(board.orderedClips.compactMap(\.pinboardOrder)).count,
            board.clips.count,
            "every member has an order after the move"
        )
    }

    // MARK: PinboardOrder primitives

    func testBetweenReturnsTheMidpointAndBoundarySteps() {
        XCTAssertEqual(PinboardOrder.between(nil, nil), 0)
        XCTAssertEqual(PinboardOrder.between(5, nil), 6, "appending steps past the tail")
        XCTAssertEqual(PinboardOrder.between(nil, 5), 4, "inserting at the head steps below it")
        XCTAssertEqual(PinboardOrder.between(1, 3), 2)
        XCTAssertEqual(PinboardOrder.between(0, 1), 0.5)
        XCTAssertNil(
            PinboardOrder.between(1, 1 + PinboardOrder.minimumGap / 2),
            "a gap too tight to halve is no room, not a collision"
        )
        XCTAssertNil(PinboardOrder.between(3, 3), "tied neighbours offer no midpoint")
    }

    // MARK: Colour

    func testColourNamesRoundTripAndUnknownsFallBack() {
        for color in PinboardColor.allCases {
            XCTAssertEqual(PinboardColor(named: color.rawValue), color)
        }
        XCTAssertNil(PinboardColor(named: "mauve"), "an imported name nothing knows is tolerated")
        XCTAssertNil(PinboardColor(named: nil))
        let board = Pinboard(name: "X", colorName: "mauve", order: 0)
        XCTAssertEqual(
            board.color, PinboardColor.grey.color,
            "a stored name no version wrote still renders, as grey"
        )
    }
}
