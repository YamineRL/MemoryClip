import Foundation

/// An event `EventDetector` read out of a clip's text: when it is, where it is,
/// and what to call it.
///
/// A value type with no model or store reference, so it crosses actors freely —
/// the detector runs nonisolated, the sink that writes it is `@MainActor`.
/// Deliberately not an `EKEvent`: EventKit types are class-bound, tied to a
/// live `EKEventStore`, and untestable without calendar permission, whereas
/// this is comparable, printable and constructible in a unit test.
struct DetectedEvent: Sendable, Equatable {
    /// What the event will be called. Never empty — the detector falls back to
    /// a generic title rather than emitting a nameless event.
    var title: String

    /// When it starts. For an all-day event this is the start of that day in
    /// `timeZone` (or the current zone when the text named none).
    var start: Date

    /// When it ends: the end the text gave, else `start` plus the caller's
    /// default duration. Always strictly after `start`.
    var end: Date

    /// Whether the text named a day but no clock time.
    var isAllDay: Bool

    /// A postal address found in the text, rendered as one line.
    var location: String?

    /// A video-call link — Zoom, Meet, Teams and friends. Distinct from any
    /// other URL in the clip: only a recognised conferencing host counts.
    var meetingURL: URL?

    /// The zone the text named, when it named one. `nil` means the event is
    /// in whatever zone the Mac is in, which is the common case.
    var timeZone: TimeZone?

    /// Whether this is corroborated enough to create without being asked.
    ///
    /// True only when the text gave a *clock time* and at least one of a
    /// meeting link or an address. The automatic setting keys off this and
    /// nothing else: a bare date in a paragraph — "Q3 ends September 30", a
    /// news article, an expiry notice — is a date, not an appointment, and
    /// silently turning every one of them into a calendar entry would make the
    /// feature something you switch off rather than something you rely on.
    /// The manual button has no such requirement; a human pressing it has
    /// already made the judgement this flag is standing in for.
    var isStrongSignal: Bool

    /// The interval the event occupies.
    var duration: TimeInterval { end.timeIntervalSince(start) }
}
