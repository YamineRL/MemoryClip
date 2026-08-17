import Foundation
import XCTest

@testable import MemoryClip

/// Lets a test hold a translation open and release it on cue, so "while the
/// engine is still working" is a state the test controls rather than races.
private actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

/// Counts what the engine was actually asked to do.
private actor Ledger {
    private(set) var texts: [String] = []
    private(set) var cancellations = 0

    func record(_ text: String) { texts.append(text) }
    func recordCancellation() { cancellations += 1 }
}

/// A translator that does not answer until the test says so, and reports
/// whether it was cancelled while waiting.
private struct GatedTranslator: NoteTranslator {
    let gate: Gate
    let ledger: Ledger

    func supportedLanguages() async -> [Locale.Language] { [Locale.Language(identifier: "zh")] }
    func readiness(for language: Locale.Language) async -> TranslationReadiness { .ready }

    func translate(_ text: String, from language: Locale.Language) async -> TranslatedText? {
        await translate(text, from: language, to: NoteTranslation.target)
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async -> TranslatedText? {
        await translate(text, from: source, to: target) { _ in }
    }

    func translate(
        _ text: String,
        from source: Locale.Language,
        to target: Locale.Language,
        onProgress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> TranslatedText? {
        await ledger.record(text)
        // One chunk in before the gate, so a test can look at the pane while
        // the rest is still coming.
        await onProgress("Half of: \(text)")
        await gate.wait()
        // The real engine surfaces cancellation as a thrown error and returns
        // nil; this stands in for that.
        if Task.isCancelled {
            await ledger.recordCancellation()
            return nil
        }
        return TranslatedText(text: "English of: \(text)", sourceLanguage: LanguageDetector.identifier(for: source))
    }
}

private let chinese = "这是一个自动翻译的测试。会议将于星期二下午三点在会议室举行。请准时参加。"

private func request(_ text: String = chinese) -> ClipTranslationRequest {
    ClipTranslationRequest(
        text: text,
        isTruncated: false,
        source: Locale.Language(identifier: "zh"),
        target: Locale.Language(identifier: "en")
    )
}

/// The run store, which exists so that a translation outlives the pane that
/// asked for it.
@MainActor
final class ClipTranslationRunsTests: XCTestCase {
    private var store: ClipStore!
    private var item: ClipItem!
    private var gate: Gate!
    private var ledger: Ledger!
    private var runs: ClipTranslationRuns!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try ClipStore(inMemory: true)
        item = ClipItem(kind: .text, text: chinese, contentHash: "hash")
        store.context.insert(item)
        gate = Gate()
        ledger = Ledger()
        runs = ClipTranslationRuns(
            service: ClipTranslationService(translator: GatedTranslator(gate: gate, ledger: ledger))
        )
    }

    override func tearDown() {
        store = nil
        item = nil
        runs = nil
        super.tearDown()
    }

    /// Let the run reach the engine before the test does anything else.
    private func waitForEngine(count: Int = 1) async throws {
        for _ in 0..<200 {
            if await ledger.texts.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the engine was never asked to translate")
    }

    private func waitForCache() async throws {
        for _ in 0..<200 {
            if item.cachedClipTranslation != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The regression this file is named after. The preview pane is torn down
    /// every time MemoryClip stops being frontmost, and the translation of the
    /// clip must survive that: it finishes, and it lands on the clip, so the
    /// pane shows it the moment it comes back.
    func testACancelledCallerDoesNotCancelTheTranslation() async throws {
        let caller = Task { await runs.translation(for: request(), of: item, in: store.context) }
        try await waitForEngine()

        caller.cancel()
        await gate.open()
        try await waitForCache()

        let cancellations = await ledger.cancellations
        XCTAssertEqual(cancellations, 0, "the engine must not have seen the caller's cancellation")
        XCTAssertEqual(item.cachedClipTranslation?.text, "English of: \(chinese)")
        XCTAssertEqual(item.cachedClipTranslation?.sourceLanguage, "zh")
        XCTAssertEqual(item.cachedClipTranslation?.targetLanguage, "en")
    }

    /// Two panes, or one pane opened twice, are one translation. The engine is
    /// the slowest thing in the app; asking it the same question twice while
    /// it is still answering is the waste this store exists to stop.
    func testASecondCallerJoinsTheRunAlreadyGoing() async throws {
        let first = Task { await runs.translation(for: request(), of: item, in: store.context) }
        try await waitForEngine()
        let second = Task { await runs.translation(for: request(), of: item, in: store.context) }

        await gate.open()
        let results = [await first.value, await second.value]

        let asked = await ledger.texts.count
        XCTAssertEqual(asked, 1, "the engine must be asked once")
        XCTAssertEqual(results.compactMap { $0?.text }, Array(repeating: "English of: \(chinese)", count: 2))
    }

    /// A run is superseded when what it is translating is no longer what the
    /// pane would show — recognition finished, or the model cleaned the text
    /// up. That one IS cancelled, because finishing it would cache an answer
    /// to a question nobody is asking any more.
    func testADifferentRequestForTheSameClipSupersedesTheRunGoing() async throws {
        let cleaned = "会议将于星期二下午三点在会议室举行。请准时参加，并带上季度预算报告。"
        let first = Task { await runs.translation(for: request(), of: item, in: store.context) }
        try await waitForEngine()
        let second = Task { await runs.translation(for: request(cleaned), of: item, in: store.context) }
        try await waitForEngine(count: 2)

        await gate.open()
        let superseded = await first.value
        let current = await second.value

        XCTAssertNil(superseded, "the run for the stale text must not produce an answer")
        let cancellations = await ledger.cancellations
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(current?.text, "English of: \(cleaned)")
        try await waitForCache()
        XCTAssertEqual(item.cachedClipTranslation?.text, "English of: \(cleaned)")
    }
}

/// What the pane shows while all that is going on.
@MainActor
final class ClipTranslationPresenterTests: XCTestCase {
    private var store: ClipStore!
    private var item: ClipItem!
    private var gate: Gate!
    private var ledger: Ledger!
    private var presenter: ClipTranslationPresenter!

    private let english = Locale.Language(identifier: "en")

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try ClipStore(inMemory: true)
        item = ClipItem(kind: .text, text: chinese, contentHash: "hash")
        store.context.insert(item)
        gate = Gate()
        ledger = Ledger()
        presenter = ClipTranslationPresenter(
            runs: ClipTranslationRuns(
                service: ClipTranslationService(translator: GatedTranslator(gate: gate, ledger: ledger))
            )
        )
    }

    override func tearDown() {
        store = nil
        item = nil
        presenter = nil
        super.tearDown()
    }

    private func refresh() -> Task<Void, Never> {
        Task {
            await presenter.refresh(item: item, context: store.context, isEnabled: true, target: english)
        }
    }

    private func waitForEngine() async throws {
        for _ in 0..<200 {
            if await ledger.texts.count >= 1 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the engine was never asked to translate")
    }

    /// The bug: a cancelled refresh returned with the flag still set, and the
    /// pane span for ever. However this ends, the spinner ends with it.
    func testACancelledRefreshLeavesNoSpinnerBehind() async throws {
        let task = refresh()
        try await waitForEngine()
        XCTAssertTrue(presenter.isTranslating)

        task.cancel()
        await gate.open()
        await task.value

        XCTAssertFalse(presenter.isTranslating, "a cancelled refresh must not leave the pane claiming to be working")
        XCTAssertNil(presenter.translation, "the answer belongs to a pane that is no longer looking")
    }

    /// The ordinary path, for contrast: the spinner is up while the engine
    /// works and gone once it answers.
    func testAFinishedRefreshShowsTheTranslationAndStopsTheSpinner() async throws {
        let task = refresh()
        try await waitForEngine()
        XCTAssertTrue(presenter.isTranslating)

        await gate.open()
        await task.value

        XCTAssertFalse(presenter.isTranslating)
        XCTAssertEqual(presenter.translation?.text, "English of: \(chinese)")
    }

    /// Nothing to do means nothing shown, and above all no spinner: this is
    /// every clip in a language the user already reads.
    func testASkippedClipShowsNothing() async {
        let english = ClipItem(kind: .text, text: "The meeting is on Tuesday at three in the boardroom.", contentHash: "english")
        store.context.insert(english)

        await presenter.refresh(item: english, context: store.context, isEnabled: true, target: self.english)

        XCTAssertFalse(presenter.isTranslating)
        XCTAssertNil(presenter.translation)
        let asked = await ledger.texts.count
        XCTAssertEqual(asked, 0)
    }

    /// The reason for all of this: a clip long enough to take seconds shows
    /// what has arrived while the rest is still coming, spinner and all.
    func testAPartialTranslationIsShownWhileTheRestIsStillComing() async throws {
        let task = refresh()
        try await waitForPartial()

        XCTAssertEqual(presenter.translation?.text, "Half of: \(chinese)")
        XCTAssertEqual(presenter.translation?.sourceLanguage, "zh")
        XCTAssertTrue(presenter.isTranslating, "the pane is not finished until the last chunk lands")
        XCTAssertNil(item.cachedClipTranslation, "only the finished translation is kept on the clip")

        await gate.open()
        await task.value

        XCTAssertFalse(presenter.isTranslating)
        XCTAssertEqual(presenter.translation?.text, "English of: \(chinese)")
        XCTAssertEqual(item.cachedClipTranslation?.text, "English of: \(chinese)")
    }

    private func waitForPartial() async throws {
        for _ in 0..<200 {
            if presenter.translation != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("no partial translation ever reached the pane")
    }

    /// A clip translated before is shown at once, without the engine.
    func testACachedTranslationIsShownWithoutTranslatingAgain() async {
        item.cachedClipTranslation = ClipTranslationResult(
            text: "Cached English",
            sourceLanguage: "zh",
            targetLanguage: "en"
        )

        await presenter.refresh(item: item, context: store.context, isEnabled: true, target: english)

        XCTAssertEqual(presenter.translation?.text, "Cached English")
        XCTAssertFalse(presenter.isTranslating)
        let asked = await ledger.texts.count
        XCTAssertEqual(asked, 0)
    }
}
