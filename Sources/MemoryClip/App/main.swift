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
        return mainMenu
    }

    @MainActor
    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "MemoryClip")

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(MenuActions.openSettings),
            keyEquivalent: ","
        )
        settings.target = MenuActions.shared
        menu.addItem(settings)

        menu.addItem(.separator())

        menu.addItem(
            NSMenuItem(title: "Hide MemoryClip", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        )
        menu.addItem(
            NSMenuItem(title: "Quit MemoryClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )

        item.submenu = menu
        return item
    }

    @MainActor
    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

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
