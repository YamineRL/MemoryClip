import Foundation
import UserNotifications

/// The one-time "secrets are now encrypted" notice (owner decision D1).
///
/// Posted on the first secret the watcher ever stores — never before, never
/// twice. The title and body are fixed catalogue strings naming no clip, so
/// Notification Center's history holds no plaintext either.
enum SecretNotice {
    /// Deliver the notice if it has never been. The flag is set before the
    /// request is made: a denied authorization means the notice never
    /// appears, and being denied should not re-arm it.
    static func postOnceIfNeeded() {
        guard EventNotifier.isAvailable else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SecretSettingsKeys.noticeShown) else { return }
        defaults.set(true, forKey: SecretSettingsKeys.noticeShown)
        Task { await post() }
    }

    private static func post() async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = loc("MemoryClip now keeps secrets encrypted")
        content.body = loc("Settings → Privacy → Secrets")
        let request = UNNotificationRequest(
            identifier: "secrets.notice",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
