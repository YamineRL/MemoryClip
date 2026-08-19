import AppKit
import ApplicationServices
import Foundation

/// Asks macOS what each recoverable permission is worth right now, and asks
/// again for the ones an update cost the user.
///
/// The three grants are checked through three unrelated APIs, and each one
/// lies in its own way, so the mapping onto `PermissionState` is where the
/// knowledge lives:
///
/// - **Calendar** answers honestly through `EventKitSink.access`, which
///   already carries the one caveat worth knowing (a granted request can go on
///   reporting `.notDetermined` for the life of the process).
/// - **Automation** can only be checked against a *running* target. Notes is
///   almost never running, so the check usually cannot reach TCC at all — see
///   `notesAutomationState`.
/// - **Accessibility** has no status, only a boolean and a prompt that opens
///   System Settings. It cannot be granted in place by anyone.
@MainActor
enum PermissionProbe {
    /// Notes' bundle identifier, which is the Automation grant's subject.
    static let notesBundleIdentifier = "com.apple.Notes"

    // MARK: - Reading

    static func state(of permission: RecoverablePermission) -> PermissionState {
        switch permission {
        case .calendar: return calendarState
        case .notesAutomation: return notesAutomationState
        case .filesAndFolders: return filesAndFoldersState
        case .accessibility: return accessibilityState
        }
    }

    /// Every permission's state, for the recovery decision.
    static func states() -> [RecoverablePermission: PermissionState] {
        RecoverablePermission.allCases.reduce(into: [:]) { states, permission in
            states[permission] = state(of: permission)
        }
    }

    private static var calendarState: PermissionState {
        switch EventKitSink.access {
        case .granted: return .granted
        case .notAsked: return .forgotten
        case .denied: return .denied
        case .restricted: return .unavailable
        }
    }

    /// The Apple Events grant for Notes, as far as it can be observed.
    ///
    /// `AEDeterminePermissionToAutomateTarget` answers from TCC only while the
    /// target is running; against a quit app it returns `procNotFound` before
    /// it ever consults the database. Notes is quit on most Macs most of the
    /// time, so that is the ordinary answer, not the edge case.
    ///
    /// It is read as `.forgotten` rather than `.unavailable`, and the reason
    /// is the one this whole file exists for: replacing the bundle invalidates
    /// the Apple Events grant unconditionally. "Cannot check" and "worked
    /// under a build that is no longer installed" together mean the grant is
    /// gone. The ledger supplies the second half — nothing is offered for a
    /// permission that has never worked, or that has worked under this build —
    /// so the worst this costs a user is one click on a prompt macOS then
    /// declines to show.
    private static var notesAutomationState: PermissionState {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: notesBundleIdentifier) != nil else {
            return .unavailable
        }
        switch automationStatus(askUserIfNeeded: false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .forgotten
        }
    }

    private static var accessibilityState: PermissionState {
        AXIsProcessTrusted() ? .granted : .forgotten
    }

    /// Whether the folders the user picked are known to work.
    ///
    /// Read out of the ledger, not off the disk, and that is the whole design
    /// rather than a shortcut. macOS answers a folder question by putting a
    /// dialog in front of the user, so a probe here would raise one from
    /// `states()` — which runs at launch, from the code whose entire job is to
    /// explain the dialog before it appears.
    ///
    /// `.forgotten` therefore covers "lost to an update" and "never recorded"
    /// alike. Both mean the same thing to the window: offer it, and let the
    /// button be what touches the disk.
    private static var filesAndFoldersState: PermissionState {
        guard !grantedFolders().isEmpty else { return .unavailable }
        return PermissionLedger().worksUnderThisBuild(.filesAndFolders) ? .granted : .forgotten
    }

    /// A folder MemoryClip has been pointed at, and how to ask for it again.
    struct GrantedFolder {
        let key: String
        let url: URL
        let title: String
        let message: String
    }

    /// The folders in use, in the order Settings presents them.
    ///
    /// The vault is left out when its bookmark will not resolve at all: there
    /// is no URL to probe and no folder to re-pick, and Settings shows no
    /// folder for it either, so there is nothing here the window could offer.
    static func grantedFolders(defaults: UserDefaults = .standard) -> [GrantedFolder] {
        var folders: [GrantedFolder] = []
        if NoteDestination.current == .markdownVault,
           let vault = FolderBookmark.resolve(key: NoteSettingsKeys.vaultBookmark) {
            folders.append(GrantedFolder(
                key: NoteSettingsKeys.vaultBookmark,
                url: vault,
                title: loc("Choose Note Folder"),
                message: loc("Pick the folder MemoryClip should write notes into — an Obsidian vault, or any folder of Markdown files.")
            ))
        }
        if defaults.bool(forKey: NoteSettingsKeys.screenshotCaptureEnabled) {
            // The folder the watcher actually watches, which is not always a
            // bookmarked one: with the feature on and nothing picked, it falls
            // back to wherever `screencapture` is configured to write — very
            // often `~/Desktop`, which macOS guards just as closely. Reading
            // only the bookmark here left the row blind to exactly that case.
            folders.append(GrantedFolder(
                key: NoteSettingsKeys.screenshotFolderBookmark,
                url: ScreenshotWatcher.resolvedFolder(),
                title: loc("Choose Screenshot Folder"),
                message: loc("Pick the folder macOS saves your screenshots to. MemoryClip watches it for new files.")
            ))
        }
        return folders
    }

    // MARK: - Asking again

    /// Put the permission's own prompt on screen where macOS still allows one,
    /// and open the pane that holds the switch where it does not.
    ///
    /// - Returns: what the permission is worth afterwards.
    @discardableResult
    static func request(_ permission: RecoverablePermission) async -> PermissionState {
        switch permission {
        case .calendar:
            await EventKitSink.primeAccess()
            if calendarState == .denied { openSettings(for: permission) }
            return calendarState
        case .notesAutomation:
            return await requestNotesAutomation()
        case .filesAndFolders:
            return requestFilesAndFolders()
        case .accessibility:
            requestAccessibility()
            return accessibilityState
        }
    }

    /// Raise the Automation prompt for Notes.
    ///
    /// Notes has to be running for the prompt to exist at all, so it is
    /// launched first — in the background, without activation, without a
    /// window taking the screen. Nothing is created in it: the Apple Event
    /// sent is the permission question itself, which is the smallest event
    /// that can carry the grant.
    private static func requestNotesAutomation() async -> PermissionState {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notesBundleIdentifier) else {
            return .unavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)

        let status = automationStatus(askUserIfNeeded: true)
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            openSettings(for: .notesAutomation)
            return .denied
        default:
            return .forgotten
        }
    }

    /// Ask for the refused folders again, through the open panel.
    ///
    /// The panel *is* the prompt. Files and Folders has no dialog an app can
    /// raise, but a folder the user chooses is granted to the app as part of
    /// the choosing — the same route that granted it the first time — and that
    /// route works even where System Settings shows a refusal.
    ///
    /// Only the folders that are actually refused are asked for, so someone
    /// whose vault is fine and whose screenshot folder is not is not made to
    /// re-pick both. Cancelling any of them leaves the rest alone: the state
    /// returned is read back from disk afterwards, not assumed from the fact
    /// that a panel was shown.
    private static func requestFilesAndFolders() -> PermissionState {
        var readings: [FolderAccess.Reading] = []
        for folder in grantedFolders() {
            // The real access first. The user pressed a button, so a prompt
            // here is the prompt they asked for — and where macOS has simply
            // forgotten rather than refused, answering it is the whole repair
            // and the picker never has to appear.
            var reading = FolderAccess.read(folder.url)
            if reading != .readable {
                // Refused, or the folder has moved. Picking it in an open
                // panel grants it outright, which is the one route that works
                // even against a refusal on the record.
                if let chosen = FolderBookmark.choose(
                    key: folder.key,
                    title: folder.title,
                    message: folder.message,
                    startingAt: folder.url
                ) {
                    reading = FolderAccess.read(chosen)
                }
            }
            readings.append(reading)
        }
        // From what the folders just said, not from the ledger: reading the
        // ledger back here would report the state as it was before the button
        // was pressed.
        guard !readings.isEmpty else { return .unavailable }
        let state: PermissionState = readings.allSatisfy { $0 == .readable } ? .granted : .forgotten

        // Written here rather than left to the caller, and written *before*
        // the notification: the watcher checks the ledger the moment it is
        // told the folder changed, and would find the old answer.
        if state == .granted { PermissionLedger().noteGranted(.filesAndFolders) }
        if readings.contains(.readable) {
            // The screenshot watcher declined to open a folder it had no
            // access to, and nothing else would tell it that changed. Same
            // notification the Settings picker posts, for the same reason.
            NotificationCenter.default.post(name: .memoryClipScreenshotFolderChanged, object: nil)
        }
        return state
    }

    /// Ask macOS to list MemoryClip under Accessibility, and open the pane.
    ///
    /// `AXIsProcessTrustedWithOptions` with the prompt option is as close to
    /// an ask as this permission has: it cannot grant anything, but it does
    /// put the app in the list with a switch beside it, which is what turns
    /// "find MemoryClip and add it" into "turn this on". The pane is opened
    /// as well, because macOS shows that alert at most once per process and a
    /// button that does nothing the second time is a broken button.
    private static func requestAccessibility() {
        // The literal rather than `kAXTrustedCheckOptionPrompt`, which is
        // imported as a mutable global and so cannot be read from anywhere
        // under Swift 6's concurrency checking. The string is the constant's
        // documented value and part of the API's contract.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openSettings(for: .accessibility)
    }

    /// Open the System Settings pane that holds this permission's switch.
    static func openSettings(for permission: RecoverablePermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Apple Events

    /// `AEDeterminePermissionToAutomateTarget` against Notes.
    ///
    /// The wildcard event class and ID ask about automating the target as a
    /// whole, which is the grant System Settings shows and the one the note
    /// script needs — asking about a single event would authorise less than
    /// the sink goes on to send.
    private static func automationStatus(askUserIfNeeded: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let identifier = Array(notesBundleIdentifier.utf8)
        let created = OSStatus(AECreateDesc(typeApplicationBundleID, identifier, identifier.count, &target))
        guard created == noErr else { return created }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, askUserIfNeeded)
    }
}
