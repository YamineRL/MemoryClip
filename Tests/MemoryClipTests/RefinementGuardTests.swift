import Foundation
import XCTest

@testable import MemoryClip

/// The refinement layer with no model behind it: the check that decides
/// whether a rewrite is allowed to become the user's note, the fallback that
/// ships when Apple Intelligence is unavailable, and the input bound.
///
/// Nothing here touches `SystemLanguageModel`, so the results are the same on
/// an eligible Mac, an ineligible one, and a CI box with the feature off.
final class RefinementGuardTests: XCTestCase {

    // MARK: - Fixtures
    //
    // Realistic pairs, because the thresholds were measured against realistic
    // pairs: a toy string has neither the chrome vocabulary that a correct
    // cleanup deletes nor the body vocabulary it has to keep, and passes or
    // fails for reasons the real inputs do not share.

    /// A Notes window: menu bar, status items, a hyphenated line break, two
    /// wraps, and two OCR character errors (`roIled`, `Fri-\nday`).
    private let noteWindowRaw = """
        Notes   File   Edit   View   Window   Help
        All iCloud   ·   3 unread                     100%   Tue 9:41 AM
        Q Search

        Sprint retro — action items

        The build server ran out of disk space on Fri-
        day, which is why the 14:20 deploy roIled
        back. Marco is adding a nightly prune job to
        the runner image so it cannot happen again.

        We also agreed to move the retro to Thurs-
        days, because it keeps colliding with the
        platform sync.
        """

    private let noteWindowCleaned = """
        Sprint retro — action items

        The build server ran out of disk space on Friday, which is why the 14:20 \
        deploy rolled back. Marco is adding a nightly prune job to the runner \
        image so it cannot happen again.

        We also agreed to move the retro to Thursdays, because it keeps colliding \
        with the platform sync.
        """

    /// A news article inside a full browser frame — the chrome-heavy case, and
    /// the one that decides where `minimumRetention` can sit.
    private let articleRaw = """
        Safari   File   Edit   View   History   Bookmarks   Window   Help
        < >   AA   theverge.com                                    + □
        Home  Tech  Reviews  Science  Entertainment  AI  Subscribe   Sign in

        We use cookies to personalise content. Accept all   Manage

        Apple ships on-device summaries to older Macs

        Apple said on Tuesday that the summarisation features intro-
        duced last autumn will reach Macs with M1 chips in the next
        minor release, reversing an earlier decision to limit them to
        M3 hardware and later.

        The company did not give a date beyond "this spring".

        12 Comments        Share        Save for later
        """

    private let articleCleaned = """
        Apple ships on-device summaries to older Macs

        Apple said on Tuesday that the summarisation features introduced last \
        autumn will reach Macs with M1 chips in the next minor release, \
        reversing an earlier decision to limit them to M3 hardware and later.

        The company did not give a date beyond "this spring".
        """

    /// A mail window whose body asks a question — the input that tempts a
    /// helpful model into answering instead of transcribing.
    private let mailRaw = """
        Mail   File   Edit   View   Mailbox   Message   Window   Help
        Inbox (4)                                Reply   Reply All   Forward

        From: Priya Raman
        Subject: token rotation

        Hey — quick one before standup. How do I revoke an API token for the
        staging tenant without locking out the nightly job that uses it? Marco
        said there was a flag for that but I cannot find it in the runbook.

        Sent from my iPhone
        """

    /// Distinct-token strings for the threshold arithmetic, where a realistic
    /// pair would only obscure which number is being pinned.
    private func synthetic(_ range: ClosedRange<Int>) -> String {
        range.map { "word\($0)" }.joined(separator: " ")
    }

    // MARK: - Accepting a real cleanup

    func testAChromeStrippedNoteWindowIsPlausible() {
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: noteWindowCleaned, raw: noteWindowRaw))
        // Deleting a menu bar, a status bar and a search field costs ~30% of
        // the distinct tokens on its own — which is why the retention floor
        // cannot sit anywhere near "a cleanup keeps every word".
        let retention = RefinementGuard.retentionRatio(cleaned: noteWindowCleaned, raw: noteWindowRaw)
        XCTAssertGreaterThan(retention, RefinementGuard.minimumRetention)
        XCTAssertLessThan(retention, 0.8)
    }

    func testRejoiningWrappedAndHyphenatedLinesIsPlausible() {
        // "Fri-" + "day" and "Thurs-" + "days" are four raw tokens that become
        // two tokens appearing nowhere in the raw text, and "roIled" → "rolled"
        // adds a third. Honest repair invents vocabulary by construction.
        let invented = RefinementGuard.inventionRatio(cleaned: noteWindowCleaned, raw: noteWindowRaw)
        XCTAssertGreaterThan(invented, 0, "dehyphenation cannot help but invent tokens")
        XCTAssertLessThanOrEqual(invented, RefinementGuard.maximumInvention)
    }

    func testAnArticleFreedFromItsBrowserFrameIsPlausible() {
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: articleCleaned, raw: articleRaw))
    }

    func testTranscribingAQuestionRatherThanAnsweringItIsPlausible() {
        let kept = """
            From: Priya Raman
            Subject: token rotation

            Hey — quick one before standup. How do I revoke an API token for the \
            staging tenant without locking out the nightly job that uses it? Marco \
            said there was a flag for that but I cannot find it in the runbook.
            """
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: kept, raw: mailRaw))
    }

    func testAModelThatChangedNothingIsPlausible() {
        // Documented and deliberate: the guard bounds damage, it does not
        // measure improvement, and a wasted refinement is not a failure.
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: articleRaw, raw: articleRaw))
    }

    // MARK: - Rejecting

    func testASummaryIsRejected() {
        let summary = "The team lost a deploy to a full disk and moved their retrospective."
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: summary, raw: noteWindowRaw))
        XCTAssertLessThan(
            RefinementGuard.retentionRatio(cleaned: summary, raw: noteWindowRaw),
            RefinementGuard.minimumRetention
        )
    }

    func testASummaryOfTheArticleIsRejected() {
        let summary = "Apple is bringing its summarisation features to M1 Macs this spring."
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: summary, raw: articleRaw))
    }

    func testAParaphraseIsRejectedEvenAtFullLength() {
        // Same length, same meaning, different words. Length is not the signal
        // — a paraphrase fails on both ratios at once.
        let paraphrase = """
            Storage on the continuous integration machine filled up last week, so \
            the afternoon release had to be reverted. Marco will schedule a cleanup \
            task inside the runner image. The retrospective also shifts to a \
            different weekday, since it kept overlapping another standing meeting.
            """
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: paraphrase, raw: noteWindowRaw))
        XCTAssertGreaterThan(
            RefinementGuard.inventionRatio(cleaned: paraphrase, raw: noteWindowRaw),
            RefinementGuard.maximumInvention
        )
    }

    func testAnsweringAQuestionFoundInTheTextIsRejected() {
        // The failure the whole guard exists for: the model read a question off
        // the user's screen and helpfully replaced the screen with its answer.
        let answer = """
            To revoke a staging API token without breaking the nightly job, create a \
            replacement token first, update the job's secret, and only then revoke \
            the old one. The --grace-period flag keeps the previous token valid for \
            24 hours while the rollout completes.
            """
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: answer, raw: mailRaw))
    }

    func testInventingContentOutOfTokenlessRawIsRejected() {
        // The mirror of erasure, and the case the counts cannot see: "• • •"
        // has no countable tokens, so nothing is dropped and the short-input
        // branch would wave through up to three invented ones. That is a model
        // handed a picture and describing it instead of transcribing text.
        XCTAssertTrue(RefinementGuard.tokens("• • •").isEmpty)
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: "Login dialog", raw: "• • •"))
        // A screenshot of icons or of bare single digits is the same shape.
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: "Quarterly revenue chart", raw: "1 2 3 4"))
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: "Sprint retro", raw: "   \n\n "))
    }

    func testEchoingBackATokenlessNoteIsStillPlausible() {
        // Guarding invention must not start rejecting the no-op: a model that
        // handed the bullets back unchanged fabricated nothing, and the
        // documented "a model that did nothing at all passes" holds here too.
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: "• • •", raw: "• • •"))
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: "1 2 3", raw: "1 2 3 4"))
    }

    func testErasingTheNoteIsRejected() {
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: "", raw: noteWindowRaw))
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: "   \n\n  ", raw: noteWindowRaw))
        // And for a short input too, where the token counts alone would call
        // it "2 dropped" and wave it through.
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: "", raw: "Unsaved changes"))
    }

    // MARK: - Thresholds

    func testRetentionIsMeasuredAgainstTheDocumentedFloor() {
        let raw = synthetic(1...20)
        // 8 of 20 distinct tokens survive: exactly the floor, and allowed.
        XCTAssertEqual(RefinementGuard.retentionRatio(cleaned: synthetic(1...8), raw: raw), 0.4, accuracy: 0.0001)
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: synthetic(1...8), raw: raw))
        // One token further and the same rewrite is a summary.
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: synthetic(1...7), raw: raw))
    }

    func testInventionIsMeasuredAgainstTheDocumentedCeiling() {
        let raw = synthetic(1...20)
        let atCeiling = synthetic(1...20) + " " + synthetic(101...105)
        // 5 new tokens in 25: exactly 20%, and allowed.
        XCTAssertEqual(RefinementGuard.inventionRatio(cleaned: atCeiling, raw: raw), 0.2, accuracy: 0.0001)
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: atCeiling, raw: raw))

        let overCeiling = synthetic(1...20) + " " + synthetic(101...108)
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: overCeiling, raw: raw))
        // Retention is untouched here — nothing was dropped — so the rejection
        // is the invention net firing on its own.
        XCTAssertEqual(RefinementGuard.retentionRatio(cleaned: overCeiling, raw: raw), 1)
    }

    func testAShortInputIsJudgedByAbsoluteAllowancesNotRatios() {
        // Two OCR character fixes on one short line. 2 of 7 distinct tokens are
        // new, which is 29% invention — the ratio would reject a rewrite that
        // is exactly what refinement is for. This is the case the ratios get
        // wrong, and the reason the short path exists.
        let raw = "Deploy to staglng at 14:2O"
        let cleaned = "Deploy to staging at 14:20"
        XCTAssertGreaterThan(
            RefinementGuard.inventionRatio(cleaned: cleaned, raw: raw),
            RefinementGuard.maximumInvention
        )
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: cleaned, raw: raw))
    }

    func testTheShortInputAllowancesAreAbsoluteCounts() {
        let raw = synthetic(1...11)  // one under shortTextTokenCount
        XCTAssertLessThan(Set(RefinementGuard.tokens(raw)).count, RefinementGuard.shortTextTokenCount)

        // Dropping is allowed up to the allowance and not past it.
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: synthetic(1...9), raw: raw))
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: synthetic(1...8), raw: raw))

        // Inventing is allowed one further, because a repair both drops a
        // token and adds one.
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: raw + " " + synthetic(101...103), raw: raw))
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: raw + " " + synthetic(101...104), raw: raw))
    }

    func testTheShortInputPathStopsAtTheDocumentedTokenCount() {
        // Same edit, one distinct token of difference in the input: at 11 the
        // absolute allowance rejects three drops, at 12 the ratio path accepts
        // them (0.75 retention). The switch is where the doc comment says.
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: synthetic(1...8), raw: synthetic(1...11)))
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: synthetic(1...9), raw: synthetic(1...12)))
    }

    // MARK: - Ratios on their own

    func testRatiosSurviveEmptyInput() {
        // Nothing to lose, so nothing was lost — and no divide by zero.
        XCTAssertEqual(RefinementGuard.retentionRatio(cleaned: "anything at all", raw: ""), 1)
        // Nothing was written, so nothing was invented.
        XCTAssertEqual(RefinementGuard.inventionRatio(cleaned: "", raw: "anything at all"), 0)
        XCTAssertEqual(RefinementGuard.retentionRatio(cleaned: "", raw: "anything at all"), 0)
        XCTAssertEqual(RefinementGuard.inventionRatio(cleaned: "anything at all", raw: ""), 1)
        for ratio in [
            RefinementGuard.retentionRatio(cleaned: "", raw: ""),
            RefinementGuard.inventionRatio(cleaned: "", raw: ""),
        ] {
            XCTAssertTrue(ratio.isFinite, "a ratio must never be NaN or infinite")
        }
    }

    func testIdenticalTextScoresPerfectly() {
        XCTAssertEqual(RefinementGuard.retentionRatio(cleaned: articleRaw, raw: articleRaw), 1)
        XCTAssertEqual(RefinementGuard.inventionRatio(cleaned: articleRaw, raw: articleRaw), 0)
    }

    func testTextWithNoCountableTokensDoesNotDivideByZero() {
        // Every token here is one character and therefore dropped, so both
        // sides tokenize to nothing — the shape that would divide by zero.
        let bullets = "a b c • 1 2"
        XCTAssertTrue(RefinementGuard.tokens(bullets).isEmpty)
        XCTAssertEqual(RefinementGuard.retentionRatio(cleaned: bullets, raw: bullets), 1)
        XCTAssertEqual(RefinementGuard.inventionRatio(cleaned: bullets, raw: bullets), 0)
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: bullets, raw: bullets))
    }

    func testARepeatedWordCannotOutvoteThePage() {
        // Distinct counts, not totals: forty "total" cells in a table must not
        // let a rewrite that kept only the table score as a faithful one.
        let raw = "total " + String(repeating: "total ", count: 40) + synthetic(1...20)
        XCTAssertLessThan(RefinementGuard.retentionRatio(cleaned: "total total total", raw: raw), 0.1)
    }

    // MARK: - Tags

    func testTagsAreLowercasedAndStrippedOfTheirHash() {
        XCTAssertEqual(
            RefinementGuard.sanitizedTags(["#Swift", "Deploy", "#CI"]),
            ["swift", "deploy", "ci"]
        )
    }

    func testTagsThatMeanTheSameThingCollapseToOne() {
        // A model emits all three spellings for one concept in a single
        // answer; a vault would show three tags.
        XCTAssertEqual(
            RefinementGuard.sanitizedTags(["#swift", "Swift.", "swift"]),
            ["swift"]
        )
    }

    func testTagOrderIsFirstSeenBecauseTheCapCutsFromTheTail() {
        XCTAssertEqual(
            RefinementGuard.sanitizedTags(["release", "deploy", "release", "ci"]),
            ["release", "deploy", "ci"]
        )
    }

    func testUnusableTagsAreDroppedRatherThanKeptEmpty() {
        // "###" and "🎉" normalize to nothing, and an empty tag in a vault's
        // front matter is a tag pane entry with no name.
        XCTAssertEqual(RefinementGuard.sanitizedTags(["", "  ", "###", "🎉", "notes"]), ["notes"])
    }

    func testTagsStopAtTheLimit() {
        let many = (1...12).map { "tag\($0)" }
        let sanitized = RefinementGuard.sanitizedTags(many)
        XCTAssertEqual(sanitized.count, RefinementGuard.tagLimit)
        XCTAssertEqual(sanitized.first, "tag1")
        // The cap counts tags that survived normalizing, not tags offered.
        XCTAssertEqual(RefinementGuard.sanitizedTags(["#", "", "a1", "b2", "c3"], limit: 2), ["a1", "b2"])
    }

    func testSeparatorsInATagFoldToHyphens() {
        // "#project notes" in a Markdown vault is the tag #project followed by
        // a stray word, so a space in a tag silently means something else.
        XCTAssertEqual(
            RefinementGuard.sanitizedTags(["note taking", "note/taking", "note-taking"]),
            ["note-taking"]
        )
        XCTAssertEqual(RefinementGuard.normalizedTag("-- release  notes --"), "release-notes")
    }

    // MARK: - Titles

    func testATitleIsCutAtTheWordLimit() {
        let clamped = RefinementGuard.clampedTitle(
            "Sprint retro action items for the platform team next week"
        )
        XCTAssertEqual(clamped, "Sprint retro action items for the platform team…")
        XCTAssertEqual(
            clamped.split(whereSeparator: { $0.isWhitespace }).count,
            RefinementGuard.titleWordLimit
        )
    }

    func testATitleIsCutAtTheCharacterLimitOnAWordBoundary() {
        // 63 characters in 6 words: under the word limit, over the character
        // one, and the cut has to land between words.
        let clamped = RefinementGuard.clampedTitle(
            "Quarterly infrastructure migration readiness assessment summary"
        )
        XCTAssertEqual(clamped, "Quarterly infrastructure migration readiness assessment…")
        XCTAssertFalse(clamped.contains("summar"), "a title must never be cut mid-word")
        XCTAssertLessThanOrEqual(
            clamped.dropLast().count,
            RefinementGuard.titleCharacterLimit
        )
    }

    func testATitleThatFitsIsLeftAlone() {
        XCTAssertEqual(RefinementGuard.clampedTitle("Sprint retro"), "Sprint retro")
        XCTAssertFalse(RefinementGuard.clampedTitle("Sprint retro").hasSuffix("…"))
    }

    func testASingleWordLongerThanTheBudgetIsHardCutRatherThanDiscarded() {
        // A URL or a base64 blob: returning "" would say "there was no title
        // here", which is a different and wrong claim.
        let clamped = RefinementGuard.clampedTitle("https://example.com/" + String(repeating: "a", count: 200))
        XCTAssertTrue(clamped.hasPrefix("https://example.com/"))
        XCTAssertEqual(clamped.count, RefinementGuard.titleCharacterLimit + 1)  // + the ellipsis
    }

    func testATitleWithNoWordsIsEmptyRatherThanBlank() {
        // "" is the signal callers use to mean "nothing usable here".
        XCTAssertEqual(RefinementGuard.clampedTitle(""), "")
        XCTAssertEqual(RefinementGuard.clampedTitle("   \n\t "), "")
    }

    // MARK: - Passthrough

    func testPassthroughIsAlwaysAvailableBecauseItAlwaysProducesANote() {
        XCTAssertTrue(PassthroughRefiner().isAvailable)
    }

    func testPassthroughReturnsTheInputTextUntouched() async {
        let input = RefinementInput(rawText: noteWindowRaw, isScreenshot: true)
        let note = await PassthroughRefiner().refine(input)

        // The whole contract: no model ran, so nothing may differ from what
        // the user already has on the clip.
        XCTAssertEqual(note.cleanedText, noteWindowRaw)
        XCTAssertFalse(note.wasRefined)
        XCTAssertEqual(note.summary, "", "a placeholder sentence would have to be special-cased everywhere")
        XCTAssertEqual(note.tags, [])
        XCTAssertFalse(note.title.isEmpty)
    }

    func testPassthroughTitlesTheNoteFromItsFirstUsableLine() async {
        let note = await PassthroughRefiner().refine(
            RefinementInput(rawText: "Sprint retro — action items:\nThe build server ran out of disk.")
        )
        // Trailing separators go; the closing bracket of "Build (v2)" would not.
        XCTAssertEqual(note.title, "Sprint retro — action items")
    }

    func testPassthroughSkipsLinesThatClampToNothing() {
        // A rule above the heading would date-stamp a note that had a
        // perfectly good title one line down.
        let title = PassthroughRefiner.heuristicTitle(
            for: RefinementInput(rawText: "***\n   \n•••\nRelease notes for 2.1\nbody text")
        )
        XCTAssertEqual(title, "Release notes for 2.1")
    }

    func testPassthroughSkipsRulesItHasNoSpecificCharacterFor() {
        // The regression: `─` (U+2500) is not in the trailing-punctuation set,
        // so the rule survived clamping and became the title — and this title
        // is the note's filename as well as its front matter, so a screenshot
        // of anything with a rule on top was filed as "… ────────.md".
        XCTAssertEqual(
            PassthroughRefiner.heuristicTitle(
                for: RefinementInput(rawText: "────────\nRelease notes for 2.1")
            ),
            "Release notes for 2.1"
        )
        // Every other rule character someone might screenshot, none of which
        // needs its own entry in a list now that the test is a character class.
        for rule in ["════════", "━━━━━━━━", "┈┈┈┈┈┈", "▁▁▁▁▁▁", "═ ═ ═ ═", "»»»", "~~~~~~", "▪▪▪"] {
            XCTAssertEqual(
                PassthroughRefiner.heuristicTitle(for: RefinementInput(rawText: rule + "\nSprint retro")),
                "Sprint retro",
                "a line with no letter and no digit is not a title"
            )
        }
    }

    func testAHeadingThatMerelyContainsPunctuationOrDigitsStillTitlesTheNote() {
        // The other half of the rule. Skipping anything that *contains*
        // punctuation would throw away most real headings — issue numbers,
        // version numbers, arrows — and date-stamp those notes instead.
        for heading in ["Fix #4213", "2.1 release notes", "→ next steps", "100% (v2)", "第一章"] {
            XCTAssertEqual(
                PassthroughRefiner.heuristicTitle(for: RefinementInput(rawText: heading + "\nbody text")),
                heading
            )
        }
    }

    func testANoteThatIsNothingButRulesFallsBackToATimestamp() {
        // Skipping rules must not leave the title empty: with no line that
        // carries any text, the timestamp is still the answer.
        let title = PassthroughRefiner.heuristicTitle(
            for: RefinementInput(
                rawText: "────────\n═══\n• • •\n",
                capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                isScreenshot: true
            )
        )
        XCTAssertTrue(title.hasPrefix("Screenshot "))
    }

    func testPassthroughFallsBackToATimestampWhenNoLineIsUsable() {
        let captured = Date(timeIntervalSince1970: 1_800_000_000)
        let screenshot = PassthroughRefiner.heuristicTitle(
            for: RefinementInput(rawText: "***\n...\n", capturedAt: captured, isScreenshot: true)
        )
        XCTAssertTrue(screenshot.hasPrefix("Screenshot "))
        XCTAssertGreaterThan(screenshot.count, "Screenshot ".count, "a bare noun is not a title")
        // Deterministic for a given clip, so a re-export lands on the same name.
        XCTAssertEqual(
            screenshot,
            PassthroughRefiner.heuristicTitle(
                for: RefinementInput(rawText: "", capturedAt: captured, isScreenshot: true)
            )
        )
    }

    func testATimestampTitleNamesWhereTheClipCameFrom() {
        let captured = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(
            PassthroughRefiner.timestampTitle(
                for: RefinementInput(rawText: "", sourceAppName: "Safari", capturedAt: captured)
            ).hasPrefix("Safari ")
        )
        // A blank app name is not a noun — it must not produce " 13 Aug 2026".
        XCTAssertTrue(
            PassthroughRefiner.timestampTitle(
                for: RefinementInput(rawText: "", sourceAppName: "   ", capturedAt: captured)
            ).hasPrefix("Clip ")
        )
        XCTAssertTrue(
            PassthroughRefiner.timestampTitle(
                for: RefinementInput(rawText: "", capturedAt: captured)
            ).hasPrefix("Clip ")
        )
    }

    func testTrailingPunctuationIsTrimmedNarrowly() {
        XCTAssertEqual(PassthroughRefiner.trimmingTrailingPunctuation("Sprint retro:"), "Sprint retro")
        XCTAssertEqual(PassthroughRefiner.trimmingTrailingPunctuation("Done!  "), "Done")
        // Trimming all punctuation would eat the closing half of these.
        XCTAssertEqual(PassthroughRefiner.trimmingTrailingPunctuation("Build (v2)"), "Build (v2)")
        XCTAssertEqual(PassthroughRefiner.trimmingTrailingPunctuation("release notes]"), "release notes]")
    }

    // MARK: - Bounding the input

    /// `count` characters of text in fixed-width lines, with no trailing
    /// newline so that the trimming inside `bounded` is a no-op and the two
    /// halves can be compared against the original exactly.
    private func lines(count: Int, width: Int = 100) -> String {
        (0..<count).map { index in
            let label = "line \(index) "
            return label + String(repeating: "x", count: max(0, width - label.count))
        }.joined(separator: "\n")
    }

    func testTextInsideTheBudgetIsSentWhole() {
        let text = lines(count: 10)
        let (sent, remainder) = FoundationModelsRefiner.bounded(text)
        XCTAssertEqual(sent, text)
        XCTAssertEqual(remainder, "")
    }

    func testTextExactlyAtTheBudgetIsSentWhole() {
        let text = String(repeating: "a", count: FoundationModelsRefiner.characterBudget)
        let (sent, remainder) = FoundationModelsRefiner.bounded(text)
        XCTAssertEqual(sent.count, FoundationModelsRefiner.characterBudget)
        XCTAssertEqual(remainder, "")
    }

    func testOverBudgetTextIsCutOnALineBoundary() {
        let text = lines(count: 120)  // ~12000 characters
        XCTAssertGreaterThan(text.count, FoundationModelsRefiner.characterBudget)

        let (sent, remainder) = FoundationModelsRefiner.bounded(text)

        XCTAssertLessThanOrEqual(sent.count, FoundationModelsRefiner.characterBudget)
        // A cut mid-sentence hands the model a fragment it tries to complete,
        // so the cut has to be a newline in the original.
        XCTAssertTrue(text.hasPrefix(sent))
        XCTAssertEqual(text.dropFirst(sent.count).first, "\n")
        XCTAssertTrue(sent.hasSuffix("x"), "the last line sent must be a whole line")
    }

    func testTheLineBoundaryIsHuntedNoFurtherBackThanTheSearchFloor() {
        let floor = Int(Double(FoundationModelsRefiner.characterBudget) * FoundationModelsRefiner.lineBoundarySearchFloor)
        let (sent, _) = FoundationModelsRefiner.bounded(lines(count: 120))
        XCTAssertGreaterThanOrEqual(sent.count, floor, "walking back further discards more than it saves")
    }

    func testTextWithNoNearbyNewlineIsCutAtTheBudget() {
        // The only newline sits well below the search floor, so there is
        // nothing worth walking back to.
        let text = String(repeating: "a", count: 1000) + "\n" + String(repeating: "b", count: 7000)
        let (sent, remainder) = FoundationModelsRefiner.bounded(text)
        XCTAssertEqual(sent.count, FoundationModelsRefiner.characterBudget)
        // The one newline is inside `sent`, so the halves still account for
        // every character of the original.
        XCTAssertEqual(sent + remainder, text)
    }

    func testTheRemainderIsHandedBackRatherThanLost() {
        let text = lines(count: 120)
        let (sent, remainder) = FoundationModelsRefiner.bounded(text)
        XCTAssertFalse(remainder.isEmpty)
        // Silently losing the second half of a long note is the one outcome
        // worse than not refining at all.
        XCTAssertEqual(sent + "\n" + remainder, text)
        XCTAssertTrue(remainder.hasSuffix("x"))
    }

    func testOneEnormousLineStillTerminatesAndReturnsSomethingUsable() {
        // A minified file, a base64 blob, a log line with no newline at all:
        // the line-boundary search finds nothing and must not loop or return
        // an empty payload.
        let text = String(repeating: "z", count: 40_000)
        let (sent, remainder) = FoundationModelsRefiner.bounded(text)
        XCTAssertEqual(sent.count, FoundationModelsRefiner.characterBudget)
        XCTAssertEqual(sent + remainder, text)
    }
}
