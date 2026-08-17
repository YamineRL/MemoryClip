import AppKit
import SwiftUI

/// NSWindow subclass so Esc dismisses the tour (a titled window does not close
/// on Esc by default). `performClose` keeps the delegate in the loop.
private final class OnboardingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// Owns the first-run onboarding window (Phase 4).
///
/// One window instance is reused. The tour is shown automatically on the very
/// first launch — tracked by `OnboardingController.hasCompletedKey` in
/// UserDefaults — and can be re-opened at any time with `show()`.
///
/// The first-run decision and the flag writes are `nonisolated` statics taking
/// an explicit `UserDefaults`, so they are testable without touching AppKit.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()

    /// UserDefaults key recording that the tour has been shown once.
    nonisolated static let hasCompletedKey = "hasCompletedOnboarding"

    private var window: NSWindow?

    // MARK: First-run decision (pure, testable)

    /// True while the tour has never been completed/shown.
    nonisolated static func isFirstRun(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: hasCompletedKey)
    }

    /// Records that the tour has been shown, so it never auto-opens again.
    nonisolated static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: hasCompletedKey)
    }

    /// Clears the flag (used by tests; also makes a "show tour again on next
    /// launch" affordance trivial).
    nonisolated static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: hasCompletedKey)
    }

    // MARK: Showing

    /// Shows the tour only on a first launch. Called from AppDelegate.
    ///
    /// The flag is written as soon as the window is shown (not on dismissal),
    /// so an unclean quit can't make the tour reappear on every launch.
    func showIfFirstRun(defaults: UserDefaults = .standard) {
        guard Self.isFirstRun(defaults: defaults) else { return }
        Self.markCompleted(defaults: defaults)
        show()
    }

    /// Opens (or brings forward) the onboarding window on demand.
    func show() {
        ensureWindow()
        guard let window else { return }

        if !window.isVisible {
            window.center()
        }
        // MemoryClip is an .accessory agent, so it must activate for the window
        // to become visible and focusable — and it must do so the same way
        // `SettingsWindowController.show()` does, for the reasons written out
        // there: cooperative activation can be refused, and a refused tour is
        // one that opens behind whatever the user was reading and takes none
        // of their key presses.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
    }

    /// Closes the tour without releasing the window (it is reused).
    func close() {
        window?.orderOut(nil)
    }

    // MARK: Window construction

    private func ensureWindow() {
        guard window == nil else { return }

        // The content rect comes from the same tokens `OnboardingView` frames
        // itself with. Spelled out separately, the two drifted the moment the
        // view grew: the window kept its old 420 points and clipped the page.
        let window = OnboardingWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Design.Size.sheetWidth,
                height: Design.Size.sheetHeight
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = loc("Welcome to MemoryClip")
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self

        let hostingView = NSHostingView(rootView: OnboardingView(onFinish: { [weak self] in
            self?.close()
        }))
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        self.window = window
    }

    // MARK: NSWindowDelegate

    /// Esc / close button: hide without releasing, so the window can be
    /// re-shown from Settings later.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
