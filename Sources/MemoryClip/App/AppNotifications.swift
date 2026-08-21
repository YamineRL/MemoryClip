import AppKit
import UserNotifications

/// Everything MemoryClip can put in Notification Centre, registered once.
///
/// `UNUserNotificationCenter` has one delegate and one set of categories, so
/// however many features post banners, exactly one place may install them.
/// Before there were two, that place was `EventNotifier` itself; a second
/// caller would have replaced the calendar's category rather than joined it,
/// and the Undo button would have quietly stopped appearing.
enum AppNotifications {
    /// Register every category and take delivery of taps.
    ///
    /// Called once at launch. The centre holds its delegate weakly, so the
    /// caller keeps `delegate` alive for as long as the app runs —
    /// `AppDelegate` does, in a stored property.
    @MainActor
    static func install(delegate: any UNUserNotificationCenterDelegate) {
        guard EventNotifier.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([EventNotifier.category, UpdateNotifier.category])
    }
}

/// Answers the buttons on MemoryClip's banners.
///
/// Kept apart from the notifiers because they are stateless enums that
/// anything may post through, while this holds the objects the buttons act
/// on. `AppDelegate` owns one for the life of the app — the notification
/// centre's `delegate` is a weak reference, and a delegate that has been
/// deallocated is a button that does nothing.
@MainActor
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let calendarCoordinator: CalendarCoordinator
    private let updateChecker: UpdateChecker

    init(calendarCoordinator: CalendarCoordinator, updateChecker: UpdateChecker) {
        self.calendarCoordinator = calendarCoordinator
        self.updateChecker = updateChecker
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
        case UpdateNotifier.downloadActionIdentifier:
            // The banner outlives the check that posted it — it can be sitting
            // in Notification Centre days later — so the release is looked up
            // again rather than taken from whatever `status` still holds.
            if let update = updateChecker.pendingUpdate {
                updateChecker.download(update)
            } else {
                updateChecker.check(userInitiated: false)
            }
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
