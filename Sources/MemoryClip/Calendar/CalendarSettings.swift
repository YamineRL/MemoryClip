import Foundation

/// Every UserDefaults key for the clip → calendar path.
///
/// Collected here rather than beside their readers for the reason
/// `NoteSettingsKeys` is: the feature spans detection, the sink and the
/// Settings pane, and a key defined next to one of those is a key the other
/// two have to guess at.
enum CalendarSettingsKeys {
    /// Whether a clip that reads as an appointment creates its event without
    /// being asked. Only a `DetectedEvent.isStrongSignal` clip ever qualifies.
    static let autoCreate = "calendarAutoCreate"
    /// How long an event runs when the text named a start but no end.
    static let eventDurationMinutes = "calendarEventDurationMinutes"
    /// Whether an event created automatically says so. Separate from
    /// `autoCreate` because something that writes to a calendar behind the
    /// user's back is only acceptable while it keeps announcing that it did.
    static let notifyOnAutoCreate = "calendarNotifyOnAutoCreate"

    /// Registered at launch. Automatic creation is OFF: writing to a calendar
    /// is not a thing to start doing for someone who has not heard of the
    /// feature, and the button on the clip is the way in. The notification is
    /// ON, so that switching automatic creation on cannot make events appear
    /// silently — the one default here that only matters once another one has
    /// been changed.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoCreate: false,
            eventDurationMinutes: 60,
            notifyOnAutoCreate: true,
        ])
    }
}

/// Failures adding a clip to the calendar can hit that the user has to be told
/// about.
/// The calendar grant, as the settings UI needs to talk about it.
///
/// Deliberately not `EKAuthorizationStatus`: the UI only cares whether events
/// can be written and, when they cannot, whether asking again would help.
enum CalendarAccess: Sendable, Equatable {
    /// Never asked. A prompt would appear, and only a user action may raise it.
    case notAsked
    /// Write-only or full access — either can create an event.
    case granted
    /// Refused. macOS will not prompt again; only System Settings can undo it.
    case denied
    /// Blocked by a profile or Screen Time. Nothing the user can do here.
    case restricted

    /// Whether automatic creation can actually happen.
    var canCreateEvents: Bool { self == .granted }
}

enum CalendarError: LocalizedError, Equatable {
    case nothingToSchedule
    case accessDenied
    case accessRestricted
    case noWritableCalendar
    case saveFailed(String)
    case removeFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingToSchedule:
            return loc("There is no date in this clip to put in the calendar.")
        case .accessDenied:
            // Names System Settings because macOS remembers a denial and never
            // asks again: there is nothing MemoryClip can do to re-prompt, so
            // a sentence that only said "permission is needed" would leave the
            // user with no move to make.
            return loc("MemoryClip needs permission to add events to your calendar. Allow it in System Settings → Privacy & Security → Calendars.")
        case .accessRestricted:
            return loc("Calendar access is turned off on this Mac by a profile or by Screen Time, so MemoryClip cannot add the event.")
        case .noWritableCalendar:
            return loc("There is no calendar to add the event to. Open Calendar and choose a default calendar for new events.")
        case .saveFailed(let reason):
            return loc("The event could not be saved: %@", reason)
        case .removeFailed(let reason):
            return loc("The event could not be removed: %@", reason)
        }
    }

    /// What the log is allowed to say out loud about this failure.
    ///
    /// Same split as `NoteError.logReason`, for the same reason: the unified
    /// log outlives the app's own "Clear All History", and the two failed
    /// cases interpolate an EventKit message that can name a calendar — which
    /// is to say the user's employer, or their doctor. This names the kind of
    /// failure and carries nothing of theirs.
    ///
    /// Exhaustive rather than a `default`, so a new case has to decide what it
    /// is called here instead of quietly inheriting "unknown".
    var logReason: String {
        switch self {
        case .nothingToSchedule:
            return "nothing to schedule"
        case .accessDenied:
            return "calendar permission denied"
        case .accessRestricted:
            return "calendar access restricted"
        case .noWritableCalendar:
            return "no writable calendar"
        case .saveFailed:
            return "event save failed"
        case .removeFailed:
            return "event removal failed"
        }
    }
}
