import AppKit
import SwiftUI

/// NSWindow subclass so Esc closes the window, which a titled window does not
/// do by default.
private final class PermissionRecoveryWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// Notices at launch which permissions an update cost the user, offers to ask
/// for them again, and opens the same window on demand from the menu bar.
///
/// The reconciliation is the interesting half, and it runs on every launch
/// whether or not a window follows:
///
/// - A permission that works is recorded against the running build. That
///   record is the only memory of a grant there is — TCC will not tell an app
///   what it was allowed to do under a signature it no longer has.
/// - A permission refused under the build that holds the record is forgotten,
///   because the user turned it off on purpose and an app that offers to undo
///   that has stopped listening.
/// - What is left — worked before, does not work now, has not been offered
///   under this build — is what the window is for.
///
/// Modelled on `OnboardingController`: one reused window, an `.accessory`
/// agent that has to activate to be seen, and the decision itself kept
/// `nonisolated` and pure in `PermissionRecovery` so it can be tested without
/// AppKit, a bundle or a TCC database.
@MainActor
final class PermissionRecoveryController: NSObject, NSWindowDelegate {
    static let shared = PermissionRecoveryController()

    private var window: NSWindow?
    /// Kept so each `show` can re-root it: the rows and the header differ
    /// between the two ways in, and a window built once for the first of them
    /// would show the wrong thing for the second.
    private var hostingView: NSHostingView<PermissionRecoveryView>?

    // MARK: Launch

    /// Reconcile the ledger with what macOS says, and show the window when an
    /// update has cost the user something.
    ///
    /// Safe to call on every launch: a Mac that has lost nothing gets no
    /// window, and a permission the user declined to restore is offered once
    /// per build rather than once per launch — Permissions… in the menu bar
    /// is how anyone who dismissed it gets back.
    @discardableResult
    func showIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        let ledger = PermissionLedger(defaults: defaults)
        let states = PermissionProbe.states()
        reconcile(states: states, ledger: ledger)

        let lost = PermissionRecovery.lost(
            granted: ledger.granted,
            asked: ledger.asked,
            states: states,
            identity: AppIdentity.current
        )
        guard !lost.isEmpty else { return false }
        for permission in lost {
            ledger.noteOffered(permission)
        }
        log.notice("Offering to restore \(lost.count, privacy: .public) permission(s) after an update")
        show(lost, states: states, reason: .update, ledger: ledger)
        return true
    }

    /// UserDefaults key recording that the blocked-feature offer has been made.
    nonisolated static let blockedOfferKey = "permissionBlockedOfferShown"

    /// Offer, once ever, the permissions a switched-on feature is missing.
    ///
    /// The ledger cannot help the release that introduces it: a grant dropped
    /// by the very update that installs this code was never observed, so
    /// `showIfNeeded` has nothing to offer and the feature protects only the
    /// *next* update. The settings do know, though — automatic events are on,
    /// or notes go to Notes — and a feature that is switched on and cannot run
    /// is worth saying out loud exactly once.
    ///
    /// The flag is written only when the window is actually shown, so someone
    /// who turns automatic events on next month still gets the offer then.
    @discardableResult
    func showBlockedOnce(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: Self.blockedOfferKey) else { return false }

        let states = PermissionProbe.states()
        let blocked = PermissionRecovery.blocked(
            states: states,
            createsEventsAutomatically: defaults.bool(forKey: CalendarSettingsKeys.autoCreate),
            writesToNotesApp: NoteDestination.current == .notesApp
        )
        guard !blocked.isEmpty else { return false }

        defaults.set(true, forKey: Self.blockedOfferKey)
        log.notice("Offering \(blocked.count, privacy: .public) permission(s) a switched-on feature needs")
        show(blocked, states: states, reason: .blocked, ledger: PermissionLedger(defaults: defaults))
        return true
    }

    /// Bring the ledger up to date with what macOS says right now.
    private func reconcile(states: [RecoverablePermission: PermissionState], ledger: PermissionLedger) {
        for (permission, state) in states {
            switch state {
            case .granted:
                ledger.noteGranted(permission)
            case .denied where ledger.granted[permission] == AppIdentity.current:
                ledger.forget(permission)
            case .denied, .forgotten, .unavailable:
                continue
            }
        }
    }

    // MARK: On demand

    /// Every permission MemoryClip can ask for, with what each is worth right
    /// now — the menu bar's Permissions… item.
    ///
    /// All of them, not only the missing ones: a window that lists what is
    /// already allowed answers "what does this app have on my Mac", which is
    /// a fair question to ask of something that reads the clipboard, and it
    /// means the item never opens an empty window.
    func showAll(defaults: UserDefaults = .standard) {
        let states = PermissionProbe.states()
        let ledger = PermissionLedger(defaults: defaults)
        reconcile(states: states, ledger: ledger)
        show(RecoverablePermission.allCases, states: states, reason: .review, ledger: ledger)
    }

    // MARK: Showing

    func show(
        _ permissions: [RecoverablePermission],
        states: [RecoverablePermission: PermissionState],
        reason: PermissionRecoveryView.Reason,
        ledger: PermissionLedger = PermissionLedger()
    ) {
        ensureWindow()
        guard let window, let hostingView else { return }

        hostingView.rootView = PermissionRecoveryView(
            reason: reason,
            permissions: permissions,
            states: states,
            onGranted: { permission in ledger.noteGranted(permission) },
            onPromptFinished: { [weak self] in self?.returnFromSystemPrompt() },
            onFinish: { [weak self] in self?.close() }
        )
        // Sized to the rows it actually got: one missing permission is a third
        // of the window three are, and a fixed height would either clip the
        // third row or leave the single one floating in a page of nothing.
        window.setContentSize(hostingView.fittingSize)

        if !window.isVisible {
            window.center()
        }
        front()
    }

    func close() {
        window?.orderOut(nil)
    }

    /// Put the window in front and give it the keyboard.
    ///
    /// The same activation `OnboardingController.show()` performs, for the
    /// same reason: an `.accessory` agent's window is not visible, focusable
    /// or findable again unless the app takes activation with it.
    private func front() {
        guard let window else { return }
        NSApp.unhide(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
    }

    /// Win the window back after a permission prompt has been answered.
    ///
    /// This window cannot use `WindowFocus.restoreAfterSystemPrompt`, which
    /// restores whichever titled window happens to be frontmost: the window
    /// that has to come back here is *this* one, and it is the only thing on
    /// screen offering the permissions that have not been granted yet.
    ///
    /// The hop through the main queue is not a flourish. A TCC dialog is still
    /// dismissing when the call that raised it returns, and an activation
    /// requested during that dismissal is undone by it — which is precisely
    /// how granting the first permission used to leave the window behind every
    /// other app, unreachable for the second.
    private func returnFromSystemPrompt() {
        front()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.front()
        }
    }

    // MARK: Window construction

    private func ensureWindow() {
        guard window == nil else { return }

        let window = PermissionRecoveryWindow(
            contentRect: NSRect(x: 0, y: 0, width: Design.Size.sheetWidth, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = loc("Permissions")
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        // Floating, unlike the tour and Settings, and for a reason particular
        // to this window: every button on it hands the screen to a system
        // dialog, and a normal-level window belonging to an agent that has
        // just lost activation is one the user has no way of finding again.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self

        let hostingView = NSHostingView(rootView: PermissionRecoveryView(
            reason: .review,
            permissions: [],
            states: [:],
            onGranted: { _ in },
            onPromptFinished: {},
            onFinish: {}
        ))
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        self.window = window
        self.hostingView = hostingView
    }

    // MARK: NSWindowDelegate

    /// Esc / close button: hide without releasing. Closing grants nothing and
    /// blocks nothing — Permissions… in the menu bar opens it again.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
