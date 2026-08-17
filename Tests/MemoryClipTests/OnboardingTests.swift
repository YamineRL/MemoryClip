import XCTest

@testable import MemoryClip

/// A `UserDefaults` that keeps everything in memory and touches no file.
///
/// The previous fixture built a real `UserDefaults(suiteName:)` with a fresh
/// UUID per test and cleared it with `removePersistentDomain(forName:)` — which
/// empties the keys but never deletes the backing plist, so every run leaked a
/// couple of `~/Library/Preferences/memoryclip.onboarding.tests.<UUID>.plist` files
/// into the user's home. Even a fixed suite name plus `removeSuite(named:)`
/// leaves one behind, because `cfprefsd` flushes the (now empty) suite after
/// the test process exits. `OnboardingController` only needs the four accessors
/// overridden below, so an in-memory stand-in keeps the same coverage with no
/// filesystem footprint at all.
private final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { storage[defaultName] }

    override func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        storage[defaultName] = nil
    }

    override func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }
}

final class OnboardingTests: XCTestCase {
    /// Isolated defaults so the tests never touch (or leak into) the real
    /// standard suite — and never write a plist anywhere.
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = InMemoryDefaults()
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    // MARK: First-run decision

    func testFirstRunIsTrueWhenKeyIsUnset() {
        XCTAssertNil(
            defaults.object(forKey: OnboardingController.hasCompletedKey),
            "the isolated suite should start empty — teardown from a previous test leaked state"
        )
        XCTAssertTrue(
            OnboardingController.isFirstRun(defaults: defaults),
            "an unset flag must mean first run, otherwise the tour never shows"
        )
    }

    func testFirstRunIsFalseAfterCompletion() {
        OnboardingController.markCompleted(defaults: defaults)
        XCTAssertFalse(
            OnboardingController.isFirstRun(defaults: defaults),
            "the tour would reopen on every launch after being completed"
        )
        // Idempotent: marking twice keeps it completed.
        OnboardingController.markCompleted(defaults: defaults)
        XCTAssertFalse(
            OnboardingController.isFirstRun(defaults: defaults),
            "marking completion twice must stay completed"
        )
    }

    func testResetMakesItAFirstRunAgain() {
        OnboardingController.markCompleted(defaults: defaults)
        OnboardingController.reset(defaults: defaults)
        XCTAssertTrue(
            OnboardingController.isFirstRun(defaults: defaults),
            "Settings → Show Introduction Again relies on reset() restoring first-run state"
        )
    }

    /// Deliberately pins the literal: this string is a *persisted* UserDefaults
    /// key in shipped installs. Renaming it silently re-shows the tour to every
    /// existing user, so a change here must be a conscious one (with a
    /// migration), not an incidental rename.
    func testCompletionKeyNameIsStableAcrossReleases() {
        XCTAssertEqual(
            OnboardingController.hasCompletedKey, "hasCompletedOnboarding",
            "renaming this persisted key re-shows the tour to every existing user"
        )
    }

    // MARK: Step definitions

    /// Structural invariants rather than a snapshot of the step list: editing
    /// the tour's copy or reordering it is not a regression, but an empty tour,
    /// a `count` out of step with `steps`, or duplicate ids (which break
    /// SwiftUI identity and the step lookups below) all are.
    func testStepListIsWellFormed() {
        XCTAssertFalse(OnboardingFlow.steps.isEmpty, "the tour has no steps to show")
        XCTAssertEqual(
            OnboardingFlow.steps.count, OnboardingFlow.count,
            "count must match steps.count — the navigation clamps derive from count"
        )
        let ids = OnboardingFlow.steps.map(\.id)
        XCTAssertEqual(
            Set(ids).count, ids.count,
            "duplicate step ids break SwiftUI identity and step lookup: \(ids)"
        )
        for id in ids {
            XCTAssertFalse(id.isEmpty, "a step has an empty identifier")
        }
    }

    func testEveryStepHasContent() {
        for step in OnboardingFlow.steps {
            XCTAssertFalse(step.title.isEmpty, "\(step.id) has no title")
            XCTAssertFalse(step.subtitle.isEmpty, "\(step.id) has no subtitle")
            XCTAssertFalse(step.symbol.isEmpty, "\(step.id) has no symbol")
            XCTAssertFalse(step.bullets.isEmpty, "\(step.id) has no bullets")
        }
    }

    /// The honest auto-paste framing must stay in the tour (it mirrors the
    /// wording used in SettingsView / README). Found by the control it
    /// carries rather than by page id, so rewriting the page around the switch
    /// is free and dropping the sentence is not.
    func testAutoPasteStepMentionsAccessibilityAndFallback() throws {
        let step = try XCTUnwrap(OnboardingFlow.steps.first { $0.setup == .autoPaste })
        let text = step.bullets.joined(separator: " ")
        XCTAssertTrue(
            text.contains("Accessibility"),
            "the auto-paste step must name the permission it needs: \(text)"
        )
        XCTAssertTrue(
            text.contains("⌘V"),
            "the auto-paste step must state the manual fallback: \(text)"
        )
    }

    /// The calendar page is where the write-only grant is asked for, and the
    /// automatic path may not raise that prompt itself — so the page has to
    /// carry the switch, not merely mention that one exists.
    func testCalendarStepOffersTheSwitchAndNamesItsKey() throws {
        let step = try XCTUnwrap(OnboardingFlow.steps.first { $0.id == "calendar" })
        XCTAssertEqual(step.setup, .calendarEvents)
        let text = step.bullets.joined(separator: " ")
        XCTAssertTrue(text.contains("⌘E"), "the page must name the panel key: \(text)")
        XCTAssertTrue(
            text.contains("Add to Calendar"),
            "the page must name the action as ClipCardView spells it: \(text)"
        )
    }

    /// A tour is read in the order it is written, so anything needing an
    /// answer is asked before anything that only explains: a decision buried
    /// past the last page anyone reaches is a decision nobody makes.
    func testEveryPageWithAControlComesFirst() {
        let carriesControl = OnboardingFlow.steps.map { $0.setup != nil }
        let lastAsking = carriesControl.lastIndex(of: true) ?? -1
        let firstTelling = carriesControl.firstIndex(of: false) ?? OnboardingFlow.count
        XCTAssertLessThan(
            lastAsking, firstTelling,
            "a page that only explains sits above one that asks for a decision: \(OnboardingFlow.steps.map(\.id))"
        )
    }

    /// The tour is finite on purpose. Nobody clicks Next eight times, and a
    /// page nobody reaches carries a setting nobody sets.
    func testTheTourStaysShortEnoughToBeRead() {
        XCTAssertLessThanOrEqual(
            OnboardingFlow.count, 6,
            "the tour grew past what a first launch will sit through: \(OnboardingFlow.steps.map(\.id))"
        )
    }

    // MARK: Inline setup

    /// The tour offers controls, not just prose, and each one is offered
    /// exactly once. A case nothing shows is a control the user can never
    /// reach; two pages sharing a case is the same switch asked for twice,
    /// which is how a tour starts turning into the Settings window.
    func testEverySetupControlIsOfferedOnExactlyOnePage() {
        let offered = OnboardingFlow.steps.compactMap(\.setup)
        XCTAssertEqual(
            Set(offered).count, offered.count,
            "two pages offer the same setting: \(offered.map(\.rawValue))"
        )
        for control in OnboardingSetup.allCases {
            XCTAssertTrue(
                offered.contains(control),
                "\(control.rawValue) is defined but no step shows it, so nothing can reach it"
            )
        }
    }

    /// The destination page is the reason the tour gained controls at all: the
    /// Markdown folder has no default, so a user who never opens Settings
    /// meets `NoteError.noDestinationConfigured` instead of a note. It must
    /// keep both halves — the action that writes a note, and the picker.
    func testNoteStepOffersTheDestinationPicker() throws {
        let step = try XCTUnwrap(OnboardingFlow.steps.first { $0.id == "notes" })
        XCTAssertEqual(
            step.setup, .noteDestination,
            "the notes page must carry the destination picker, not merely describe it"
        )
        let text = step.bullets.joined(separator: " ")
        XCTAssertTrue(
            text.contains("Save as Note"),
            "the page must name the panel action that writes a note, as ClipCardView spells it: \(text)"
        )
        XCTAssertTrue(
            text.contains("⌘S"),
            "the page must name the key as well: the panel has no menu bar to find it in: \(text)"
        )
        XCTAssertTrue(
            text.contains("Settings → Notes"),
            "the page must say where the same settings live afterwards: \(text)"
        )
        XCTAssertTrue(
            text.contains("Settings → Translation"),
            "translation left the Notes pane; the page that mentions it must send the reader to the right one: \(text)"
        )
    }

    /// Every "Settings → X" in the tour must name a pane that exists.
    ///
    /// The tour is written once and read by every new user, so a pointer at a
    /// pane that has since been renamed sends them looking for a word the
    /// sidebar no longer contains — which is exactly what "Settings → Security
    /// & Privacy" did after the pane became Privacy. Derived from
    /// `SettingsPane.title` rather than a list of accepted words, so renaming a
    /// pane fails here instead of quietly making the tour wrong.
    func testEverySettingsPointerNamesAPaneThatExists() {
        let titles = Set(SettingsPane.allCases.map(\.title))
        // "System Settings → Privacy & Security" is macOS's own pane and not
        // ours to check; neutralise the phrase before scanning for ours.
        let text = OnboardingFlow.steps
            .flatMap(\.bullets)
            .joined(separator: "\n")
            .replacingOccurrences(of: "System Settings → ", with: "macOS pane ")

        var rest = Substring(text)
        var checked = 0
        while let marker = rest.range(of: "Settings → ") {
            rest = rest[marker.upperBound...]
            let name = String(rest.prefix { $0.isLetter })
            checked += 1
            XCTAssertTrue(
                titles.contains(name),
                "the tour points at Settings → \(name), which is not one of \(titles.sorted())"
            )
        }
        XCTAssertGreaterThan(
            checked, 0,
            "no Settings pointers were found at all — the scan, not the tour, is what broke"
        )
    }

    /// Nothing the tour offers may become a gate. The flow is what `Next` and
    /// `Done` consult, and it has no notion of a step being satisfied — this
    /// pins that: every page is reachable and leavable with the setup
    /// untouched, which is what makes the controls optional in fact and not
    /// just in intent.
    func testEveryPageIsPassableWithoutUsingItsControl() {
        var index = 0
        while !OnboardingFlow.isLast(index) {
            let next = OnboardingFlow.nextIndex(after: index)
            XCTAssertEqual(
                next, index + 1,
                "\(OnboardingFlow.step(at: index).id) did not advance — a step that holds the tour up is a blocking step"
            )
            index = next
        }
        XCTAssertEqual(
            index, OnboardingFlow.count - 1,
            "walking Next without configuring anything must reach the last page, where Done lives"
        )
    }

    // MARK: Navigation / index clamping

    func testNextAdvancesOneStep() {
        XCTAssertEqual(OnboardingFlow.nextIndex(after: 0), 1, "Next from 0 should land on 1")
        XCTAssertEqual(OnboardingFlow.nextIndex(after: 3), 4, "Next from 3 should land on 4")
    }

    func testPreviousGoesBackOneStep() {
        XCTAssertEqual(OnboardingFlow.previousIndex(before: 4), 3, "Back from 4 should land on 3")
        XCTAssertEqual(OnboardingFlow.previousIndex(before: 1), 0, "Back from 1 should land on 0")
    }

    func testNextClampsAtTheLastStep() {
        let last = OnboardingFlow.count - 1
        XCTAssertEqual(
            OnboardingFlow.nextIndex(after: last), last,
            "Next on the last step must stay put, not run off the end"
        )
        XCTAssertEqual(
            OnboardingFlow.nextIndex(after: last + 5), last,
            "an out-of-range index must clamp to the last step"
        )
    }

    func testPreviousClampsAtTheFirstStep() {
        XCTAssertEqual(
            OnboardingFlow.previousIndex(before: 0), 0,
            "Back on the first step must stay put"
        )
        XCTAssertEqual(
            OnboardingFlow.previousIndex(before: -3), 0,
            "a negative index must clamp to the first step"
        )
    }

    func testFirstAndLastPredicates() {
        let last = OnboardingFlow.count - 1
        XCTAssertTrue(OnboardingFlow.isFirst(0), "index 0 is the first step")
        XCTAssertFalse(OnboardingFlow.isLast(0), "index 0 is not the last step")
        XCTAssertTrue(OnboardingFlow.isLast(last), "index \(last) is the last step")
        XCTAssertFalse(OnboardingFlow.isFirst(last), "index \(last) is not the first step")
        // Out-of-range indices resolve to the nearest boundary.
        XCTAssertTrue(OnboardingFlow.isFirst(-10), "negative indices clamp to the first step")
        XCTAssertTrue(
            OnboardingFlow.isLast(last + 10),
            "indices past the end clamp to the last step"
        )
    }

    func testStepAccessorClampsOutOfRangeIndices() throws {
        XCTAssertEqual(
            OnboardingFlow.step(at: -1), try XCTUnwrap(OnboardingFlow.steps.first),
            "a negative index must resolve to the first step, never trap"
        )
        XCTAssertEqual(
            OnboardingFlow.step(at: 999), try XCTUnwrap(OnboardingFlow.steps.last),
            "an index past the end must resolve to the last step, never trap"
        )
    }

    func testWalkingForwardAndBackTraversesEveryStep() {
        var index = 0
        var visited = [OnboardingFlow.step(at: index).id]
        while !OnboardingFlow.isLast(index) {
            index = OnboardingFlow.nextIndex(after: index)
            visited.append(OnboardingFlow.step(at: index).id)
        }
        XCTAssertEqual(
            visited, OnboardingFlow.steps.map(\.id),
            "walking Next from the start must reach every step exactly once, in order"
        )

        while !OnboardingFlow.isFirst(index) {
            index = OnboardingFlow.previousIndex(before: index)
        }
        XCTAssertEqual(index, 0, "walking Back from the end must return to the first step")
    }
}
