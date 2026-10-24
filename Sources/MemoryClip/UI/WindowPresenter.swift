import AppKit

/// Where a window opened on request goes, worked out without a window server.
///
/// A titled window MemoryClip opens — Settings, the tour, Permissions — comes
/// from an `.accessory` agent: no Dock tile, no app switcher entry, nothing to
/// click if it opens somewhere the user is not looking. Reported as "I click
/// Settings and nothing shows": the window was minimised, on a display that
/// had since been unplugged, or on the other monitor. So the rule is that a
/// window opened on request lands on the screen the user is working on, in
/// full, every time.
enum WindowPlacement {
    /// The part of a window's top edge that has to be on a screen for the
    /// window to count as reachable: the title bar, which is what it is
    /// dragged by. A window whose title bar is off every screen cannot be
    /// moved back by hand.
    static let titleBarHeight: CGFloat = 28
    /// How much of that title bar, across, must be on a screen.
    static let minimumGrip: CGFloat = 80

    /// The screen the user is on: the one under the pointer, which is where
    /// the menu bar item or the hotkey was just used. The first screen
    /// (the main one) when the pointer is somehow on none of them.
    static func targetScreen(pointer: NSPoint, screenFrames: [NSRect]) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        // `contains` excludes the max edges, and the pointer sits exactly on
        // the top edge while it is in the menu bar.
        return screenFrames.firstIndex { $0.insetBy(dx: -1, dy: -1).contains(pointer) } ?? 0
    }

    /// Whether a window at `frame` can still be grabbed by its title bar on
    /// one of `visibleFrames`.
    static func isReachable(_ frame: NSRect, visibleFrames: [NSRect]) -> Bool {
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - titleBarHeight, width: frame.width, height: titleBarHeight)
        return visibleFrames.contains { screen in
            let overlap = screen.intersection(titleBar)
            return !overlap.isNull && overlap.width >= min(minimumGrip, frame.width) && overlap.height > 0
        }
    }

    /// The frame to open a window at.
    ///
    /// - Parameters:
    ///   - current: Where the window is now (or was last left).
    ///   - minimumSize: The smallest frame the window allows.
    ///   - keepPosition: Whether `current` is a place the user chose (a saved
    ///     or earlier position) rather than AppKit's default origin.
    ///   - target: The visible frame of the screen the user is on.
    /// - Returns: `current` when it was chosen and lies wholly on `target`;
    ///   otherwise the window centred on `target`, a little above the middle
    ///   as AppKit's `center()` does, shrunk to fit a screen smaller than it.
    static func openingFrame(current: NSRect, minimumSize: NSSize, keepPosition: Bool, target: NSRect) -> NSRect {
        if keepPosition, target.contains(current) { return current }

        let width = max(min(current.width, target.width), min(minimumSize.width, target.width))
        let height = max(min(current.height, target.height), min(minimumSize.height, target.height))
        let x = target.midX - width / 2
        // A third of the free space below, two thirds above: optically
        // centred, the way `NSWindow.center()` places a window.
        let free = target.height - height
        let y = target.minY + free * 2 / 3
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }
}

/// Opens one of MemoryClip's titled windows where the user can see and use it.
@MainActor
enum WindowPresenter {
    /// Show `window` in front, on the screen the user is on, with the keyboard.
    ///
    /// - Parameter keepPosition: Whether the window's current frame is one the
    ///   user chose. Kept only when it lies wholly on the screen they are on
    ///   now; otherwise the window is centred there.
    ///
    /// Each step answers one way "nothing shows":
    /// - hidden: an `NSApp.hide` from the panel dismissing leaves the app
    ///   hidden, and a hidden app will not order windows in;
    /// - minimised: ordering a minimised window front leaves it in the Dock;
    /// - elsewhere: a window already open is left where it is while its title
    ///   bar is on some screen, and brought to the user's screen when it is
    ///   not (a display unplugged under it); one being opened goes to the
    ///   user's screen;
    /// - not focused: activation as `SettingsWindowController.show()`
    ///   explains — window first, forced activation second, key last.
    ///
    /// The Space is the window's `collectionBehavior`, set where it is made.
    static func present(_ window: NSWindow, keepPosition: Bool) {
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }

        let screens = NSScreen.screens
        let visibleFrames = screens.map(\.visibleFrame)
        if let index = WindowPlacement.targetScreen(pointer: NSEvent.mouseLocation, screenFrames: screens.map(\.frame)) {
            let stayPut = window.isVisible && WindowPlacement.isReachable(window.frame, visibleFrames: visibleFrames)
            if !stayPut {
                let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
                let frame = WindowPlacement.openingFrame(
                    current: window.frame,
                    minimumSize: minimum,
                    keepPosition: keepPosition && !window.isVisible,
                    target: visibleFrames[index]
                )
                if frame != window.frame { window.setFrame(frame, display: false) }
            }
        }

        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
    }
}
