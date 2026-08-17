import AppKit

/// Puts MemoryClip's own window back in front after another process has had
/// the screen.
///
/// A permission prompt — TCC, Touch ID — is not the app's window. Answering it
/// hands activation back to whichever *regular* application held it before,
/// and MemoryClip is an `.accessory` agent: no Dock tile to click, no menu bar
/// to notice, no entry in the app switcher. A Settings window that merely fell
/// behind Safari is, to the person who was reading it a second ago, a Settings
/// window that closed itself the moment they said Allow.
///
/// So every place that can raise a system dialog from one of MemoryClip's own
/// windows calls this when the dialog returns. It is deliberately called only
/// on the paths that actually raised one: activation the user did not ask for
/// is its own bug, and an agent that jumps in front on every settings change
/// is worse than one that occasionally has to be found again.
@MainActor
enum WindowFocus {
    /// Bring the frontmost real window back, and take activation with it.
    ///
    /// `unhide` first because hiding is the one state ordering a window in
    /// cannot undo, and `activate(ignoringOtherApps:)` rather than the
    /// cooperative spelling for the reason `SettingsWindowController.show()`
    /// writes out: a request that can be refused leaves the window on screen
    /// and unfocused, which is the failure this exists to prevent.
    static func restoreAfterSystemPrompt() {
        NSApp.unhide(nil)
        guard let window = NSApp.orderedWindows.first(where: isRestorable) else { return }
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
    }

    private static func isRestorable(_ window: NSWindow) -> Bool {
        isRestorable(
            isVisible: window.isVisible,
            isTitled: window.styleMask.contains(.titled),
            isPanel: window is NSPanel
        )
    }

    /// The windows worth restoring: Settings and the tour, which are the only
    /// two a permission prompt can be raised from.
    ///
    /// `NSPanel` is excluded rather than enumerated around, because every
    /// panel MemoryClip owns — the clip deck, Quick Look, the QR code — is one
    /// that hides itself when the app resigns active. Ordering one of those
    /// back in would undo a dismissal the user performed on purpose.
    ///
    /// Taking the three facts rather than the window so the rule can be
    /// checked without a window server, which is what the test machines and
    /// CI have.
    static func isRestorable(isVisible: Bool, isTitled: Bool, isPanel: Bool) -> Bool {
        isVisible && isTitled && !isPanel
    }
}
