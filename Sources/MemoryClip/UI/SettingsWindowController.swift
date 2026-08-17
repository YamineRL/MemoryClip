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
    static var windowTitle: String { loc("MemoryClip Settings") }

    private var window: NSWindow?

    private init() {}

    /// Shows the Settings window, creating it on first use and bringing an
    /// existing one forward otherwise.
    ///
    /// The order is deliberate — window first, activation second, key last —
    /// and so is the deprecated spelling of the activation.
    ///
    /// `NSApp.activate()` is the cooperative one: it asks, and an app that
    /// was not handed activation by whoever currently holds it is free to be
    /// refused. That is right for the panel, which the user summons with a
    /// hotkey while MemoryClip is already being dealt with, and wrong here,
    /// where the request arrives from an `.accessory` agent that has no menu
    /// bar, no Dock tile and nothing else on screen to click. Refused, the
    /// window still orders in and simply never takes focus, so Settings looks
    /// open and swallows nothing the user types. `ignoringOtherApps` is
    /// deprecated rather than gone, and it is the only spelling that says
    /// what a Settings window opened by explicit user request means.
    ///
    /// `makeKey()` last because activation is asynchronous at the window
    /// server: a `makeKeyAndOrderFront` issued while the app is still inactive
    /// orders the window in and leaves the key part unhonoured.
    func show() {
        // An `NSApp.hide` from the panel dismissing leaves the app hidden, and
        // a hidden app will not order new windows in.
        NSApp.unhide(nil)

        let window = window ?? makeWindow()
        self.window = window

        if !window.isVisible {
            window.center()
        }
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
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
