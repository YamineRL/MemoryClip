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

    /// Whether a request would put a dialog on screen — which the automatic
    /// path is not allowed to do.
    ///
    /// This cannot be `authorizationStatus(for:) == .notDetermined` alone, and
    /// the reason is worth recording because it costs an afternoon to find.
    /// On an ad-hoc-signed build, `requestWriteOnlyAccessToEvents()` returns
    /// **true** and the write genuinely succeeds, while
    /// `authorizationStatus(for: .event)` goes on reporting `.notDetermined`
    /// for the life of the process. Trusting the status alone therefore
    /// produced a loop nobody could escape: every capture decided it had
    /// never asked, declined, and left the user with a switch that was on and
    /// a calendar that stayed empty — while the manual button, which asks the
    /// store directly instead of consulting the status, worked the whole time.
    ///
    /// So the grant is remembered here as well. `false` once anything in this
    /// process has been told yes, whatever TCC says afterwards; the rule that
    /// matters — never raise the first prompt from a background capture — is
    /// unaffected, since a run that has never asked still has the flag clear.
    nonisolated var wouldPromptForAccess: Bool {
        guard !Self.grantedInThisRun.value else { return false }
        return EKEventStore.authorizationStatus(for: .event) == .notDetermined
    }

    /// Set the moment any request comes back granted, and never cleared.
    ///
    /// Locked rather than `nonisolated(unsafe)` because it is written from the
    /// settings pane and read from the capture path, and `nonisolated` so that
    /// read needs no hop to the main actor.
    private nonisolated static let grantedInThisRun = Flag()

    /// Records that access has been granted, from wherever it was asked.
    nonisolated static func noteAccessGranted() {
        grantedInThisRun.set()
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
        Self.noteAccessGranted()
    }

    /// Raise the permission prompt now, from a place the user just clicked.
    ///
    /// Turning automatic creation on is the only moment this can be asked
    /// well. The automatic path itself refuses to prompt — a dialog raised by
    /// a background sweep arrives with nothing on screen to explain it — so
    /// without this the switch would go on, nothing would ever happen, and
    /// there would be no way to find out why: a decline while access is
    /// `.notDetermined` looks exactly like a clip that named no date.
    ///
    /// Ignores its own outcome. A refusal is recorded by macOS and surfaces
    /// as `accessDenied` the first time the button is used, which is where
    /// the alert and its Open Settings button are.
    static func primeAccess() async {
        // The remembered grant is checked first, and not only as an
        // optimisation: the status can stay `.notDetermined` after a
        // successful grant, so without this the pane would raise the dialog
        // again every time it was opened.
        guard !grantedInThisRun.value,
              EKEventStore.authorizationStatus(for: .event) == .notDetermined
        else { return }

        let granted = (try? await EKEventStore().requestWriteOnlyAccessToEvents()) ?? false
        if granted { noteAccessGranted() }
        log.notice("""
            Calendar access prompt answered: \(granted ? "granted" : "refused", privacy: .public) \
            (status now \(EKEventStore.authorizationStatus(for: .event).rawValue, privacy: .public))
            """)
    }

    /// What the calendar grant is right now, in terms the settings UI can act
    /// on without importing EventKit.
    ///
    /// This exists because the automatic path can only ever *decline* when
    /// permission is missing — it must not raise a prompt of its own — and a
    /// silent decline is indistinguishable from "that clip had no date in
    /// it". Somewhere has to say so out loud, and the pane holding the switch
    /// is the only place the user is looking.
    nonisolated static var access: CalendarAccess {
        // The remembered grant outranks the status for the reason
        // `wouldPromptForAccess` documents: the status can stay
        // `.notDetermined` after a request that genuinely succeeded, and a
        // warning telling someone to grant access they have already granted
        // is worse than no warning at all.
        if grantedInThisRun.value { return .granted }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notAsked
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess, .writeOnly: return .granted
        @unknown default: return .notAsked
        }
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

/// A set-once boolean that crosses actors. Smaller than an actor and usable
/// from a `nonisolated` getter, which is what the access flag needs.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    func set() {
        lock.lock()
        raised = true
        lock.unlock()
    }
}
