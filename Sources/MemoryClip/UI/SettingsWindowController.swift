import AppKit
import SwiftUI

/// Owns the Settings window outright, as plain AppKit.
///
/// SwiftUI's `Settings` scene only opens through the responder chain
/// (`showSettingsWindow:`). An `.accessory` app with no key window has no
/// chain to walk, so a status-bar menu item could never reliably reach it —
/// the ⌘, main-menu equivalent worked only because AppKit dispatches menu key
/// equivalents to SwiftUI's own hidden target. Hosting the same `SettingsView`
/// in a window we create and retain removes the dispatch problem entirely:
/// every caller lands here, and here always has a window to show.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    /// Shows the Settings window, creating it on first use and bringing an
    /// existing one forward otherwise.
    func show() {
        // An `NSApp.hide` from the panel dismissing leaves the app hidden, and
        // a hidden app will not order new windows in.
        NSApp.unhide(nil)
        NSApp.activate()

        let window = window ?? makeWindow()
        self.window = window

        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: controller)
        window.title = "MemoryClip Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Closing settings must not deallocate the window out from under us —
        // it is reused for the life of the app.
        window.isReleasedWhenClosed = false
        window.setContentSize(controller.view.fittingSize)
        window.setFrameAutosaveName("MemoryClipSettingsWindow")
        return window
    }
}
