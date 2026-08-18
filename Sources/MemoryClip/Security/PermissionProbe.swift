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
