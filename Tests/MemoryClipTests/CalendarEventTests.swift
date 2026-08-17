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
