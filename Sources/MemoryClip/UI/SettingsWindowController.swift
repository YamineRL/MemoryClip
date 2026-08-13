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

    /// The window's title. Also applied from inside `SettingsView`, which is
    /// what stops `NavigationSplitView` retitling the window per pane.
    static let windowTitle = "MemoryClip Settings"

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
        // Nothing in `SettingsView` may size the window. With the default
        // sizing options the hosting controller republishes its content's
        // fitting size as the window's preferred and minimum size, which for a
        // sidebar layout means the window grows and shrinks as you move
        // between panes — the detail area visibly jumping under the pointer.
        // Empty options make the window authoritative: the panes fill what
        // they are given.
        controller.sizingOptions = []

        let window = NSWindow(contentViewController: controller)
        window.title = Self.windowTitle
        // Resizable, unlike the old tab window: a sidebar layout has a real
        // reason to be widened (long hints, larger text sizes), and
        // `contentMinSize` is what keeps that from being used to squash it.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Closing settings must not deallocate the window out from under us —
        // it is reused for the life of the app.
        window.isReleasedWhenClosed = false
        window.setContentSize(
            NSSize(width: Design.Size.settingsWidth, height: Design.Size.settingsHeight)
        )
        window.contentMinSize = NSSize(
            width: Design.Size.settingsMinWidth,
            height: Design.Size.settingsMinHeight
        )
        // A *new* autosave name. The old one holds a frame saved for the
        // 520×420 tab window, and AppKit restores a saved frame verbatim — a
        // user who had opened Settings before this change would get the
        // sidebar layout crushed into the tab window's footprint.
        window.setFrameAutosaveName("MemoryClipSettingsSidebarWindow")
        return window
    }
}
