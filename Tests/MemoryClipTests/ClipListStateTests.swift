import XCTest

@testable import MemoryClip

/// A plain stand-in for `ClipItem` — the filtering/selection logic was split
/// out of `PanelView` precisely so it can be exercised without SwiftData.
private struct FakeClip: ClipDisplayable {
    var uuid = UUID()
    var kind: ClipKind = .text
    var text: String?
    var ocrText: String?
    var colorHex: String?
    var fileURLStrings: [String] = []
    var sourceAppName: String?
}

final class ClipFilterTests: XCTestCase {
    // MARK: Type filter

    func testTextFilterMatchesRichTextButNotLinks() {
        let filter = ClipFilter(search: "", type: .text, source: nil)
        XCTAssertTrue(filter.matchesType(FakeClip(kind: .text)))
        XCTAssertTrue(filter.matchesType(FakeClip(kind: .richText)), "rich text is text")
        XCTAssertFalse(filter.matchesType(FakeClip(kind: .link)), "links have their own chip")
        XCTAssertFalse(filter.matchesType(FakeClip(kind: .image)))
        XCTAssertFalse(filter.matchesType(FakeClip(kind: .file)))
        XCTAssertFalse(filter.matchesType(FakeClip(kind: .color)))
    }

    func testLinkFilterMatchesOnlyLinks() {
        let filter = ClipFilter(type: .link)
        XCTAssertTrue(filter.matchesType(FakeClip(kind: .link)))
        XCTAssertFalse(filter.matchesType(FakeClip(kind: .text)))
        XCTAssertFalse(filter.matchesType(FakeClip(kind: .richText)))
    }

    func testAllFilterMatchesEveryKind() {
        let filter = ClipFilter()
        for kind in ClipKind.allCases {
            XCTAssertTrue(filter.matchesType(FakeClip(kind: kind)), "\(kind) should pass .all")
        }
        XCTAssertTrue(filter.isIdentity)
    }

    // MARK: Search

    func testSearchIsCaseInsensitiveAcrossEveryField() {
        XCTAssertTrue(ClipFilter(search: "HELLO").matchesSearch(FakeClip(text: "say hello there")))
        XCTAssertTrue(ClipFilter(search: "invoice")
            .matchesSearch(FakeClip(kind: .image, ocrText: "INVOICE 2024")))
        XCTAssertTrue(ClipFilter(search: "ff00").matchesSearch(FakeClip(kind: .color, colorHex: "#FF00AA")))
        XCTAssertTrue(ClipFilter(search: "report")
            .matchesSearch(FakeClip(kind: .file, fileURLStrings: ["/tmp/Report.pdf"])))
        XCTAssertTrue(ClipFilter(search: "safari").matchesSearch(FakeClip(sourceAppName: "Safari")))
    }

    func testEmptySearchMatchesEverything() {
        XCTAssertTrue(ClipFilter(search: "").matchesSearch(FakeClip()))
        XCTAssertTrue(ClipFilter(search: "").matchesSearch(FakeClip(text: nil)))
    }

    func testNonMatchingSearchRejects() {
        XCTAssertFalse(ClipFilter(search: "zzz").matchesSearch(FakeClip(text: "hello", sourceAppName: "Notes")))
    }

    // MARK: Source

    func testSourceFilterIsExact() {
        let filter = ClipFilter(source: "Safari")
        XCTAssertTrue(filter.matchesSource(FakeClip(sourceAppName: "Safari")))
        XCTAssertFalse(filter.matchesSource(FakeClip(sourceAppName: "Safari Technology Preview")))
        XCTAssertFalse(filter.matchesSource(FakeClip(sourceAppName: nil)))
        XCTAssertTrue(ClipFilter(source: nil).matchesSource(FakeClip(sourceAppName: nil)))
    }

    // MARK: Combination

    func testApplyCombinesAllThreeFilters() {
        let clips = [
            FakeClip(kind: .text, text: "alpha note", sourceAppName: "Notes"),
            FakeClip(kind: .richText, text: "alpha styled", sourceAppName: "Notes"),
            FakeClip(kind: .link, text: "https://alpha.example", sourceAppName: "Notes"),
            FakeClip(kind: .text, text: "alpha note", sourceAppName: "Safari"),
            FakeClip(kind: .text, text: "beta note", sourceAppName: "Notes")
        ]
        let filtered = ClipFilter(search: "alpha", type: .text, source: "Notes").apply(to: clips)
        XCTAssertEqual(filtered.map(\.uuid), [clips[0].uuid, clips[1].uuid])
    }

    // MARK: Announcement summary

    func testAnnouncementSummaryDescribesEachKind() {
        XCTAssertEqual(FakeClip(kind: .text, text: "  hi\nthere ").announcementSummary, "hi there")
        XCTAssertEqual(FakeClip(kind: .color, colorHex: "#FF0000").announcementSummary, "#FF0000")
        XCTAssertEqual(
            FakeClip(kind: .file, fileURLStrings: ["/tmp/a.txt", "/tmp/b.txt"]).announcementSummary,
            "a.txt, b.txt"
        )
        XCTAssertEqual(FakeClip(kind: .image).announcementSummary, "image")
        XCTAssertEqual(FakeClip(kind: .image, ocrText: "receipt").announcementSummary, "image, receipt")
        XCTAssertEqual(FakeClip(kind: .text, text: "   ").announcementSummary, "empty clip")
    }

    func testAnnouncementSummaryIsTruncated() {
        let summary = FakeClip(kind: .text, text: String(repeating: "a", count: 200)).announcementSummary
        XCTAssertEqual(summary.count, 81, "80 characters plus an ellipsis")
        XCTAssertTrue(summary.hasSuffix("…"))
    }
}

final class ClipSelectionTests: XCTestCase {
    private let ids = (0..<5).map { _ in UUID() }

    // MARK: Index resolution

    func testNoSelectionMeansTheTopRow() {
        let selection = ClipSelection()
        XCTAssertEqual(selection.index(in: ids), 0)
        XCTAssertNil(selection.index(in: []))
    }

    func testSelectionResolvesByUUID() {
        let selection = ClipSelection(id: ids[3])
        XCTAssertEqual(selection.index(in: ids), 3)
    }

    /// The core of the drift bug: a background capture inserts at row 0 and
    /// pushes everything down. The uuid must still resolve to the same clip.
    func testSelectionSurvivesAnInsertionAtTheTop() {
        var selection = ClipSelection()
        selection.select(index: 2, in: ids)
        XCTAssertEqual(selection.index(in: ids), 2)

        let grown = [UUID(), UUID()] + ids
        XCTAssertEqual(selection.index(in: grown), 4, "same clip, two rows further down")
    }

    func testSelectionSurvivesReorderingAndShrinking() {
        var selection = ClipSelection()
        selection.select(index: 4, in: ids)
        let shrunk = [ids[4], ids[0]]
        XCTAssertEqual(selection.index(in: shrunk), 0)
    }

    /// A selection whose clip is gone resolves to nil — the caller must do
    /// nothing rather than act on row 0 (the newest clip).
    func testVanishedSelectionResolvesToNil() {
        let selection = ClipSelection(id: UUID())
        XCTAssertNil(selection.index(in: ids))
        XCTAssertEqual(selection.movementOrigin(in: ids), 0, "but movement restarts from the top")
    }

    // MARK: Movement

    func testMoveClampsAtBothEnds() {
        var selection = ClipSelection()
        selection.move(by: -1, in: ids)
        XCTAssertEqual(selection.index(in: ids), 0)

        selection.move(by: 99, in: ids)
        XCTAssertEqual(selection.index(in: ids), 4)

        selection.move(by: 1, in: ids)
        XCTAssertEqual(selection.index(in: ids), 4)

        selection.move(by: -2, in: ids)
        XCTAssertEqual(selection.index(in: ids), 2)
    }

    func testMoveInEmptyListClearsSelection() {
        var selection = ClipSelection(id: ids[1])
        selection.move(by: 1, in: [])
        XCTAssertNil(selection.index(in: []))
    }

    func testSelectClampsOutOfRangeIndices() {
        var selection = ClipSelection()
        selection.select(index: -5, in: ids)
        XCTAssertEqual(selection.index(in: ids), 0)
        selection.select(index: 500, in: ids)
        XCTAssertEqual(selection.index(in: ids), 4)
        selection.select(index: 1, in: [])
        XCTAssertNil(selection.index(in: []))
    }

    func testClearReturnsToTheTopRow() {
        var selection = ClipSelection(id: ids[3])
        selection.clear()
        XCTAssertEqual(selection.index(in: ids), 0)
    }

    // MARK: Deletion

    func testDeletingSelectsTheFollowingClip() {
        var selection = ClipSelection(id: ids[1])
        selection.selectNeighbour(of: ids[1], in: ids)
        var remaining = ids
        remaining.remove(at: 1)
        XCTAssertEqual(selection.index(in: remaining), 1, "the clip that moved up into the slot")
        XCTAssertEqual(selection.id, ids[2])
    }

    func testDeletingTheLastClipSelectsThePreviousOne() {
        var selection = ClipSelection(id: ids[4])
        selection.selectNeighbour(of: ids[4], in: ids)
        XCTAssertEqual(selection.id, ids[3])
        XCTAssertEqual(selection.index(in: Array(ids.dropLast())), 3)
    }

    func testDeletingTheOnlyClipClearsTheSelection() {
        let only = ids[0]
        var selection = ClipSelection(id: only)
        selection.selectNeighbour(of: only, in: [only])
        XCTAssertNil(selection.id)
        XCTAssertNil(selection.index(in: []))
    }

    func testNeighbourOfAnUnknownClipLeavesSelectionAlone() {
        var selection = ClipSelection(id: ids[2])
        selection.selectNeighbour(of: UUID(), in: ids)
        XCTAssertEqual(selection.id, ids[2])
    }
}
