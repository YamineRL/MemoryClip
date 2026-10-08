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
    /// Every event handed to `save`, keyed by its creation operation — the
    /// same identity the real sink keys its `EKEvent`s by.
    private(set) var saved: [UUID: DetectedEvent] = [:]
    /// Operation ids undo asked to remove, in order.
    private(set) var removed: [UUID] = []

    /// Thrown instead of saving, to drive the failure paths.
    var saveError: CalendarError?
    var removeError: CalendarError?

    /// Set once `save` is entered — lets a test hold a creation open so a
    /// second one can race it.
    private(set) var saveEntered = false
    /// Runs inside `save`, before the receipt is built.
    var onSave: (@MainActor () async throws -> Void)?

    var calendarTitle = "Work"

    /// What the offer path asks before it offers at all. The real one
    /// answers from TCC; this one is set by the test that cares.
    ///
    /// `nonisolated(unsafe)` because the protocol requirement is not
    /// main-actor bound while this class is. Every test that touches it runs
    /// on the main actor, and nothing else reads it.
    nonisolated(unsafe) var wouldPromptForAccess = false

    /// Whether a save could ever succeed — the gate on the offer. False
    /// stands in for a denied or restricted grant.
    nonisolated(unsafe) var canReachCalendar = true

    @MainActor
    func save(_ event: DetectedEvent, operation: UUID) async throws -> EventReceipt {
        saveEntered = true
        if let onSave { try await onSave() }
        if let saveError { throw saveError }
        saved[operation] = event
        return EventReceipt(
            eventIdentifier: "event-\(saved.count)",
            calendarTitle: calendarTitle,
            start: event.start
        )
    }

    @MainActor
    func removeSaved(_ operation: UUID) async throws -> Bool {
        if let removeError { throw removeError }
        removed.append(operation)
        return saved.removeValue(forKey: operation) != nil
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
        XCTAssertEqual(sink.saved.values.first?.title, "Design review")
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

    func testAStrongSignalClipIsOffered() async throws {
        UserDefaults.standard.set(true, forKey: CalendarSettingsKeys.autoCreate)
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        let offered = await coordinator.offerIfWanted(for: item)

        XCTAssertNotNil(offered, "a timed invitation with a meeting link is what the setting is for")
        XCTAssertTrue(sink.saved.isEmpty, "an offer is not a save — the sink is never reached")
        XCTAssertNil(try XCTUnwrap(store.item(withUUID: item.uuid)).calendarEventID)
    }

    func testAWeakSignalClipIsLeftAlone() async throws {
        UserDefaults.standard.set(true, forKey: CalendarSettingsKeys.autoCreate)
        let store = try makeStore()
        let item = try insert(Self.bareDate, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        // The date is real — the manual button would have scheduled it.
        XCTAssertNotNil(coordinator.event(for: item))

        let offered = await coordinator.offerIfWanted(for: item)

        XCTAssertNil(offered, "a bare date is a date, not an appointment")
        XCTAssertTrue(sink.saved.isEmpty)
        XCTAssertNil(try XCTUnwrap(store.item(withUUID: item.uuid)).calendarEventID)
    }

    func testNothingIsOfferedWhileTheSettingIsOff() async throws {
        UserDefaults.standard.set(false, forKey: CalendarSettingsKeys.autoCreate)
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        let offered = await coordinator.offerIfWanted(for: item)

        XCTAssertNil(offered)
        XCTAssertTrue(sink.saved.isEmpty, "the sink must not be reached at all")
    }

    func testAClipThatAlreadyHasAnEventIsNotOfferedTwice() async throws {
        UserDefaults.standard.set(true, forKey: CalendarSettingsKeys.autoCreate)
        UserDefaults.standard.set(false, forKey: CalendarSettingsKeys.notifyOnAutoCreate)
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        _ = await coordinator.addEvent(for: item)
        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))

        let offered = await coordinator.offerIfWanted(for: refreshed)

        XCTAssertNil(offered)
        XCTAssertEqual(sink.saved.count, 1, "the appointment is in the calendar once")
    }

    /// A refused grant means Add could only ever fail, so the offer — a dead
    /// button — is not made. A never-asked sink still gets the offer: the
    /// first TCC prompt is allowed to belong to the button the user pressed.
    func testARefusedSinkSuppressesTheOfferButAnUnaskedOneStillGetsIt() async throws {
        UserDefaults.standard.set(true, forKey: CalendarSettingsKeys.autoCreate)
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        sink.canReachCalendar = false
        let refused = await coordinator.offerIfWanted(for: item)
        XCTAssertNil(refused, "denied access is a dead Add button — do not ask")

        sink.canReachCalendar = true
        sink.wouldPromptForAccess = true
        let asked = await coordinator.offerIfWanted(for: item)
        XCTAssertNotNil(asked, "never-asked can still be asked — by the button, not the capture")
        XCTAssertTrue(sink.saved.isEmpty)
    }

    func testABatchOnlyOffersTheClipsItNames() async throws {
        UserDefaults.standard.set(true, forKey: CalendarSettingsKeys.autoCreate)
        let store = try makeStore()
        let named = try insert(Self.invitation, into: store)
        _ = try insert(
            """
            Retro
            August 21, 2026 at 11:00 AM – 11:30 AM
            Zoom: https://us02web.zoom.us/j/89123456780
            """,
            into: store
        )
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        let offered = await coordinator.offerIfWanted(forClipsWith: [named.uuid])

        XCTAssertEqual(offered, [named.uuid])
        XCTAssertTrue(sink.saved.isEmpty, "offers never touch the sink")
    }

    // MARK: - Accepting an offer

    /// The offer's Add button — a save by clip uuid, through the same
    /// machinery the panel's button uses.
    func testAcceptingAnOfferCreatesTheEvent() async throws {
        UserDefaults.standard.set(false, forKey: CalendarSettingsKeys.notifyOnAutoCreate)
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        guard case .success(let receipt) = await coordinator.acceptOfferedEvent(forClipWith: item.uuid) else {
            return XCTFail("the offer's yes should create the event")
        }

        XCTAssertEqual(sink.saved.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(store.item(withUUID: item.uuid)).calendarEventID,
            receipt.eventIdentifier
        )
    }

    /// A banner can outlive the clip it offered. The answer is an error the
    /// delegate can ignore, not a crash or a silent event.
    func testAcceptingAnOfferForAGoneClipFails() async throws {
        let store = try makeStore()
        let coordinator = CalendarCoordinator(store: store, sink: FakeEventSink())

        guard case .failure(let error) = await coordinator.acceptOfferedEvent(forClipWith: UUID()) else {
            return XCTFail("no clip must not become an event")
        }
        XCTAssertEqual(error, .nothingToSchedule)
    }

    /// Edit's half: the offer hands the detection to whoever opens the .ics.
    func testTheOfferedEventIsReadableForEditing() async throws {
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let coordinator = CalendarCoordinator(store: store, sink: FakeEventSink())

        let detected = try XCTUnwrap(coordinator.detectedEvent(forClipWith: item.uuid))
        XCTAssertEqual(detected.title, "Design review")
        XCTAssertNotNil(detected.meetingURL)

        XCTAssertNil(
            coordinator.detectedEvent(forClipWith: UUID()),
            "a clip that no longer exists has no offer to edit"
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

        XCTAssertEqual(sink.removed.count, 1)
        XCTAssertTrue(sink.saved.isEmpty)
        XCTAssertNil(try XCTUnwrap(store.item(withUUID: item.uuid)).calendarEventID)
    }

    /// Nothing standing to undo is `.undoUnavailable`, not a claimed success:
    /// a "success" that touched nothing is exactly the lie notification-undo
    /// exists to stop telling.
    func testUndoWithNothingCreatedReportsUnavailable() async throws {
        let store = try makeStore()
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        guard case .failure(let error) = await coordinator.undoLastEvent() else {
            return XCTFail("nothing to undo must not claim success")
        }
        XCTAssertEqual(error, .undoUnavailable)
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

    /// P2.5's acceptance case: two clips, two events, and Undo on the FIRST
    /// one's notification must remove the first one's event — not whichever
    /// was created last, which is the bug operation identity fixes.
    func testUndoRemovesTheOperationItNamesNotTheLast() async throws {
        let store = try makeStore()
        let first = try insert("Design review August 20, 2026 at 3:00 PM", into: store)
        let second = try insert("Dentist August 21, 2026 at 9:00 AM", into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        _ = await coordinator.addEvent(for: first)
        _ = await coordinator.addEvent(for: second)
        let firstOperation = try XCTUnwrap(coordinator.operationID(forClipWith: first.uuid))
        let secondOperation = try XCTUnwrap(coordinator.operationID(forClipWith: second.uuid))

        guard case .success = await coordinator.undoEvent(firstOperation) else {
            return XCTFail("undoing the first event failed")
        }

        XCTAssertEqual(sink.removed, [firstOperation],
                       "undo must name the creation it retracts")
        XCTAssertNotNil(sink.saved[secondOperation],
                        "the second event is untouched")
        XCTAssertNil(try XCTUnwrap(store.item(withUUID: first.uuid)).calendarEventID)
        XCTAssertNotNil(try XCTUnwrap(store.item(withUUID: second.uuid)).calendarEventID)
    }

    /// An operation this run does not know — a notification for an event
    /// created before launch, or already undone — reports unavailable, never
    /// success. Claiming otherwise is how "Undo" lies.
    func testUndoOfAnUnknownOperationReportsUnavailable() async throws {
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        _ = await coordinator.addEvent(for: item)

        guard case .failure(let error) = await coordinator.undoEvent(UUID()) else {
            return XCTFail("an unknown operation must not claim success")
        }
        XCTAssertEqual(error, .undoUnavailable)
    }

    /// P2.6: a second `addEvent` for a clip whose first creation is still
    /// inside `sink.save` must be declined — the check-then-await window is
    /// exactly where a duplicate used to enter.
    func testAConcurrentAddForTheSameClipIsDeclined() async throws {
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        sink.onSave = { try? await Task.sleep(for: .milliseconds(200)) }
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        let firstResult = Task { @MainActor in await coordinator.addEvent(for: item) }
        while !sink.saveEntered { await Task.yield() }

        guard case .failure(let error) = await coordinator.addEvent(for: item) else {
            return XCTFail("a racing add must not become a second event")
        }
        XCTAssertEqual(error, .alreadyInFlight)
        _ = await firstResult.value

        XCTAssertEqual(sink.saved.count, 1, "one clip, one event — the race produced no duplicate")
    }

    /// The clip moved on while the event was being created — edited, in
    /// this case. The created event describes content that is gone, so the
    /// honest move is to un-create it, not to record it or to leave it
    /// orphaned in the calendar.
    func testAClipChangedMidSaveUnCreatesTheEvent() async throws {
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        sink.onSave = { [uuid = item.uuid] in
            guard let live = store.item(withUUID: uuid) else { return }
            _ = store.applyEdit(live, newText: "edited, no date")
        }

        guard case .failure(let error) = await coordinator.addEvent(for: item) else {
            return XCTFail("a stale write-back must not record the event")
        }
        XCTAssertEqual(error, .clipChangedDuringSave)
        XCTAssertTrue(sink.saved.isEmpty, "the orphaned event was removed")
        XCTAssertEqual(sink.removed.count, 1)
        XCTAssertNil(try XCTUnwrap(store.item(withUUID: item.uuid)).calendarEventID)
    }

    /// Same recovery, harder case: the clip was deleted outright while the
    /// save was in flight. Nothing may be left standing.
    func testAClipDeletedMidSaveUnCreatesTheEvent() async throws {
        let store = try makeStore()
        let item = try insert(Self.invitation, into: store)
        let sink = FakeEventSink()
        let coordinator = CalendarCoordinator(store: store, sink: sink)

        sink.onSave = { [uuid = item.uuid] in
            guard let live = store.item(withUUID: uuid) else { return }
            store.delete(live)
        }

        guard case .failure(let error) = await coordinator.addEvent(for: item) else {
            return XCTFail("a deleted clip must not keep the event")
        }
        XCTAssertEqual(error, .clipChangedDuringSave)
        XCTAssertTrue(sink.saved.isEmpty)
        XCTAssertEqual(sink.removed.count, 1)
    }

    // MARK: - What is read off the clip

    func testTheModelsTitleIsTheFallbackTitle() async throws {
        let store = try makeStore()
        let item = try insert("August 20, 2026 at 3:00 PM", into: store)
        store.applyRefinement(title: "Budget sync", summary: nil, text: nil, tags: [], toClipWith: item.uuid, revision: 0)
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
            toClipWith: item.uuid,
            revision: 0
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

        XCTAssertFalse(CalendarCoordinator.isOfferEnabled, "event suggestions ship off")
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

    /// The offer's banner asks rather than announces — it shares the event
    /// line but the title is a question, because nothing exists yet.
    func testTheOfferAsksRatherThanAnnouncing() {
        let offer = EventNotifier.offerMessage(
            eventTitle: "Design review",
            start: start,
            isAllDay: false,
            locale: Locale(identifier: "en_GB")
        )
        XCTAssertEqual(offer.title, loc("Add this event to your calendar?"))
        XCTAssertTrue(offer.body.contains("Design review"), offer.body)
        XCTAssertFalse(offer.title.hasPrefix("Added"), "past tense claims a save that has not happened")
    }

    func testTheActionsAreDistinctlyIdentified() {
        let identifiers = [
            EventNotifier.categoryIdentifier,
            EventNotifier.undoActionIdentifier,
            EventNotifier.openActionIdentifier,
            EventNotifier.offerCategoryIdentifier,
            EventNotifier.addActionIdentifier,
            EventNotifier.editActionIdentifier,
            EventNotifier.declineActionIdentifier,
        ]
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "two notification identifiers collide")
    }
}
