import AppKit
import UserNotifications

/// The banner that says a newer MemoryClip exists, and the button on it.
///
/// Shaped like `EventNotifier`, and for the same reasons written there: the
/// wording is a pure function the tests exercise, delivery is inert in any
/// process that is not an app bundle, and permission is asked at the first
/// post rather than at launch — here that means it is only ever asked of
/// someone who switched the daily check on and has an update waiting, which
/// is the one moment the question answers itself.
enum UpdateNotifier {
    static let categoryIdentifier = "app.memoryclip.update"
    /// Downloads the disk image and opens it — `UpdateChecker.download`.
    static let downloadActionIdentifier = "app.memoryclip.update.download"

    struct Message: Equatable {
        let title: String
        let body: String
    }

    /// The two lines of the banner.
    ///
    /// The body says what the button will actually do, in order, because the
    /// second half of it is a Finder window appearing: an update that opens a
    /// disk image and stops there is not what most Mac apps mean by "update",
    /// and being told so beforehand is the difference between an install and
    /// a surprise.
    static func message(version: ReleaseVersion) -> Message {
        Message(
            title: loc("MemoryClip %@ is available", version.description),
            body: loc("Download it and MemoryClip will open the disk image for you to drag across.")
        )
    }

    /// Announce one available release, if the user will have it.
    ///
    /// Silent on every failure, like the calendar banner: there is no window
    /// open to complain in, and the update is still there to be found in
    /// Settings.
    @MainActor
    static func post(version: ReleaseVersion) async {
        guard EventNotifier.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        guard await isAuthorized(center) else { return }

        let text = message(version: version)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = categoryIdentifier

        // Keyed on the version rather than a fresh uuid: if one somehow gets
        // posted twice, the second replaces the first instead of stacking.
        let request = UNNotificationRequest(
            identifier: "\(categoryIdentifier).\(version)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            log.error("Update notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private static func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert])
        } catch {
            log.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// One button. `.foreground` because taking it ends with Finder opening a
    /// volume, and an app that is about to put a window on screen should be
    /// the one in front when it does.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: downloadActionIdentifier,
                    title: loc("Download"),
                    options: [.foreground]
                )
            ],
            intentIdentifiers: [],
            options: []
        )
    }
}
