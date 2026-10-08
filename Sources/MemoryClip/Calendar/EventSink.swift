import Foundation

/// What a sink hands back after creating an event.
///
/// `eventIdentifier` is stored on the clip as `ClipItem.calendarEventID`,
/// which is what tells the panel this clip already has an event. It is
/// EventKit's identifier and nothing else is derived from it here — see
/// `EventKitSink` for why it can be recorded but not looked up again.
struct EventReceipt: Sendable, Equatable {
    /// EventKit's identifier for the created event.
    let eventIdentifier: String
    /// The calendar it landed in, for the confirmation the user is shown —
    /// "Added to Work" is the only way they can tell it went somewhere they
    /// expected, given nothing here lets them choose.
    let calendarTitle: String
    /// When the event starts, so the confirmation can say the date back
    /// without the caller re-reading the clip.
    let start: Date
}

/// One place an event can be created.
///
/// Deliberately narrow, exactly as `NoteSink` is: a sink takes a finished
/// `DetectedEvent` — a `Sendable` value the coordinator has already flattened
/// off the model — and returns where it put it. It never sees `ClipItem`, a
/// `ModelContext` or the pasteboard.
///
/// `async` because the real conformer genuinely is: the first save has to
/// await the TCC prompt. Every failure is a `CalendarError`, so the UI has one
/// thing to catch and one sentence to show.
protocol EventSink: Sendable {
    /// Whether the next `save` would put a permission dialog on screen.
    ///
    /// Asked by the automatic path and by nothing else. A prompt is a modal
    /// interruption the user has to answer, and one raised by a background
    /// sweep arrives with nothing on screen explaining what asked for it —
    /// the hazard `NotesAppSink`'s header records for the Automation grant.
    /// So automatic creation declines while this is true and leaves the first
    /// prompt to the panel's button, which a human pressed.
    ///
    /// Defaulted to false because a sink that needs no grant can never
    /// prompt, which is every sink but the EventKit one.
    var wouldPromptForAccess: Bool { get }

    /// Whether a `save` could ever succeed. Asked by the offer path: an
    /// offer whose only answer leads to a certain failure is a dead button,
    /// so access that is refused outright — denied or restricted — means the
    /// offer is not made. A never-asked state does NOT block: the offer's
    /// Add button is a user action, and the first prompt is allowed to
    /// belong to it.
    ///
    /// Defaulted to true: only the EventKit sink can be refused at all.
    var canReachCalendar: Bool { get }

    /// Create `event` in the user's default calendar, as the creation
    /// `operation` names it.
    ///
    /// The operation identifier is the undo handle: write-only access means
    /// the event can never be looked up again, so the in-memory `EKEvent` is
    /// keyed by the operation the caller minted — which is what lets undo
    /// later say WHICH creation it is retracting instead of merely "the last
    /// one".
    func save(_ event: DetectedEvent, operation: UUID) async throws -> EventReceipt

    /// Remove the event created by `operation`, if this sink still holds it.
    ///
    /// Returns false when the sink holds nothing for that operation — the
    /// event was created by a previous run of the app (undo cannot outlive
    /// the process that created it; see `EventKitSink`'s write-only note)
    /// or was already undone. The caller reports that rather than claiming
    /// an undo nothing performed.
    func removeSaved(_ operation: UUID) async throws -> Bool
}

extension EventSink {
    var wouldPromptForAccess: Bool { false }
    var canReachCalendar: Bool { true }
}
