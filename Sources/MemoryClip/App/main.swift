import AppKit

/// AppKit entry point.
///
/// This used to be a SwiftUI `App` whose only scene was `Settings`. That scene
/// is the reason the Settings window could only be opened with ⌘, — see
/// `SettingsWindowController`. With the window hosted ourselves there is
/// nothing left for a `Scene` to do, so the app starts as plain AppKit and
/// builds its own main menu.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.mainMenu = MainMenu.make()
application.run()

/// The application's main menu.
///
/// An `.accessory` app never shows a menu bar, but the main menu is still what
/// gives key equivalents somewhere to be handled: ⌘, for Settings, ⌘Q to quit,
/// and the Edit menu that makes ⌘X/⌘C/⌘V/⌘A work in the panel's search field.
/// Without it those shortcuts are dead.
enum MainMenu {
    @MainActor
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        return mainMenu
    }

    @MainActor
    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "MemoryClip")

        let settings = NSMenuItem(
            title: loc("Settings…"),
            action: #selector(MenuActions.openSettings),
            keyEquivalent: ","
        )
        settings.target = MenuActions.shared
        menu.addItem(settings)

        menu.addItem(.separator())

        menu.addItem(
            NSMenuItem(title: loc("Hide MemoryClip"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        )
        menu.addItem(
            NSMenuItem(title: loc("Quit MemoryClip"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )

        item.submenu = menu
        return item
    }

    /// The Window menu, which exists for exactly one key equivalent: ⌘W.
    ///
    /// Settings and the onboarding tour are ordinary titled windows, and a
    /// titled window that will not close on ⌘W reads as broken — it is the
    /// shortcut people reach for before they look for the red button. The
    /// panel gets it too, which is right: it already overrides `performClose`
    /// so its delegate stays in the loop, and Escape remains the faster way
    /// out for anyone whose hands are on the clip list.
    ///
    /// `target` stays nil deliberately. A nil target sends the action down the
    /// responder chain to whichever window is key, which is the whole point:
    /// one menu item closes whatever the user is actually looking at, and no
    /// window has to be known about here.
    @MainActor
    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: loc("Window"))
        menu.addItem(
            NSMenuItem(title: loc("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        )
        item.submenu = menu
        return item
    }

    @MainActor
    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: loc("Edit"))

        menu.addItem(NSMenuItem(title: loc("Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: loc("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: loc("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: loc("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: loc("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: loc("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        item.submenu = menu
        return item
    }
}

/// Target for main-menu items that need one of our own methods.
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func openSettings() {
        openSettingsWindow()
    }
}
