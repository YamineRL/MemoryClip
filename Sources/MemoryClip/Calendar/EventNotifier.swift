import AppKit
import UserNotifications

/// The banner an automatically created event announces itself with, and the
/// two buttons on it.
///
/// # Nothing here may run without a bundle
///
/// `UNUserNotificationCenter.current()` does not fail politely in a process
/// that is not an application bundle — it raises, taking the process with it.
/// Under `swift test` and `swift run` there is no `Info.plist` of MemoryClip's
/// (the same condition `AppVersionInfo` documents for the About pane), so
/// every entry point below opens with `isAvailable` and every test in the
/// suite would otherwise be one automatic event away from a crash rather than
/// a failure.
///
/// That is also why the shape is split: `message(...)` is a pure function of
/// its arguments, returning the two lines the banner shows, and is what the
/// tests exercise. `post(...)` is the delivery half, and is inert — a silent
/// early return — anywhere the notification centre cannot be reached.
///
/// # Permission
///
/// Authorization is requested at the first *post*, not at launch. A menu-bar
/// app that asks to send notifications before it has anything to say is asking
/// the user to answer a question they have no way to judge; asked at the
/// moment MemoryClip has actually put something in a calendar, the question
/// answers itself. `.alert` only: nothing here is worth a sound or a red dot
/// on an app icon that does not exist.
///
/// A denial is final and silent. The event is still in the calendar and the
/// clip still says `· in calendar` in the panel, which is the same information
/// arriving somewhere the user chose to look.
enum EventNotifier {
    /// The category the two actions hang off, named on every request so the
    /// buttons appear on the banner.
    static let categoryIdentifier = "app.memoryclip.calendarEvent"
    /// Removes the event again — `CalendarCoordinator.undoLastEvent()`.
    static let undoActionIdentifier = "app.memoryclip.calendarEvent.undo"
    /// Brings up Calendar so the user can see what landed.
    static let openActionIdentifier = "app.memoryclip.calendarEvent.open"

    /// The two lines of the banner.
    struct Message: Equatable {
        let title: String
        let body: String
    }

    /// Whether this process can talk to the notification centre at all.
    ///
    /// See the header: `current()` traps rather than returning nil, so this is
    /// not an optimisation, it is the guard that keeps the test suite alive.
    ///
    /// Both halves are load-bearing. A missing bundle identifier is the
    /// obvious case, but it is not the one the test suite is in: `xctest`
    /// injects `com.apple.dt.xctest.tool` into the info dictionary of a
    /// *directory* — `/Applications/Xcode.app/Contents/Developer/usr/bin` —
    /// so the identifier is there while the bundle behind it is not, and
    /// `current()` raises `bundleProxyForCurrentProcess is nil` on the spot.
    /// Requiring the main bundle to actually be an `.app` is what tells the
    /// built application apart from every other way this code can be loaded.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - What it says

    /// The banner text for one created event.
    ///
    /// Pure, and taking values rather than an `EventReceipt`, so it is
    /// testable without a notification centre, without EventKit and without a
    /// bundle — which between them is everything this function would otherwise
    /// need to be exercised at all.
    ///
    /// The start is rendered through a `Date.FormatStyle` carrying the app's
    /// own locale rather than the system's: MemoryClip's language is resolved
    /// against the catalogue it ships (see `L10n`), so a French user reading
    /// French strings must not get an English date in the middle of one. The
    /// style, not a format string, because the order of day, month and time —
    /// and the word between them — differs per locale and is not ours to
    /// guess.
    ///
    /// An all-day event drops the time entirely and spells the day out: "at
    /// 00:00" is not when it starts, it is an artefact of how midnight is
    /// stored.
    static func message(
        eventTitle: String,
        start: Date,
        isAllDay: Bool,
        calendarTitle: String,
        locale: Locale = L10n.locale
    ) -> Message {
        let when = isAllDay
            ? start.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(locale))
            : start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        return Message(
            title: loc("Added to your %@ calendar", calendarTitle),
            body: loc("%@ — %@", eventTitle, when)
        )
    }

    // MARK: - Delivery

    /// Register the category and take delivery of taps.
    ///
    /// Called once at launch. The centre holds its delegate weakly, so the
    /// caller has to keep `delegate` alive for as long as the app runs —
    /// `AppDelegate` does, in a stored property.
    @MainActor
    static func install(delegate: any UNUserNotificationCenterDelegate) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([category])
    }

    /// Announce one created event, if the user will have it.
    ///
    /// Every failure here is silent on purpose: an event that could not be
    /// announced is still an event, and there is no window open to complain
    /// in when this runs.
    @MainActor
    static func post(eventTitle: String, start: Date, isAllDay: Bool, calendarTitle: String) async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        guard await isAuthorized(center) else { return }

        let text = message(
            eventTitle: eventTitle,
            start: start,
            isAllDay: isAllDay,
            calendarTitle: calendarTitle
        )
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = categoryIdentifier

        // No trigger: deliver now. A fresh identifier every time, so two
        // events created in one burst are two banners rather than one
        // replacing the other.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            log.error("Calendar notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ask for permission, or confirm we already have it.
    ///
    /// `requestAuthorization` is the whole check: after the first answer it
    /// returns what macOS recorded without prompting again, so this can be
    /// called on every post without the user ever seeing a second dialog.
    @MainActor
    private static func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert])
        } catch {
            log.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Undo, and a way to go and look.
    ///
    /// Undo is not `.destructive`: red is for what you cannot take back, and
    /// this button is the taking back. Opening Calendar is `.foreground`
    /// because it activates another app.
    private static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(identifier: undoActionIdentifier, title: loc("Undo"), options: []),
                UNNotificationAction(
                    identifier: openActionIdentifier,
                    title: loc("Open in Calendar"),
                    options: [.foreground]
                )
            ],
            intentIdentifiers: [],
            options: []
        )
    }
}

/// Answers the two buttons on the banner.
///
/// Kept apart from `EventNotifier` because the notifier is a stateless enum
/// that anything may post through, while this holds the coordinator whose undo
/// the button calls. `AppDelegate` owns one for the life of the app — the
/// notification centre's `delegate` is a weak reference, and a delegate that
/// has been deallocated is a button that does nothing.
@MainActor
final class EventNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let calendarCoordinator: CalendarCoordinator

    init(calendarCoordinator: CalendarCoordinator) {
        self.calendarCoordinator = calendarCoordinator
    }

    /// Show the banner even when MemoryClip is the active app.
    ///
    /// Left alone, macOS suppresses a notification an app posts to itself
    /// while it is frontmost — which for a menu-bar app means the banner
    /// vanishes exactly when the panel is open, the one moment the user is
    /// looking at MemoryClip.
    ///
    /// `nonisolated` so it witnesses the requirement whatever isolation the
    /// SDK declares it with; it touches nothing of this object's.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    /// Act on a tapped button.
    ///
    /// Only the action identifier crosses to the main actor: `UNNotificationResponse`
    /// is a reference type that is not `Sendable`, and the identifier is all
    /// this needs.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await handle(response.actionIdentifier)
    }

    private func handle(_ action: String) async {
        switch action {
        case EventNotifier.undoActionIdentifier:
            _ = await calendarCoordinator.undoLastEvent()
        case EventNotifier.openActionIdentifier:
            Self.openCalendar()
        default:
            // The banner itself was clicked, or it was dismissed. Neither is
            // an instruction, and MemoryClip has no window to bring forward
            // for one.
            break
        }
    }

    /// Bring up Calendar.
    ///
    /// The app, by bundle identifier, rather than a URL scheme: `calshow:` is
    /// undocumented, has no guarantee of surviving a release, and there is
    /// nothing to deep-link to anyway — write-only access means MemoryClip
    /// cannot resolve its own event back to something to show. Opening the app
    /// is what the button honestly does.
    private static func openCalendar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else {
            log.error("Calendar.app could not be located")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
