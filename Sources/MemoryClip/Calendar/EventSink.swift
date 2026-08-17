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
    /// Create `event` in the user's default calendar.
    func save(_ event: DetectedEvent) async throws -> EventReceipt

    /// Remove the event this sink created last, if it still holds it.
    ///
    /// Takes no identifier on purpose. MemoryClip asks for **write-only**
    /// calendar access, which grants creating events and nothing else: a
    /// lookup by identifier, or any predicate query, needs full access and is
    /// not available here at any price. So the only handle on a created event
    /// is the object the sink made, held in memory — which is what "the last
    /// one" means, and why undo cannot outlive the run of the app that did the
    /// creating.
    func removeLastSaved() async throws
}
