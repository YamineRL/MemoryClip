import AppKit
import UserNotifications

/// Which causes have already been announced this run.
///
/// A value rather than state inside the poster, so the once-per-cause rule is
/// testable without a notification centre.
struct NoticeLedger: Equatable {
    private(set) var posted: Set<String> = []

    /// True the first time `key` is seen, false every time after.
    mutating func shouldPost(_ key: String) -> Bool {
        posted.insert(key).inserted
    }
}

/// One banner about something that went wrong out of sight.
///
/// `key` names the cause, not the occurrence: two notices with the same key
/// are the same news, and only the first is shown.
struct FailureNotice: Equatable, Sendable {
    /// Where a tap on the banner's body goes.
    enum Destination: Equatable, Sendable {
        case settings(SettingsPane)
        case systemSettings(URL)

        static let userInfoKey = "destination"

        /// The destination as a `userInfo` string: `settings:<pane>` or the URL.
        var userInfoValue: String {
            switch self {
            case .settings(let pane): "settings:\(pane.rawValue)"
            case .systemSettings(let url): url.absoluteString
            }
        }

        init?(userInfoValue value: String) {
            if value.hasPrefix("settings:") {
                guard let pane = SettingsPane(rawValue: String(value.dropFirst("settings:".count))) else { return nil }
                self = .settings(pane)
            } else if let url = URL(string: value), url.scheme == "x-apple.systempreferences" {
                self = .systemSettings(url)
            } else {
                return nil
            }
        }
    }

    let key: String
    let title: String
    let body: String
    let destination: Destination?

    // MARK: - Notes

    /// A clip in `identifier` was not translated because the language is not
    /// downloaded on this Mac.
    static func translationNeedsDownload(identifier: String, locale: Locale = L10n.locale) -> FailureNotice {
        let name = locale.localizedString(forIdentifier: identifier) ?? identifier
        return FailureNotice(
            key: "translation.\(identifier)",
            title: loc("Clip not translated"),
            body: loc("Download %@ in Settings → Translation to translate it.", name),
            destination: .settings(.translation)
        )
    }

    /// An automatic note export failed. Nil for a clip with nothing to write,
    /// which is not a failure the user can act on.
    static func noteExportFailed(_ error: NoteError) -> FailureNotice? {
        if error == .nothingToWrite { return nil }
        let destination: Destination = if error == .automationDenied,
                                          let url = RecoverablePermission.notesAutomation.settingsURL {
            .systemSettings(url)
        } else {
            .settings(.notes)
        }
        return FailureNotice(
            key: "note.\(error.logReason)",
            title: loc("Note not saved"),
            body: error.localizedDescription,
            destination: destination
        )
    }

    /// Note refinement is on, but Apple Intelligence is turned off.
    static var appleIntelligenceOff: FailureNotice {
        FailureNotice(
            key: "refinement.appleIntelligenceOff",
            title: loc("Apple Intelligence is off"),
            body: loc("Turn it on in System Settings, or turn off note refinement in Settings → Notes."),
            destination: .settings(.notes)
        )
    }

    // MARK: - Capture

    /// An image over the capture limits was left out of history.
    static func imageTooLarge(megabytes: Int, megapixels: Int) -> FailureNotice {
        FailureNotice(
            key: "capture.imageTooLarge",
            title: loc("Image not saved"),
            body: loc("Images over %d MB or %d megapixels aren’t kept in history.", megabytes, megapixels),
            destination: nil
        )
    }

    /// A secret could not be encrypted, so it was not kept.
    static var secretNotKept: FailureNotice {
        FailureNotice(
            key: "capture.secretNotKept",
            title: loc("Secret not saved"),
            body: loc("It couldn’t be encrypted, so it wasn’t kept. It’s still on your clipboard."),
            destination: nil
        )
    }

    /// The screenshot folder has stayed unreachable through several retries.
    static var screenshotFolderUnreachable: FailureNotice {
        FailureNotice(
            key: "screenshots.folderUnreachable",
            title: loc("Screenshots not being saved"),
            body: loc("Choose the screenshot folder again in Settings → Screenshots."),
            destination: .settings(.screenshots)
        )
    }

    /// This build has no access to the screenshot folder.
    static var screenshotAccessMissing: FailureNotice {
        FailureNotice(
            key: "screenshots.accessMissing",
            title: loc("Screenshots not being saved"),
            body: loc("Allow MemoryClip into the screenshot folder in Settings → Screenshots."),
            destination: .settings(.screenshots)
        )
    }

    // MARK: - App

    /// The panel lock is on, but this Mac cannot ask for Touch ID or a password.
    static var appLockUnavailable: FailureNotice {
        FailureNotice(
            key: "appLock.unavailable",
            title: loc("Panel opened without Touch ID"),
            body: loc("This Mac can’t ask for Touch ID or a password. Set one up in System Settings to lock the panel."),
            destination: URL(string: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension")
                .map { .systemSettings($0) }
        )
    }

    /// The history store could not be reset, so this run keeps it in memory.
    static var historyNotPersisted: FailureNotice {
        FailureNotice(
            key: "store.inMemory",
            title: loc("History won’t be saved"),
            body: loc("Clips copied now will be gone when MemoryClip quits. Restart it to try again."),
            destination: nil
        )
    }

    /// A calendar action taken from a banner failed. Nil when another
    /// creation for the same clip is already underway.
    static func calendarActionFailed(_ error: CalendarError, undo: Bool) -> FailureNotice? {
        if error == .alreadyInFlight { return nil }
        let destination: Destination? = switch error {
        case .accessDenied: RecoverablePermission.calendar.settingsURL.map { .systemSettings($0) }
        default: nil
        }
        return FailureNotice(
            key: "calendar.\(undo ? "undo" : "add").\(error.logReason)",
            title: undo ? loc("Couldn’t undo the event") : loc("Couldn’t add the event"),
            body: error.localizedDescription,
            destination: destination
        )
    }

    /// An update download started from a banner failed.
    static var updateDownloadFailed: FailureNotice {
        FailureNotice(
            key: "update.downloadFailed",
            title: loc("Update not downloaded"),
            body: loc("Try again from Settings → General."),
            destination: .settings(.general)
        )
    }
}

/// Posts `FailureNotice`s, each cause at most once per run.
///
/// Inert outside an app bundle, like the other notifiers, so a failure path
/// reached from a test returns instead of touching the notification centre.
@MainActor
enum FailureNotifier {
    static let categoryIdentifier = "app.memoryclip.failure"

    private static var ledger = NoticeLedger()

    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryIdentifier, actions: [], intentIdentifiers: [], options: [])
    }

    static func post(_ notice: FailureNotice?) {
        guard let notice, EventNotifier.isAvailable, ledger.shouldPost(notice.key) else { return }
        Task { await deliver(notice) }
    }

    private static func deliver(_ notice: FailureNotice) async {
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert]) else { return }
        } catch {
            log.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.categoryIdentifier = categoryIdentifier
        if let destination = notice.destination {
            content.userInfo = [FailureNotice.Destination.userInfoKey: destination.userInfoValue]
        }
        let request = UNNotificationRequest(
            identifier: "\(categoryIdentifier).\(notice.key)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            log.error("Failure notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Take the user where the notice said the fix is.
    static func open(_ destination: FailureNotice.Destination) {
        switch destination {
        case .settings(let pane):
            UserDefaults.standard.set(pane.rawValue, forKey: SettingsKeys.settingsPane)
            SettingsWindowController.shared.show()
        case .systemSettings(let url):
            NSWorkspace.shared.open(url)
        }
    }
}
