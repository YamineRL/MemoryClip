import Foundation
import SwiftData
import XCTest

@testable import MemoryClip

/// The panel's filtering now happens inside SQLite, so it can only be trusted
/// if it is exercised against a real store: a predicate that compiles happily
/// can still blow up at fetch time with "unimplemented SQL generation for
/// predicate", an uncaught NSInvalidArgumentException. Every test here runs a
/// real fetch.
@MainActor
final class ClipQueryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema([ClipItem.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    // MARK: Fixtures

    @discardableResult
    private func insert(
        kind: ClipKind,
        text: String? = nil,
        ocrText: String? = nil,
        colorHex: String? = nil,
        files: [String] = [],
        app: String? = nil,
        createdAt: Date = .now
    ) -> ClipItem {
        let item = ClipItem(
            kind: kind,
            text: text,
            fileURLStrings: files,
            colorHex: colorHex,
            contentHash: UUID().uuidString,
            sourceAppName: app,
            createdAt: createdAt,
            ocrText: ocrText
        )
        context.insert(item)
        return item
    }

    /// The whole panel pipeline: fetch with the filter's descriptor, then
    /// apply the Swift-side remainder, exactly as `PanelContentView` does.
    private func visible(_ filter: ClipFilter, limit: Int = ClipFilter.pageSize) throws -> [ClipItem] {
        filter.refine(try context.fetch(filter.fetchDescriptor(limit: limit)))
    }

    private func texts(_ items: [ClipItem]) -> [String] {
        items.map { $0.text ?? $0.colorHex ?? $0.ocrText ?? $0.fileURLStrings.joined() }
    }

    private func populate() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        insert(kind: .text, text: "Hello World", app: "Safari", createdAt: base)
        insert(kind: .richText, text: "styled hello", app: "Notes", createdAt: base.addingTimeInterval(1))
        insert(kind: .link, text: "https://hello.example", app: "Safari", createdAt: base.addingTimeInterval(2))
        insert(kind: .image, ocrText: "INVOICE 2024", app: "Preview", createdAt: base.addingTimeInterval(3))
        insert(kind: .color, colorHex: "#FF00AA", app: "Figma", createdAt: base.addingTimeInterval(4))
        insert(kind: .file, files: ["/tmp/Report.pdf"], app: "Finder", createdAt: base.addingTimeInterval(5))
        insert(kind: .text, text: "unrelated", app: "Mail", createdAt: base.addingTimeInterval(6))
    }

    // MARK: The landmine

    /// A regression guard for the crash the predicate has to avoid: fetching
    /// must not throw an Objective-C exception about SQL generation.
    func testEveryFilterCombinationFetchesWithoutCrashing() throws {
        populate()
        for type in TypeFilter.allCases {
            for source in [nil, "Safari", "Finder"] {
                for search in ["", "hello", "HELLO", "réport", "#ff00aa", "zzz"] {
                    let filter = ClipFilter(search: search, type: type, source: source)
                    XCTAssertNoThrow(
                        try context.fetch(filter.fetchDescriptor()),
                        "type=\(type) source=\(source ?? "-") search=\(search)"
                    )
                }
            }
        }
    }

    // MARK: Search parity with the old Swift-side filter

    func testSearchMatchesText() throws {
        populate()
        XCTAssertEqual(
            Set(texts(try visible(ClipFilter(search: "hello")))),
            ["Hello World", "styled hello", "https://hello.example"]
        )
    }

    func testSearchIsCaseInsensitive() throws {
        populate()
        XCTAssertEqual(try visible(ClipFilter(search: "HELLO")).count, 3)
        XCTAssertEqual(try visible(ClipFilter(search: "hello")).count, 3)
    }

    func testSearchMatchesOCRText() throws {
        populate()
        let found = try visible(ClipFilter(search: "invoice"))
        XCTAssertEqual(found.map(\.kind), [.image])
    }

    func testSearchMatchesColorHex() throws {
        populate()
        XCTAssertEqual(try visible(ClipFilter(search: "ff00")).map(\.kind), [.color])
    }

    /// The one part SQL cannot do: `fileURLStrings` is stored as an opaque
    /// blob, so file clips are admitted by the predicate and sifted in Swift.
    func testSearchMatchesFilePaths() throws {
        populate()
        insert(kind: .file, files: ["/tmp/other.txt"], app: "Finder")
        XCTAssertEqual(
            try visible(ClipFilter(search: "report")).map(\.fileURLStrings),
            [["/tmp/Report.pdf"]]
        )
        XCTAssertTrue(try visible(ClipFilter(search: "nothinglikethis")).isEmpty,
                      "file clips must not leak through as false matches")
    }

    func testSearchMatchesSourceApp() throws {
        populate()
        let found = try visible(ClipFilter(search: "safari"))
        XCTAssertEqual(Set(found.compactMap(\.sourceAppName)), ["Safari"])
        XCTAssertEqual(found.count, 2)
    }

    func testNonMatchingSearchReturnsNothing() throws {
        populate()
        XCTAssertTrue(try visible(ClipFilter(search: "qwertyuiop")).isEmpty)
    }

    // MARK: Type filter

    func testTypeFilterFoldsRichTextIntoTextButNotLinks() throws {
        populate()
        let found = try visible(ClipFilter(type: .text))
        XCTAssertEqual(Set(found.map(\.kind)), [.text, .richText])
        XCTAssertEqual(found.count, 3)
    }

    func testEachTypeFilterSelectsItsOwnKind() throws {
        populate()
        XCTAssertEqual(Set(try visible(ClipFilter(type: .link)).map(\.kind)), [.link])
        XCTAssertEqual(Set(try visible(ClipFilter(type: .image)).map(\.kind)), [.image])
        XCTAssertEqual(Set(try visible(ClipFilter(type: .color)).map(\.kind)), [.color])
        XCTAssertEqual(Set(try visible(ClipFilter(type: .file)).map(\.kind)), [.file])
        XCTAssertEqual(try visible(ClipFilter(type: .all)).count, 7)
    }

    /// The type filter must also bound the file-clip escape hatch, or a
    /// search under "Images" would list files.
    func testTypeFilterStillAppliesWhileSearching() throws {
        populate()
        XCTAssertTrue(try visible(ClipFilter(search: "report", type: .image)).isEmpty)
        XCTAssertEqual(try visible(ClipFilter(search: "report", type: .file)).count, 1)
    }

    // MARK: Source filter

    func testSourceFilterIsExactMatch() throws {
        populate()
        insert(kind: .text, text: "preview build", app: "Safari Technology Preview")
        XCTAssertEqual(Set(try visible(ClipFilter(source: "Safari")).compactMap(\.sourceAppName)), ["Safari"])
        XCTAssertEqual(try visible(ClipFilter(source: "Safari")).count, 2)
    }

    func testSourceFilterCombinesWithSearchAndType() throws {
        populate()
        let found = try visible(ClipFilter(search: "hello", type: .text, source: "Notes"))
        XCTAssertEqual(texts(found), ["styled hello"])
    }

    func testNilSourceMeansEveryApp() throws {
        populate()
        insert(kind: .text, text: "no app", app: nil)
        XCTAssertEqual(try visible(ClipFilter()).count, 8)
    }

    // MARK: Ordering and paging

    func testResultsAreNewestFirst() throws {
        populate()
        let found = try visible(ClipFilter())
        XCTAssertEqual(texts(found).first, "unrelated")
        XCTAssertEqual(
            found.map(\.createdAt),
            found.map(\.createdAt).sorted(by: >),
            "the panel lists clips newest first"
        )
    }

    func testFetchLimitCapsThePage() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<50 {
            insert(kind: .text, text: "clip \(i)", app: "Notes", createdAt: base.addingTimeInterval(Double(i)))
        }
        let page = try visible(ClipFilter(), limit: 10)
        XCTAssertEqual(page.count, 10)
        XCTAssertEqual(texts(page).first, "clip 49", "a page holds the newest clips")
    }

    /// The pagination promise: a match older than one page is still found,
    /// because the search happens in SQL over the whole store. Only how many
    /// rows are rendered is bounded — never what is findable.
    func testAMatchOlderThanAPageIsStillFound() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        insert(kind: .text, text: "needle in a haystack", app: "Notes", createdAt: base)
        for i in 0..<500 {
            insert(kind: .text, text: "filler \(i)", app: "Notes", createdAt: base.addingTimeInterval(Double(i + 1)))
        }
        let found = try visible(ClipFilter(search: "needle"), limit: 10)
        XCTAssertEqual(texts(found), ["needle in a haystack"])
    }

    /// Growing the page reaches deeper into the store, which is what the
    /// list's end-of-page trigger does when the user scrolls.
    func testGrowingTheLimitReachesOlderClips() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<40 {
            insert(kind: .text, text: "clip \(i)", app: "Notes", createdAt: base.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(try visible(ClipFilter(), limit: 10).count, 10)
        XCTAssertEqual(try visible(ClipFilter(), limit: 20).count, 20)
        XCTAssertEqual(try visible(ClipFilter(), limit: 100).count, 40, "the whole store fits")
    }

    // MARK: Swift-side remainder

    func testRefineOnlyReconsidersFileClips() {
        let filter = ClipFilter(search: "report")
        let text = ClipItem(kind: .text, text: "matched in SQL", contentHash: "a")
        let file = ClipItem(kind: .file, fileURLStrings: ["/tmp/Report.pdf"], contentHash: "b")
        let other = ClipItem(kind: .file, fileURLStrings: ["/tmp/notes.txt"], contentHash: "c")
        XCTAssertEqual(
            filter.refine([text, file, other]).map(\.uuid),
            [text.uuid, file.uuid],
            "non-file rows are trusted; file rows are re-checked"
        )
    }

    func testRefineIsAPassThroughWithoutASearch() {
        let items = [
            ClipItem(kind: .file, fileURLStrings: ["/tmp/a.txt"], contentHash: "a"),
            ClipItem(kind: .text, text: "b", contentHash: "b")
        ]
        XCTAssertEqual(ClipFilter().refine(items).count, 2)
        XCTAssertEqual(ClipFilter(type: .file).refine(items).count, 2, "the type filter is SQL's job")
    }

    func testKindRawValuesMirrorTheTypeFilter() {
        XCTAssertEqual(TypeFilter.all.kindRawValues, [], "empty means unrestricted")
        XCTAssertEqual(TypeFilter.text.kindRawValues, ["richText", "text"])
        XCTAssertEqual(TypeFilter.link.kindRawValues, ["link"])
        for type in TypeFilter.allCases {
            for kind in ClipKind.allCases where type != .all {
                XCTAssertEqual(
                    type.matches(kind),
                    type.kindRawValues.contains(kind.rawValue),
                    "\(type)/\(kind): the predicate and the Swift filter must agree"
                )
            }
        }
    }
}
