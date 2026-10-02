import Foundation
import SwiftData
import XCTest

@testable import MemoryClip

/// A `ClipDisplayable` stand-in with every operator-readable field settable:
/// the `is:`/`after:`/`app:` checks need more than the text triple the older
/// fixtures carry.
private struct OpClip: ClipDisplayable {
    var uuid = UUID()
    var kind: ClipKind = .text
    var text: String?
    var ocrText: String?
    var colorHex: String?
    var fileURLStrings: [String] = []
    var sourceAppName: String?
    var isPinned: Bool = false
    var notePath: String?
    var calendarEventID: String?
    var createdAt: Date = .distantPast
    var refinedTitle: String?
    var refinedText: String?
    var refinedSummary: String?
    var refinedTags: [String] = []
    var translatedText: String?
    var clipTranslationText: String?
    var isScreenshot: Bool = false
}

/// The `key:value` search operators: the grammar itself, the date forms it
/// resolves against an injected clock, and the agreement between the SQL
/// predicate and the Swift-side remainder. Same rule as `ClipQueryTests`:
/// the predicate half only fails at fetch time, so the agreement cases run
/// real fetches.
@MainActor
final class ClipOperatorTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    /// A fixed clock in a calendar with real DST transitions, so `today`,
    /// `7d` and `on:` resolve to the same day no matter where the test runs.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()
    /// Tuesday 15 September 2026, 14:30 Paris time.
    private lazy var now = calendar.date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 14, minute: 30)
    )!

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
        _ label: String,
        kind: ClipKind,
        text: String? = nil,
        files: [String] = [],
        app: String? = nil,
        createdAt: Date,
        isPinned: Bool = false,
        isScreenshot: Bool = false,
        notePath: String? = nil,
        calendarEventID: String? = nil,
        ocrText: String? = nil,
        translatedText: String? = nil
    ) -> ClipItem {
        let item = ClipItem(
            kind: kind,
            text: text,
            fileURLStrings: files,
            contentHash: label,
            sourceAppName: app,
            createdAt: createdAt,
            isPinned: isPinned,
            ocrText: ocrText,
            isScreenshot: isScreenshot,
            translatedText: translatedText,
            notePath: notePath,
            calendarEventID: calendarEventID
        )
        context.insert(item)
        return item
    }

    /// One local day at `hour` on `day`, in the test calendar.
    private func on(day: Int, hour: Int = 12, month: Int = 9, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: 0
        ))!
    }

    /// The clips the agreement cases run against: one of every state `is:`
    /// knows, an app pair sharing a prefix, and dates spread over the week
    /// before `now`.
    private func populate() -> [ClipItem] {
        [
            insert("pinned", kind: .text, text: "keep me", app: "Notes",
                   createdAt: on(day: 15, hour: 9), isPinned: true),
            insert("safari-tp", kind: .text, text: "preview build",
                   app: "Safari Technology Preview", createdAt: on(day: 15, hour: 8)),
            insert("plain", kind: .text, text: "world", app: "Safari",
                   createdAt: on(day: 15, hour: 7)),
            insert("shot", kind: .file,
                   files: ["file:///tmp/Screenshot.png"], app: "Screenshots",
                   createdAt: on(day: 14), isScreenshot: true),
            insert("noted", kind: .text, text: "alpha", app: "Safari",
                   createdAt: on(day: 12), notePath: "/vault/a.md"),
            insert("doc", kind: .file, files: ["file:///tmp/report.pdf"],
                   app: "Finder", createdAt: on(day: 11)),
            insert("event", kind: .text, text: "meeting at 3", app: "Mail",
                   createdAt: on(day: 10), calendarEventID: "evt-1"),
            insert("translated", kind: .image,
                   app: "Photos", createdAt: on(day: 9),
                   ocrText: "Bonjour", translatedText: "Hello")
        ]
    }

    /// The whole panel pipeline, exactly as `PanelContentView` runs it:
    /// SQL page first, Swift remainder after.
    private func visible(
        _ filter: ClipFilter,
        limit: Int = ClipFilter.pageSize
    ) throws -> [ClipItem] {
        filter.refine(try context.fetch(filter.fetchDescriptor(limit: limit)))
    }

    // MARK: The grammar

    /// `key:value` is an operator; everything else stays a word.
    func testScanClassifiesEachToken() {
        let text = "deploy is:pinned -app:Slack in:vault 14:30"
        let tokens = ClipQuery.scan(text)
        XCTAssertEqual(tokens.count, 5)
        XCTAssertNil(tokens[0].key)
        XCTAssertEqual(tokens[1].key, .is)
        XCTAssertEqual(tokens[1].value, "pinned")
        XCTAssertFalse(tokens[1].negated)
        XCTAssertEqual(tokens[2].key, .app)
        XCTAssertEqual(tokens[2].value, "Slack")
        XCTAssertTrue(tokens[2].negated)
        // `in:` is not a key (pinboards are a later PRD): the whole token is
        // a word and keeps searching as literal text.
        XCTAssertNil(tokens[3].key)
        XCTAssertEqual(String(text[tokens[3].range]), "in:vault")
        XCTAssertNil(tokens[4].key, "a clock time is not an operator")
    }

    func testKeysAndValuesAreCaseInsensitive() {
        var constraints = ClipConstraints()
        XCTAssertTrue(constraints.apply(.is, value: "PINNED", negated: false,
                                        now: now, calendar: calendar))
        XCTAssertEqual(constraints.states, [.pinned])
        let text = "APP:Safari"
        let token = ClipQuery.scan(text).first
        XCTAssertEqual(token?.key, .app, "the key matches case-insensitively")
        XCTAssertEqual(token.flatMap { $0.head.map { String(text[$0]) } }, "APP:",
                       "the styled head keeps the typed case")
    }

    func testQuotesKeepAValueTogether() {
        let text = "app:\"Google Chrome\" tail"
        let token = ClipQuery.scan(text).first
        XCTAssertEqual(token?.key, .app)
        XCTAssertEqual(token?.value, "Google Chrome")
        XCTAssertEqual(String(text[token!.range]), "app:\"Google Chrome\"")

        // An unclosed quote reads to the end of the field - the suggestion
        // list is what closes it.
        let open = ClipQuery.scan("app:\"Google Chr").first
        XCTAssertEqual(open?.value, "Google Chr")
    }

    func testAnEmptyValueIsAWordNotAnOperator() {
        for query in ["app:", "is:", "app: tail", "app:\"\""] {
            let tokens = ClipQuery.scan(query)
            XCTAssertTrue(tokens.allSatisfy { $0.key == nil },
                          "\(query): a `key:` with no value is searchable text")
        }
    }

    func testALeadingDashOnlyNegatesAnOperator() {
        let tokens = ClipQuery.scan("- -app:x")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertNil(tokens[0].key, "a lone dash is a word")
        XCTAssertEqual(tokens[1].key, .app)
        XCTAssertTrue(tokens[1].negated)
    }

    // MARK: What the query does with them

    func testOperatorsLeaveTheWordsAsTerms() {
        let query = ClipQuery("deploy failing is:pinned", now: now, calendar: calendar)
        XCTAssertEqual(query.terms, ["deploy", "fail"])
        XCTAssertEqual(query.constraints.states, [.pinned])
        XCTAssertEqual(query.operatorTokens.map(\.key), [.is])
    }

    func testAQueryOfOperatorsAloneHasNoTerms() {
        let query = ClipQuery("is:pinned app:Safari", now: now, calendar: calendar)
        XCTAssertTrue(query.terms.isEmpty)
        XCTAssertEqual(query.constraints.apps, ["Safari"])
    }

    /// An operator whose value the key does not know narrows nothing: the
    /// token is styled with a warning, not searched and not applied.
    func testAnUnrecognisedValueNarrowsNothing() {
        let query = ClipQuery("is:bogus", now: now, calendar: calendar)
        XCTAssertTrue(query.constraints.isEmpty)
        XCTAssertTrue(query.terms.isEmpty)
        XCTAssertEqual(query.operatorTokens.count, 1)
        XCTAssertFalse(query.operatorTokens[0].valueIsKnown)
        // `type:all` is rejected the same way: "all" filters nothing.
        XCTAssertFalse(ClipQuery("type:all", now: now, calendar: calendar)
            .operatorTokens[0].valueIsKnown)
    }

    func testTheStopWordFallbackSurvivesOperators() {
        XCTAssertEqual(ClipQuery("the", now: now, calendar: calendar).terms, ["the"])
        // With an operator beside it, a stop word drops as it always did.
        XCTAssertTrue(ClipQuery("the is:pinned", now: now, calendar: calendar).terms.isEmpty)
    }

    // MARK: The date forms

    private func operand(_ value: String) -> ClipConstraints.DateOperand? {
        ClipConstraints.dateOperand(value, now: now, calendar: calendar)
    }

    private func dayInterval(_ d: Int, _ m: Int = 9, _ y: Int = 2026) -> DateInterval {
        calendar.dateInterval(of: .day, for: on(day: d, month: m, year: y))!
    }

    func testNamedDaysResolveToLocalDays() {
        guard case .day(let today)? = operand("today") else {
            return XCTFail("today is a day")
        }
        XCTAssertTrue(today.contains(now))
        XCTAssertEqual(today, dayInterval(15))

        guard case .day(let yesterday)? = operand("yesterday") else {
            return XCTFail("yesterday is a day")
        }
        XCTAssertEqual(yesterday, dayInterval(14))
    }

    func testISODatesResolveToWholeLocalDays() {
        guard case .day(let day)? = operand("2026-09-01") else {
            return XCTFail("2026-09-01 is a day")
        }
        XCTAssertEqual(day, dayInterval(1))
    }

    /// Calendar arithmetic, not 86_400-second arithmetic: the day the clocks
    /// went back in Paris (26 October 2025) ran 25 hours, and `on:` has to
    /// cover all of it.
    func testADayThroughADSTTransitionIsWhole() {
        let fallBack = calendar.date(
            from: DateComponents(year: 2025, month: 10, day: 26, hour: 12)
        )!
        guard case .day(let day)? = ClipConstraints.dateOperand(
            "today", now: fallBack, calendar: calendar
        ) else {
            return XCTFail("today is a day")
        }
        XCTAssertEqual(day.duration, 25 * 3600, "a 25-hour day is still one day")
    }

    func testRelativeDatesAreInstantsOffNow() {
        guard case .ago(let instant, let count, let unit)? = operand("7d") else {
            return XCTFail("7d is a reach back")
        }
        XCTAssertEqual(instant, calendar.date(byAdding: .day, value: -7, to: now))
        XCTAssertEqual(count, 7)
        XCTAssertEqual(unit, .day)
        XCTAssertNotNil(operand("2w"))
        XCTAssertNotNil(operand("3m"))
    }

    func testBadDateValuesAreRejected() {
        for value in ["soon", "0d", "-3d", "2026-02-31", "2026-9-1", "12x", "32d "] {
            XCTAssertNil(operand(value), "\(value) must not resolve")
        }
    }

    func testDateOperatorsFoldIntoBounds() {
        var query = ClipQuery("after:2026-09-14", now: now, calendar: calendar)
        XCTAssertEqual(query.constraints.after, dayInterval(14).start)
        XCTAssertNil(query.constraints.before)

        query = ClipQuery("before:2026-09-14", now: now, calendar: calendar)
        XCTAssertEqual(query.constraints.before, dayInterval(14).start,
                       "before: a named day ends the day before it")
        XCTAssertNil(query.constraints.after)

        query = ClipQuery("on:2026-09-14", now: now, calendar: calendar)
        XCTAssertEqual(query.constraints.after, dayInterval(14).start)
        XCTAssertEqual(query.constraints.before, dayInterval(14).end)
    }

    func testNegatedDateOperatorsFlipTheBound() {
        var query = ClipQuery("-after:2026-09-14", now: now, calendar: calendar)
        XCTAssertEqual(query.constraints.before, dayInterval(14).start)
        query = ClipQuery("-before:2026-09-14", now: now, calendar: calendar)
        XCTAssertEqual(query.constraints.after, dayInterval(14).start)
        query = ClipQuery("-on:2026-09-14", now: now, calendar: calendar)
        XCTAssertEqual(query.constraints.excludedDays, [dayInterval(14)])
        XCTAssertNil(query.constraints.after, "-on: excludes rather than bounds")
    }

    func testOnARelativeDayLandsOnTheDayItFellIn() {
        let query = ClipQuery("on:7d", now: now, calendar: calendar)
        let week = calendar.date(byAdding: .day, value: -7, to: now)!
        XCTAssertEqual(query.constraints.after,
                       calendar.dateInterval(of: .day, for: week)?.start)
    }

    // MARK: The Swift-side rule

    func testAppMatchingIsAnAnchoredPrefix() {
        let query = ClipQuery("app:saf", now: now, calendar: calendar)
        XCTAssertTrue(query.constraints.matches(
            OpClip(sourceAppName: "Safari")
        ))
        XCTAssertTrue(query.constraints.matches(
            OpClip(sourceAppName: "Safari Technology Preview")
        ),
                      "the prefix rule is why `app:saf` reaches Safari")
        XCTAssertFalse(query.constraints.matches(
            OpClip(sourceAppName: "Pro Safari")
        ),
                       "it is a prefix, not a substring")
        XCTAssertFalse(query.constraints.matches(OpClip(sourceAppName: nil)))
    }

    func testTheStatesReadTheirFields() {
        let query = ClipQuery("is:noted is:event", now: now, calendar: calendar)
        XCTAssertFalse(query.constraints.matches(OpClip(notePath: "/vault/a")))
        XCTAssertTrue(query.constraints.matches(
            OpClip(notePath: "/vault/a", calendarEventID: "e")
        ))
        XCTAssertTrue(ClipQuery("is:translated", now: now, calendar: calendar)
            .constraints.matches(OpClip(translatedText: "hello")))
        XCTAssertTrue(ClipQuery("is:translated", now: now, calendar: calendar)
            .constraints.matches(OpClip(clipTranslationText: "bonjour")))
    }

    /// `type:file` keeps screenshots out (they are Images); `-type:file`
    /// keeps them in. The two directions are why `isScreenshot` is part of
    /// the match and not just the kind.
    func testTypeKnowsScreenshotsArePictures() {
        let shot = OpClip(kind: .file, isScreenshot: true)
        let doc = OpClip(kind: .file)
        XCTAssertTrue(ClipQuery("type:image", now: now, calendar: calendar)
            .constraints.matches(shot))
        XCTAssertFalse(ClipQuery("type:image", now: now, calendar: calendar)
            .constraints.matches(doc))
        XCTAssertFalse(ClipQuery("type:file", now: now, calendar: calendar)
            .constraints.matches(shot))
        XCTAssertTrue(ClipQuery("type:file", now: now, calendar: calendar)
            .constraints.matches(doc))
        // And the exclusion goes the other way: `-type:file` keeps the shot.
        XCTAssertTrue(ClipQuery("-type:file", now: now, calendar: calendar)
            .constraints.matches(shot))
        XCTAssertFalse(ClipQuery("-type:file", now: now, calendar: calendar)
            .constraints.matches(doc))
    }

    // MARK: The two halves have to agree

    /// The load-bearing invariant of the whole feature: every clause the
    /// predicate carries is exact or a widening, so `refine(fetch)` equals
    /// `apply(store)` - never narrower, or a page could hide a match.
    func testFetchAndRefineAgreeWithTheSwiftRule() throws {
        let all = populate()
        let queries = [
            "app:Saf", "-app:Saf", "app:Safari", "app:Screenshots",
            "is:pinned", "-is:pinned", "is:screenshot", "-is:screenshot",
            "is:noted", "is:event", "is:translated",
            "type:text", "type:image", "type:file", "-type:file", "-type:image",
            "type:text type:link", "-type:text -type:image -type:link -type:file -type:color",
            "after:2026-09-14", "before:2026-09-14", "on:2026-09-15",
            "on:yesterday", "on:7d", "-on:2026-09-15", "after:7d",
            "is:bogus", "in:vault",
            "world app:Safari", "alpha is:noted", "keep is:pinned -app:Safari"
        ]
        for text in queries {
            let filter = ClipFilter(search: text, now: now, calendar: calendar)
            let fetched = try context.fetch(filter.fetchDescriptor())
            let expected = Set(filter.apply(to: all).map(\.uuid))
            XCTAssertTrue(
                expected.isSubset(of: Set(fetched.map(\.uuid))),
                "\(text): the predicate dropped a row the rule keeps"
            )
            XCTAssertEqual(
                Set(filter.refine(fetched).map(\.uuid)), expected,
                "\(text): fetch+refine must equal the Swift rule"
            )
        }
    }

    /// `type:` and a chip name the same column: `type:text` under the Links
    /// chip is a contradiction the fetch reports as empty rather than
    /// widening into everything.
    func testAContradictoryTypeAndChipMatchNothing() throws {
        populate()
        let filter = ClipFilter(search: "type:text", type: .link,
                                now: now, calendar: calendar)
        XCTAssertEqual(try visible(filter).count, 0)
    }

    /// A clause SQL cannot carry - `-app:` here - means the fetch is wider
    /// than the answer, and a small page can come back all filler. The
    /// panel's answer is to re-fetch wider, so a match that missed the page
    /// still turns up.
    func testAWidenedPageFindsWhatRefineRemoved() throws {
        for i in 0..<30 {
            insert("filler-\(i)", kind: .text, text: "filler", app: "Safari",
                   createdAt: on(day: 15, hour: 0).addingTimeInterval(Double(i)))
        }
        insert("needle", kind: .text, text: "needle", app: "Notes",
               createdAt: on(day: 8))
        let filter = ClipFilter(search: "-app:Safari", now: now, calendar: calendar)
        XCTAssertEqual(try visible(filter, limit: 10).count, 0,
                       "the newest page is all filler a negation discards")
        XCTAssertEqual(try visible(filter).map(\.contentHash), ["needle"])
    }

    // MARK: The filter's app setting

    func testTheSourcePropertyIsTheAppOperator() {
        var filter = ClipFilter()
        filter.source = "Safari"
        XCTAssertEqual(filter.search, "app:Safari")
        XCTAssertEqual(filter.source, "Safari")

        // Quoted when the name needs it, and written back out of the words.
        filter.source = "Google Chrome"
        XCTAssertEqual(filter.search, "app:\"Google Chrome\"")

        // A typed `app:` reports through the same property - one code path.
        XCTAssertEqual(ClipFilter(search: "app:saf").source, "saf")

        // Clearing removes every `app:` token, either sign.
        filter.search = "word app:Safari -app:Notes"
        filter.source = nil
        XCTAssertEqual(filter.search, "word")

        // Choosing one app replaces a previous pick rather than stacking.
        filter.source = "Safari"
        filter.source = "Notes"
        XCTAssertEqual(filter.search, "word app:Notes")
    }

    /// "Clear filters" keeps the words and drops every operator token,
    /// including the unknown-key words the grammar never claimed.
    func testClearingOperatorsKeepsTheWords() {
        XCTAssertEqual(
            ClipQuery.clearingOperators(from: "invoice is:pinned -app:Safari is:bogus in:vault"),
            "invoice in:vault",
            "`in:` was never an operator, so it stays as the word it is"
        )
        XCTAssertEqual(ClipQuery.clearingOperators(from: "is:pinned"), "")
    }

    // MARK: The constraint summary

    func testTheEmptyStateNamesTheConstraints() {
        let summary = ClipFilter(
            search: "invoice app:Slack is:pinned", now: now, calendar: calendar
        ).constraintSummary
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("invoice") ?? false)
        XCTAssertTrue(summary?.contains("Slack") ?? false)
        XCTAssertTrue(summary?.contains("pinned") ?? false)
        XCTAssertNil(ClipFilter().constraintSummary)
        XCTAssertNotNil(ClipFilter(type: .file).constraintSummary,
                        "a chip alone is a constraint worth naming")
    }

    // MARK: Suggestions

    private func context(_ text: String) -> ClipQuery.SuggestionContext? {
        ClipQuery.suggestionContext(in: text)
    }

    func testTheSuggestionContextReadsTheTrailingToken() {
        XCTAssertNil(context(""))
        XCTAssertNil(context("word"))
        XCTAssertNil(context("is:pinned "), "a closing space ends the token")
        XCTAssertEqual(context("is:")?.key, .is)
        XCTAssertEqual(context("is:")?.prefix, "")
        XCTAssertEqual(context("is:pi")?.prefix, "pi")
        XCTAssertEqual(context("-is:pi")?.negated, true)
        XCTAssertEqual(context("word app:Saf")?.key, .app)
        XCTAssertEqual(context("app:\"Google Ch")?.prefix, "Google Ch")
        XCTAssertNil(context("in:"), "an unknown key suggests nothing")
        XCTAssertNil(context("is:pi rest"), "only the token at the end completes")
    }

    func testSuggestionsOfferTheKeysVocabulary() {
        let all = ClipQuery.suggestions(
            for: context("is:")!, apps: [], now: now, calendar: calendar
        )
        XCTAssertEqual(all.map(\.value), ClipStateValue.allCases.map(\.rawValue))

        let filtered = ClipQuery.suggestions(
            for: context("is:s")!, apps: [], now: now, calendar: calendar
        )
        XCTAssertEqual(filtered.map(\.value), ["screenshot"])

        let kinds = ClipQuery.suggestions(
            for: context("type:l")!, apps: [], now: now, calendar: calendar
        )
        XCTAssertEqual(kinds.map(\.value), ["link"])
    }

    func testAppSuggestionsComeFromTheStoreInOrderAndCapped() {
        let apps = (0..<12).map { (name: "App\($0)", count: $0) }
        let rows = ClipQuery.suggestions(
            for: context("app:")!, apps: apps, now: now, calendar: calendar
        )
        XCTAssertEqual(rows.count, 8, "the list caps at eight")
        XCTAssertEqual(rows.first?.token, "app:App0",
                       "the caller's order - most-used first - is kept")

        let spaced = ClipQuery.suggestions(
            for: context("app:Go")!,
            apps: [(name: "Google Chrome", count: 4), (name: "Mail", count: 9)],
            now: now, calendar: calendar
        )
        XCTAssertEqual(spaced.map(\.token), ["app:\"Google Chrome\""],
                       "a name with a space completes quoted")
    }

    func testAcceptingACompletesTheTokenAndClosesIt() {
        var text = "word is:pi"
        var accepted = ClipQuery.accepting(context(text)!, "pinned", in: text)
        XCTAssertEqual(accepted, "word is:pinned ",
                       "the trailing space ends the token")
        XCTAssertNil(context(accepted), "so the list closes itself")

        text = "-is:pi"
        accepted = ClipQuery.accepting(context(text)!, "pinned", in: text)
        XCTAssertEqual(accepted, "-is:pinned ", "accepting keeps the sign")
    }

    /// A date suggestion says what it resolves to, so "7d" is not a leap.
    func testDateSuggestionsNameTheDay() {
        let rows = ClipQuery.suggestions(
            for: context("on:")!, apps: [], now: now, calendar: calendar
        )
        XCTAssertEqual(rows.map(\.value), ["today", "yesterday", "7d"])
        XCTAssertEqual(rows.first?.detail,
                       ClipConstraints.dayLabel(dayInterval(15), now: now, calendar: calendar))
    }
}
