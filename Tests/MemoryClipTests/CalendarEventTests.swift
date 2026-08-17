import XCTest

@testable import MemoryClip

/// A sink with no EventKit behind it, so the clip → event path can be tested
/// without calendar permission, a default calendar, or anyone to answer the
/// prompt — none of which a build machine has.
///
/// `@MainActor final class` for the same two reasons the real one is: it
/// accumulates what it was given, and it stands in for something that holds a
/// live `EKEventStore`.
@MainActor
private final class FakeEventSink: EventSink {
    /// Every event handed to `save`, in order.
    private(set) var saved: [DetectedEvent] = []
    private(set) var removals = 0

    /// Thrown instead of saving, to drive the failure paths.
    var saveError: CalendarError?
    var removeError: CalendarError?

    var calendarTitle = "Work"

    /// What the automatic path asks before it uses a sink at all. The real one
    /// answers from TCC; this one is set by the test that cares.
    ///
    /// `nonisolated(unsafe)` because the protocol requirement is not
    /// main-actor bound while this class is. Every test that touches it runs
    /// on the main actor, and nothing else reads it.
    nonisolated(unsafe) var wouldPromptForAccess = false

    @MainActor
    func save(_ event: DetectedEvent) async throws -> EventReceipt {
        if let saveError { throw saveError }
        saved.append(event)
        return EventReceipt(
            eventIdentifier: "event-\(saved.count)",
            calendarTitle: calendarTitle,
            start: event.start
        )
    }

    @MainActor
    func removeLastSaved() async throws {
        if let removeError { throw removeError }
        removals += 1
        if !saved.isEmpty { saved.removeLast() }
    }
}

/// The persistence half of "Add to Calendar": what the coordinator reads off a
/// clip, what it writes back to it, and the one piece of arithmetic that has to
/// be right for an all-day event to land on the right day.
@MainActor
final class CalendarEventTests: XCTestCase {
    /// A fixed zone, so the all-day arithmetic does not depend on where the
    /// machine running the tests happens to be.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        return calendar
    }()

    override func tearDownWithError() throws {
        for key in [
            CalendarSettingsKeys.autoCreate,
            CalendarSettingsKeys.eventDurationMinutes,
            CalendarSettingsKeys.notifyOnAutoCreate,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Fixtures

    private func makeStore() throws -> ClipStore {
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
        return try ClipStore(inMemory: true)
    }

    @discardableResult
    private func insert(_ text: String, into store: ClipStore) throws -> ClipItem {
        store.insert(
            CapturedClip(
                kind: .text,
                text: text,
                richTextData: nil,
                imageData: nil,
                fileURLStrings: [],
                colorHex: nil,
                hash: ContentParser.hashText("text:\(text)")
            ),
            sourceBundleID: nil,
            sourceAppName: nil
        )
        return try XCTUnwrap(store.recent(limit: 1).first)
    }

    private static let invitation = """
    Design review
    August 20, 2026 at 3:00 PM – 4:00 PM
    Zoom: https://us02web.zoom.us/j/89123456789
    """

    // MARK: - Creating

    func testAScheduledClipRemembersItsEvent() async throws {
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        guard case .success(let receipt) = await coordinator.addEvent(for: item) else {
            return XCTFail("a clip with a date and a meeting link should schedule")
        }

        XCTAssertEqual(sink.saved.count, 1)
        XCTAssertEqual(sink.saved.first?.title, "Design review")
        XCTAssertEqual(receipt.calendarTitle, "Work")

        // The clip records the event, which is what stops a second one being
        // created for the same appointment.
        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))
        XCTAssertEqual(refreshed.calendarEventID, receipt.eventIdentifier)
        XCTAssertNil(coordinator.lastError)
    }

    func testAClipWithNoDateCannotBeScheduled() async throws {
        let store = try makeStore()
        let item = try insert("Just some text with nothing to put in a calendar", into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        let result = await coordinator.addEvent(for: item)
        guard case .failure(let error) = result else {
            return XCTFail("text with no date must not become an event")
        }

        XCTAssertEqual(error, .nothingToSchedule)
        XCTAssertEqual(coordinator.lastError, .nothingToSchedule)
        XCTAssertTrue(sink.saved.isEmpty, "the sink must not be reached at all")
        XCTAssertNil(try XCTUnwrap(store.item(withUUID: item.uuid)).calendarEventID)
    }

    func testASinkFailureSurfacesAsItsOwnError() async throws {
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        sink.saveError = .accessDenied
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        let result = await coordinator.addEvent(for: item)
        guard case .failure(let error) = result else {
            return XCTFail("a refused permission must not read as a success")
        }

        XCTAssertEqual(error, .accessDenied)
        XCTAssertEqual(coordinator.lastError, .accessDenied)
        XCTAssertNil(
            try XCTUnwrap(store.item(withUUID: item.uuid)).calendarEventID,
            "a clip whose event was never created must not look scheduled"
        )
    }

    func testASuccessClearsAnEarlierFailure() async throws {
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        sink.saveError = .noWritableCalendar
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        _ = await coordinator.addEvent(for: item)
        XCTAssertEqual(coordinator.lastError, .noWritableCalendar)

        sink.saveError = nil
        _ = await coordinator.addEvent(for: item)
        XCTAssertNil(coordinator.lastError)
    }

    // MARK: - Creating without being asked

    /// A clip with no clock time and no corroboration. `EventDetector` reads a
    /// date out of it — so the manual button would schedule it — and
    /// `isStrongSignal` is what says it is not an appointment.
    private static let bareDate = "Your subscription renews on August 20, 2026"

    func testAStrongSignalClipSchedulesItself() async throws {
        UserDefaults.standard.set(true, forKey: CalendarSettingsKeys.autoCreate)
        UserDefaults.standard.set(false, forKey: CalendarSettingsKeys.notifyOnAutoCreate)
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        let receipt = await coordinator.autoCreateIfWanted(for: item)

        XCTAssertNotNil(receipt, "a timed invitation with a meeting link is what the setting is for")
        XCTAssertEqual(sink.saved.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(store.item(withUUID: item.uuid)).calendarEventID,
            receipt?.eventIdentifier
        )
    }

    func testAWeakSignalClipIsLeftAlone() async throws {
        UserDefaults.standard.set(true, forKey: CalendarSettingsKeys.autoCreate)
        let store = try makeStore()
        let item = try insert(Self.bareDate, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        // The date is real — the manual button would have scheduled it.
        XCTAssertNotNil(coordinator.event(for: item))

        let receipt = await coordinator.autoCreateIfWanted(for: item)

        XCTAssertNil(receipt, "a bare date is a date, not an appointment")
        XCTAssertTrue(sink.saved.isEmpty)
        XCTAssertNil(try XCTUnwrap(store.item(withUUID: item.uuid)).calendarEventID)
    }

    func testNothingIsCreatedWhileTheSettingIsOff() async throws {
        UserDefaults.standard.set(false, forKey: CalendarSettingsKeys.autoCreate)
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        let receipt = await coordinator.autoCreateIfWanted(for: item)

        XCTAssertNil(receipt)
        XCTAssertTrue(sink.saved.isEmpty, "the sink must not be reached at all")
    }

    func testAClipThatAlreadyHasAnEventIsNotScheduledTwice() async throws {
        UserDefaults.standard.set(true, forKey: CalendarSettingsKeys.autoCreate)
        UserDefaults.standard.set(false, forKey: CalendarSettingsKeys.notifyOnAutoCreate)
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        _ = await coordinator.addEvent(for: item)
        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))

        let receipt = await coordinator.autoCreateIfWanted(for: refreshed)

        XCTAssertNil(receipt)
        XCTAssertEqual(sink.saved.count, 1, "the appointment is in the calendar once")
    }

    /// The first permission dialog has to come from something the user
    /// pressed, so a sink that has never been asked declines the automatic
    /// path and keeps working for the manual one.
    func testTheFirstPermissionPromptIsLeftToTheButton() async throws {
        UserDefaults.standard.set(true, forKey: CalendarSettingsKeys.autoCreate)
        UserDefaults.standard.set(false, forKey: CalendarSettingsKeys.notifyOnAutoCreate)
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        sink.wouldPromptForAccess = true
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        let receipt = await coordinator.autoCreateIfWanted(for: item)

        XCTAssertNil(receipt)
        XCTAssertTrue(sink.saved.isEmpty)

        guard case .success = await coordinator.addEvent(for: item) else {
            return XCTFail("the button may prompt, so it must not be blocked by the same check")
        }
    }

    func testABatchOnlyOffersTheClipsItNames() async throws {
        UserDefaults.standard.set(true, forKey: CalendarSettingsKeys.autoCreate)
        UserDefaults.standard.set(false, forKey: CalendarSettingsKeys.notifyOnAutoCreate)
        let store = try makeStore()
        let named = try insert(Self.invitation, into: store)
        let unnamed = try insert(
            """
            Retro
            August 21, 2026 at 11:00 AM – 11:30 AM
            Zoom: https://us02web.zoom.us/j/89123456780
            """,
            into: store
        )
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        await coordinator.autoCreateIfWanted(forClipsWith: [named.uuid])

        XCTAssertEqual(sink.saved.count, 1)
        XCTAssertNotNil(try XCTUnwrap(store.item(withUUID: named.uuid)).calendarEventID)
        XCTAssertNil(
            try XCTUnwrap(store.item(withUUID: unnamed.uuid)).calendarEventID,
            "a clip the batch did not name is a clip recognition did not just finish"
        )
    }

    // MARK: - Undo

    func testUndoRemovesTheEventAndClearsTheClip() async throws {
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        _ = await coordinator.addEvent(for: item)
        guard case .success = await coordinator.undoLastEvent() else {
            return XCTFail("undo failed")
        }

        XCTAssertEqual(sink.removals, 1)
        XCTAssertTrue(sink.saved.isEmpty)
        XCTAssertNil(try XCTUnwrap(store.item(withUUID: item.uuid)).calendarEventID)
    }

    func testUndoWithNothingCreatedDoesNothing() async throws {
        let store = try makeStore()
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        guard case .success = await coordinator.undoLastEvent() else {
            return XCTFail("nothing to undo is not a failure")
        }
        XCTAssertNil(coordinator.lastError)
    }

    func testAFailedRemovalKeepsTheIdentifierOnTheClip() async throws {
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        _ = await coordinator.addEvent(for: item)
        sink.removeError = .removeFailed("the event is gone")

        guard case .failure(let error) = await coordinator.undoLastEvent() else {
            return XCTFail("a refused removal must not read as a success")
        }
        XCTAssertEqual(error, .removeFailed("the event is gone"))
        XCTAssertNotNil(
            try XCTUnwrap(store.item(withUUID: item.uuid)).calendarEventID,
            "the event is still in the calendar, so the clip still has one"
        )
    }

    // MARK: - What is read off the clip

    func testTheModelsTitleIsTheFallbackTitle() async throws {
        let store = try makeStore()
        let item = try insert("August 20, 2026 at 3:00 PM", into: store)
        store.applyRefinement(title: "Budget sync", summary: nil, text: nil, tags: [], toClipWith: item.uuid)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))
        XCTAssertEqual(coordinator.event(for: refreshed)?.title, "Budget sync")
    }

    func testAnUntitledClipFallsBackToAGenericName() async throws {
        let store = try makeStore()
        let item = try insert("August 20, 2026 at 3:00 PM", into: store)
        let coordinator = CalendarCoordinator(store: store, sink: FakeEventSink())

        XCTAssertEqual(coordinator.event(for: item)?.title, loc("Event"))
    }

    func testTheRefinedTextIsScannedRatherThanTheRaw() async throws {
        let store = try makeStore()
        let item = try insert("no date at all in the clip's own text", into: store)
        store.applyRefinement(
            title: nil,
            summary: nil,
            text: "Standup on August 20, 2026 at 9:30am",
            tags: [],
            toClipWith: item.uuid
        )

        let coordinator = CalendarCoordinator(store: store, sink: FakeEventSink())
        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))
        XCTAssertNotNil(coordinator.event(for: refreshed), "the cleaned-up text is what the user reads")
    }

    // MARK: - Settings

    func testTheDurationSettingIsWhatAnOpenEndedEventRuns() async throws {
        UserDefaults.standard.set(30, forKey: CalendarSettingsKeys.eventDurationMinutes)
        XCTAssertEqual(CalendarCoordinator.defaultDuration, 1800)

        let store = try makeStore()
        let item = try insert("Standup on August 20, 2026 at 9:30am", into: store)
        let coordinator = CalendarCoordinator(store: store, sink: FakeEventSink())

        XCTAssertEqual(coordinator.event(for: item)?.duration, 1800)
    }

    func testAnUnsetDurationIsAnHour() async throws {
        UserDefaults.standard.removeObject(forKey: CalendarSettingsKeys.eventDurationMinutes)
        XCTAssertEqual(CalendarCoordinator.defaultDuration, 3600)
    }

    func testRegisterDefaultsProducesTheDocumentedDefaults() async throws {
        for key in [
            CalendarSettingsKeys.autoCreate,
            CalendarSettingsKeys.eventDurationMinutes,
            CalendarSettingsKeys.notifyOnAutoCreate,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        CalendarSettingsKeys.registerDefaults()

        XCTAssertFalse(CalendarCoordinator.isAutoCreateEnabled, "automatic creation ships off")
        XCTAssertTrue(CalendarCoordinator.notifiesOnAutoCreate)
        XCTAssertEqual(
            UserDefaults.standard.integer(forKey: CalendarSettingsKeys.eventDurationMinutes),
            60
        )
    }

    // MARK: - Errors

    func testEveryErrorHasItsOwnLogReason() async throws {
        let errors: [CalendarError] = [
            .nothingToSchedule,
            .accessDenied,
            .accessRestricted,
            .noWritableCalendar,
            .saveFailed("something"),
            .removeFailed("something"),
        ]
        var seen: Set<String> = []
        for error in errors {
            let reason = error.logReason
            XCTAssertFalse(reason.isEmpty, "\(error) has no log reason")
            XCTAssertTrue(seen.insert(reason).inserted, "\(reason) is used twice")
            XCTAssertFalse(reason.contains("something"), "\(reason) carries the interpolated detail")
            XCTAssertFalse(error.localizedDescription.isEmpty, "\(error) has no sentence for the user")
        }
    }

    // MARK: - All-day arithmetic

    func testAWholeDayEndsInsideThatDay() async throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))
        let halfOpen = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))

        let end = EventKitSink.inclusiveAllDayEnd(start: start, halfOpenEnd: halfOpen)
        XCTAssertTrue(
            calendar.isDate(end, inSameDayAs: start),
            "EventKit's all-day end is the last day the event is on, not the day after"
        )
        XCTAssertEqual(end.timeIntervalSince(start), 86_399)
    }

    func testAMultiDaySpanEndsOnItsLastDay() async throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))
        let halfOpen = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: start))
        let lastDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: start))

        let end = EventKitSink.inclusiveAllDayEnd(start: start, halfOpenEnd: halfOpen)
        XCTAssertTrue(calendar.isDate(end, inSameDayAs: lastDay))
    }

    func testADegenerateSpanNeverEndsBeforeItStarts() async throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))
        XCTAssertEqual(EventKitSink.inclusiveAllDayEnd(start: start, halfOpenEnd: start), start)
        XCTAssertEqual(
            EventKitSink.inclusiveAllDayEnd(start: start, halfOpenEnd: start.addingTimeInterval(-3600)),
            start
        )
    }

    func testTheDetectorsAllDaySpanConvertsToASingleDay() async throws {
        let event = try XCTUnwrap(
            EventDetector.detect("All hands on August 20, 2026", fallbackTitle: "Untitled", calendar: calendar)
        )
        XCTAssertTrue(event.isAllDay)

        let end = EventKitSink.inclusiveAllDayEnd(start: event.start, halfOpenEnd: event.end)
        XCTAssertTrue(calendar.isDate(end, inSameDayAs: event.start))
    }
}

/// The banner's words, which are the only half of `EventNotifier` a test can
/// reach: everything else needs a notification centre, and asking for one in
/// this process raises rather than returning nil (see `EventNotifier`).
final class EventNotifierTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_787_670_000)

    private func message(isAllDay: Bool = false, locale: Locale = Locale(identifier: "en_GB")) -> EventNotifier.Message {
        EventNotifier.message(
            eventTitle: "Design review",
            start: start,
            isAllDay: isAllDay,
            calendarTitle: "Work",
            locale: locale
        )
    }

    /// The test process is not an app bundle, so nothing here may reach the
    /// notification centre. This is the assertion that says so out loud: if it
    /// ever fails, the delivery half has become reachable from the suite and
    /// the next automatic event crashes it.
    func testTheNotificationCentreIsOutOfReachUnderTest() {
        XCTAssertFalse(EventNotifier.isAvailable)
    }

    func testTheBannerNamesTheEventAndItsCalendar() {
        let message = message()
        XCTAssertEqual(message.title, loc("Added to your %@ calendar", "Work"))
        XCTAssertTrue(message.body.contains("Design review"), message.body)
    }

    func testATimedEventSaysWhatTimeItStarts() {
        let timed = message()
        let allDay = message(isAllDay: true)
        XCTAssertNotEqual(timed.body, allDay.body)
        XCTAssertTrue(timed.body.contains(":"), "a timed event states its clock time: \(timed.body)")
        XCTAssertFalse(allDay.body.contains(":"), "midnight is storage, not a start time: \(allDay.body)")
    }

    /// The date is rendered with the app's locale rather than the system's, so
    /// a French reader does not get an English date inside a French sentence.
    func testTheStartIsFormattedInTheGivenLocale() {
        let english = message(locale: Locale(identifier: "en_GB")).body
        let french = message(locale: Locale(identifier: "fr_FR")).body
        XCTAssertNotEqual(english, french, "the locale is not reaching the date style")
    }

    func testTheActionsAreDistinctlyIdentified() {
        let identifiers = [
            EventNotifier.categoryIdentifier,
            EventNotifier.undoActionIdentifier,
            EventNotifier.openActionIdentifier
        ]
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "two notification identifiers collide")
    }
}
