import Foundation
import SwiftData
import XCTest

@testable import MemoryClip

/// Searching the panel the way people actually type at it: in words, not in
/// substrings.
///
/// Same rule as `ClipQueryTests` — every case here runs a real fetch against a
/// real store, because the half of this that lives in SQL only fails at fetch
/// time. A matcher that agrees with the table while the predicate drops the
/// row is a search that finds nothing, and only a fetch can tell the two
/// apart.
@MainActor
final class ClipSearchTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema([ClipItem.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
        populate()
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    // MARK: Fixtures

    /// A store of the clips this feature exists for: a build failure, a
    /// screenshot the local model summarised and tagged, a screenshot that
    /// arrived in Arabic and was translated, and enough neighbours to make a
    /// wrong match visible.
    private func populate() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        insert(
            "deploy",
            kind: .text,
            text: "Error: deployment to production failed after 3 retries — rollback initiated",
            app: "Terminal",
            createdAt: base
        )
        insert("hello", kind: .text, text: "Hello World", app: "Safari", createdAt: base.addingTimeInterval(1))
        insert(
            "reunion",
            kind: .text,
            text: "Réunion demain à 9h avec l'équipe",
            app: "Notes",
            createdAt: base.addingTimeInterval(2)
        )
        insert(
            "invoice",
            kind: .file,
            files: ["file:///Users/me/Desktop/Screenshot%202026-02-01%20at%2009.30.00.png"],
            app: "Screenshots",
            createdAt: base.addingTimeInterval(3),
            ocrText: "TOTAL 240.00 EUR",
            isScreenshot: true,
            refinedTitle: "Hosting invoice",
            refinedSummary: "An invoice covering the February renewal, charged in euros.",
            refinedTags: ["billing", "infrastructure"]
        )
        insert(
            "arabic",
            kind: .file,
            files: ["file:///Users/me/Desktop/Screenshot%202026-03-04%20at%2011.02.00.png"],
            app: "Screenshots",
            createdAt: base.addingTimeInterval(4),
            ocrText: "تقرير المبيعات",
            isScreenshot: true,
            translatedText: "Sales report for the third quarter"
        )
        insert(
            "report",
            kind: .file,
            files: [URL(fileURLWithPath: "/Users/me/Documents/Q3 Report.pdf").absoluteString],
            app: "Finder",
            createdAt: base.addingTimeInterval(5)
        )
        insert(
            "japanese",
            kind: .file,
            files: ["file:///Users/me/Desktop/Screenshot%202026-03-05%20at%2009.14.00.png"],
            app: "Screenshots",
            createdAt: base.addingTimeInterval(8),
            ocrText: "会議の議事録",
            isScreenshot: true,
            clipTranslationText: "Minutes of the planning meeting"
        )
        insert("color", kind: .color, colorHex: "#FF00AA", app: "Figma", createdAt: base.addingTimeInterval(6))
        insert("noise", kind: .text, text: "unrelated chatter", app: "Mail", createdAt: base.addingTimeInterval(7))
    }

    @discardableResult
    private func insert(
        _ label: String,
        kind: ClipKind,
        text: String? = nil,
        colorHex: String? = nil,
        files: [String] = [],
        app: String? = nil,
        createdAt: Date = .now,
        ocrText: String? = nil,
        isScreenshot: Bool = false,
        refinedTitle: String? = nil,
        refinedSummary: String? = nil,
        refinedTags: [String] = [],
        translatedText: String? = nil,
        clipTranslationText: String? = nil
    ) -> ClipItem {
        let item = ClipItem(
            kind: kind,
            text: text,
            fileURLStrings: files,
            colorHex: colorHex,
            contentHash: label,
            sourceAppName: app,
            createdAt: createdAt,
            ocrText: ocrText,
            isScreenshot: isScreenshot,
            refinedTitle: refinedTitle,
            refinedSummary: refinedSummary,
            refinedTags: refinedTags,
            translatedText: translatedText,
            clipTranslationText: clipTranslationText
        )
        context.insert(item)
        return item
    }

    /// The whole panel pipeline: fetch with the filter's descriptor, then
    /// apply the Swift-side remainder, exactly as `PanelContentView` does.
    private func found(_ search: String, limit: Int = ClipFilter.pageSize) throws -> [String] {
        let filter = ClipFilter(search: search)
        return filter.refine(try context.fetch(filter.fetchDescriptor(limit: limit))).map(\.contentHash).sorted()
    }

    // MARK: The table

    func testSearchFindsTheClipsPeopleAreDescribing() throws {
        let cases: [(query: String, expected: [String])] = [
            // The sentence this whole thing exists for: none of it appears in
            // the clip verbatim, and every word of it does.
            ("that error about the deploy failing", ["deploy"]),
            ("deployment failed", ["deploy"]),
            ("rollback", ["deploy"]),
            // A word spread across two fields: the text and the app it came
            // from. "errors" and "Error:" are the same word.
            ("terminal errors", ["deploy"]),
            ("hello", ["hello"]),
            ("réunion demain", ["reunion"]),
            // Typed without the accents, which is how most people type them.
            ("reunion", ["reunion"]),
            // Only the model's summary says "renewal"…
            ("renewal", ["invoice"]),
            // …only its tags say "billing"…
            ("billing", ["invoice"]),
            // …and only the note translation says "quarter"…
            ("quarter", ["arabic"]),
            // …and only the preview's own translation says "minutes", which
            // is the one a clip gets by being looked at rather than refined.
            ("minutes", ["japanese"]),
            ("planning meeting", ["japanese"]),
            // "report" alone would find the PDF too; "sales" is what settles
            // which of the two was meant.
            ("sales report", ["arabic"]),
            ("q3 report", ["report"]),
            // A plural finds the singular: the source app is "Screenshots".
            ("screenshots", ["arabic", "invoice", "japanese"]),
            ("ff00", ["color"]),
            ("#FF00AA", ["color"]),
            // Both words exist in the store, no clip holds both.
            ("hello invoice", []),
            ("gibberishtermxyz", []),
            // The encoded space is one term, not a "20" that would find every
            // screenshot taken in 2026.
            ("%20", [])
        ]
        for (query, expected) in cases {
            XCTAssertEqual(try found(query), expected, "search: \(query)")
        }
    }

    // MARK: The query itself

    func testQuerySplitsDropsStopWordsAndStems() {
        XCTAssertEqual(ClipQuery("that error about the deploy failing").terms, ["error", "deploy", "fail"])
        XCTAssertEqual(ClipQuery("Hello").terms, ["Hello"], "a word with no lemma stands as typed")
        XCTAssertEqual(ClipQuery("").terms, [])
        XCTAssertEqual(ClipQuery("   ").terms, [])
    }

    /// An irregular form has a lemma that is a different word, and searching
    /// for that instead would lose the clips holding what was typed.
    func testAnIrregularFormIsLeftAsTyped() {
        XCTAssertEqual(ClipQuery("ran").terms, ["ran"])
        XCTAssertEqual(ClipQuery("mice").terms, ["mice"])
    }

    func testAQueryOfNothingButStopWordsSearchesForItself() {
        XCTAssertEqual(ClipQuery("the").terms, ["the"])
        XCTAssertEqual(ClipQuery("of the").terms, ["of the"])
    }

    /// What the predicate is given. The longest term, so the most selective —
    /// and one every matching clip carries, which is what makes the fetch a
    /// superset of the answer.
    func testTheNarrowingTermIsTheLongestOne() {
        XCTAssertEqual(ClipQuery("that error about the deploy failing").narrowing, "deploy")
        XCTAssertEqual(ClipQuery("hello").narrowing, "hello")
        XCTAssertEqual(ClipQuery("").narrowing, "")
    }

    func testTheParsedQueryFollowsTheSearchText() {
        var filter = ClipFilter()
        XCTAssertTrue(filter.query.terms.isEmpty)
        filter.search = "deploy failing"
        XCTAssertEqual(filter.query.terms, ["deploy", "fail"])
        filter.search = ""
        XCTAssertTrue(filter.query.terms.isEmpty)
        XCTAssertTrue(filter.isIdentity)
        XCTAssertEqual(filter, ClipFilter(), "a filter is still worth comparing")
        XCTAssertNotEqual(ClipFilter(search: "a"), ClipFilter(search: "b"))
    }

    // MARK: The two halves have to agree

    /// The pagination promise, for a sentence: the predicate narrows on one
    /// term across the whole store, so a match older than a page is still
    /// fetched and still found.
    func testASentenceFindsAMatchOlderThanAPage() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<300 {
            insert("filler-\(i)", kind: .text, text: "filler \(i)", app: "Notes", createdAt: base.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(try found("that error about the deploy failing", limit: 10), ["deploy"])
    }

    /// Every combination still has to survive a fetch: a predicate that
    /// compiles can throw "unimplemented SQL generation" at fetch time, and a
    /// query is now a string the app derived rather than the one typed.
    func testTermDerivedPredicatesFetchWithoutCrashing() throws {
        let queries = [
            "", "   ", "the", "that error about the deploy failing", "réunion demain",
            "#FF00AA", "%20", "https://hello.example/a?b=c", "🙂", "'; drop table zclipitem; --"
        ]
        for type in TypeFilter.allCases {
            for source in [nil, "Terminal", "Screenshots"] {
                for search in queries {
                    let filter = ClipFilter(search: search, type: type, source: source)
                    XCTAssertNoThrow(
                        try context.fetch(filter.fetchDescriptor()),
                        "type=\(type) source=\(source ?? "-") search=\(search)"
                    )
                }
            }
        }
    }

    /// The type chips and the source filter still bound a sentence search.
    func testTheOtherFiltersStillApplyToASentence() throws {
        let sentence = "that error about the deploy failing"
        XCTAssertEqual(
            ClipFilter(search: sentence, type: .text)
                .refine(try context.fetch(ClipFilter(search: sentence, type: .text).fetchDescriptor()))
                .map(\.contentHash),
            ["deploy"]
        )
        for (type, source) in [(TypeFilter.image, nil), (TypeFilter.all, "Safari")] as [(TypeFilter, String?)] {
            let filter = ClipFilter(search: sentence, type: type, source: source)
            XCTAssertTrue(
                filter.refine(try context.fetch(filter.fetchDescriptor())).isEmpty,
                "type=\(type) source=\(source ?? "-")"
            )
        }
    }
}
