import EventKit
import Foundation

/// Creates the event in the user's calendar, through EventKit.
///
/// # Write-only, and what that costs
///
/// Access is requested with `requestWriteOnlyAccessToEvents()`, not with full
/// access. Creating an event needs nothing more, and the grant the user is
/// asked for should be the grant the feature uses — an app that reads a
/// calendar it has no reason to read is exactly what the prompt exists to warn
/// about.
///
/// The price is that this sink can never *fetch*. `event(withIdentifier:)`, a
/// predicate, `calendars(for:)` — every read on `EKEventStore` requires full
/// access and comes back empty or throwing under a write-only grant. Three
/// things follow, and all three are deliberate:
///
/// - There is no calendar picker. The event goes to
///   `defaultCalendarForNewEvents`, because listing the alternatives is a
///   read. When that is nil there is genuinely nowhere to write, which is
///   `CalendarError.noWritableCalendar`.
/// - Undo is `removeLastSaved()` rather than "remove event X": the only handle
///   left is the `EKEvent` object this sink built, kept in `lastSaved`.
/// - That handle lives in memory, so **undo spans the current run of the app
///   only**. Quit MemoryClip and the event stays where it is, to be deleted in
///   Calendar like any other. The clip still records its identifier, which is
///   what marks the clip as scheduled; it is not something this layer can
///   resolve back to an event.
///
/// # Why a class, and why the main actor
///
/// It holds two pieces of state — the store and the last event — so it cannot
/// be the `struct` the note sinks are. `@MainActor` because the first `save`
/// puts the TCC prompt on screen, and because `EKEvent` is a mutable reference
/// type that would otherwise have to be `Sendable` to be held at all.
@MainActor
final class EventKitSink: EventSink {
    private let store = EKEventStore()

    /// The event created by the last successful `save`, and the only thing
    /// undo can act on. See the write-only note above.
    private var lastSaved: EKEvent?

    // MARK: - EventSink

    /// True exactly while the user has never been asked.
    ///
    /// `.notDetermined` is the one status whose `requestAccess` puts a dialog
    /// on screen; every other status answers from what macOS already recorded,
    /// which is why the denied and restricted cases below can be turned into
    /// errors without a second prompt attempt.
    ///
    /// `nonisolated` because `authorizationStatus(for:)` is a static read of
    /// TCC state that touches nothing this class holds, and because the
    /// protocol requirement it satisfies is not main-actor bound.
    nonisolated var wouldPromptForAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .notDetermined
    }

    @MainActor
    func save(_ event: DetectedEvent) async throws -> EventReceipt {
        try await requestAccess()

        guard let calendar = store.defaultCalendarForNewEvents else {
            throw CalendarError.noWritableCalendar
        }

        let created = Self.makeEvent(for: event, in: calendar, store: store)
        do {
            try store.save(created, span: .thisEvent, commit: true)
        } catch {
            throw CalendarError.saveFailed(error.localizedDescription)
        }
        lastSaved = created

        log.notice("Created a calendar event")
        return EventReceipt(
            eventIdentifier: created.eventIdentifier ?? "",
            calendarTitle: calendar.title,
            start: created.startDate
        )
    }

    @MainActor
    func removeLastSaved() async throws {
        // Nothing held means nothing this sink can reach: either no event has
        // been created in this run, or one has already been undone. Neither is
        // a failure to report — there is simply nothing left to do.
        guard let event = lastSaved else { return }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarError.removeFailed(error.localizedDescription)
        }
        lastSaved = nil
        log.notice("Removed the last calendar event MemoryClip created")
    }

    // MARK: - Access

    /// Ask for write-only access, mapping the two states a prompt cannot fix
    /// onto their own errors.
    ///
    /// The status is read first because macOS does not re-prompt after a
    /// denial: `requestWriteOnlyAccessToEvents()` on a denied store returns
    /// false immediately, and "the user said no once" and "the user just said
    /// no" deserve the same sentence but not a second dialog attempt.
    private func requestAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied:
            throw CalendarError.accessDenied
        case .restricted:
            throw CalendarError.accessRestricted
        default:
            break
        }

        let granted: Bool
        do {
            granted = try await store.requestWriteOnlyAccessToEvents()
        } catch {
            throw CalendarError.saveFailed(error.localizedDescription)
        }
        guard granted else { throw CalendarError.accessDenied }
    }

    // MARK: - Building the event

    /// The `EKEvent` for a detected appointment.
    ///
    /// `structuredLocation` rather than `location`: a plain string is shown
    /// but not resolved, and the structured form is what lets Calendar offer
    /// travel time and a map for an address the detector already found.
    ///
    /// The meeting link is written twice on purpose. `url` is the field
    /// Calendar's own "Join" button reads, and the note is what every other
    /// client — a phone's lock screen, a third-party app, a printed agenda —
    /// shows instead, where it is at least tappable text.
    ///
    /// `timeZone` is set only when the text named one. Leaving it nil means
    /// "whatever zone this Mac is in", which is right for the common case and
    /// wrong to overwrite with a guess.
    private static func makeEvent(
        for event: DetectedEvent,
        in calendar: EKCalendar,
        store: EKEventStore
    ) -> EKEvent {
        let created = EKEvent(eventStore: store)
        created.calendar = calendar
        created.title = event.title
        created.startDate = event.start
        created.endDate = event.isAllDay
            ? inclusiveAllDayEnd(start: event.start, halfOpenEnd: event.end)
            : event.end
        created.isAllDay = event.isAllDay
        if let zone = event.timeZone { created.timeZone = zone }
        created.url = event.meetingURL
        if let location = event.location {
            created.structuredLocation = EKStructuredLocation(title: location)
        }
        if let meetingURL = event.meetingURL {
            created.notes = loc("Join: %@", meetingURL.absoluteString)
        }
        return created
    }

    /// EventKit's all-day end date for a half-open interval.
    ///
    /// The two conventions disagree, and getting it wrong is invisible until
    /// someone looks at their calendar: `DetectedEvent.end` for an all-day
    /// event is the start of the FOLLOWING day, while EventKit's `endDate` is
    /// the last day the event is ON. Handing EventKit the half-open end books
    /// a one-day event across two days, every time.
    ///
    /// A second before the boundary lands inside the last day whatever the
    /// zone and whatever the calendar, which the start of that day —
    /// arithmetic needing a `Calendar` this sink would have to guess at — does
    /// not. Clamped to `start` so a malformed span cannot produce an event
    /// that ends before it begins.
    ///
    /// Static and taking only dates so it is testable without an
    /// `EKEventStore`, which is to say without calendar permission.
    static func inclusiveAllDayEnd(start: Date, halfOpenEnd: Date) -> Date {
        max(start, halfOpenEnd.addingTimeInterval(-1))
    }
}
