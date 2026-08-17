import AppKit

/// Owns the menu-bar status item and its quick-history dropdown.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let store: ClipStore
    private let watcher: PasteboardWatcher
    private let pasteService: PasteService
    private let panelController: PanelController
    private let statusItem: NSStatusItem

    /// The app that was frontmost when the dropdown opened; paste targets it.
    private var frontmostAtMenuOpen: NSRunningApplication?

    /// True when clip contents may be shown/pasted without authenticating:
    /// either the lock is off, or the user authenticated recently. The window
    /// lives in `AppLockService`, so unlocking the panel also unredacts this
    /// dropdown — NSMenu cannot await an authentication while it is being
    /// built, so the titles are redacted until that window is open and the
    /// gate is applied to the *actions*.
    private var isUnlocked: Bool { AppLockService.shared.isUnlocked }

    /// Run `body` behind the app lock, reusing the unlocked window.
    private func gated(reason: String, _ body: @escaping @MainActor () -> Void) {
        if isUnlocked {
            body()
            return
        }
        authenticating(reason: reason, body)
    }

    /// Run `body` behind the app lock, ALWAYS authenticating first (no
    /// unlocked-window shortcut) — for destructive or bulk-disclosure
    /// actions. `AppLockService.gate` passes straight through when the lock
    /// is disabled or unavailable.
    private func authenticating(reason: String, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            // `gate` opens the shared unlock window on success.
            guard await AppLockService.shared.gate(reason: reason) else { return }
            body()
        }
    }

    init(store: ClipStore, watcher: PasteboardWatcher, pasteService: PasteService, panelController: PanelController) {
        self.store = store
        self.watcher = watcher
        self.pasteService = pasteService
        self.panelController = panelController
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.title = ""
        // The menu MUST be installed on the status item, not on its button.
        // `button.menu` is only NSView's contextual (right-click) menu, and
        // the status-bar button has no target/action of its own — so a plain
        // left click on the icon did nothing at all. NSStatusItem pops the
        // menu from its own `menu` property.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        panelController.statusItemButtonFrame = { [weak self] in
            guard let button = self?.statusItem.button, let window = button.window else {
                return .zero
            }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
    }

    // MARK: Icon

    func updateIcon() {
        guard let button = statusItem.button else { return }
        // Paused keeps an SF Symbol: it is a *state* the user needs to read at
        // a glance, and the brand mark dimmed or badged would say it far less
        // clearly than the system's own pause glyph. Running shows the logo.
        if watcher.isPaused {
            let image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: loc("MemoryClip (paused)"))
            image?.isTemplate = true
            button.image = image
        } else {
            button.image = BrandMark.menuBarImage()
        }
    }

    // MARK: Menu construction

    func menuWillOpen(_ menu: NSMenu) {
        // Remember which app owned focus so paste can restore it.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            frontmostAtMenuOpen = frontmost
        } else {
            frontmostAtMenuOpen = nil
        }

        menu.removeAllItems()

        // A header rather than a bare run of rows: without it the top of the
        // menu is five lines of arbitrary text sitting directly above a list
        // of commands, and nothing says the two halves are different kinds of
        // thing. Shown even when the list is empty, so the menu keeps one
        // shape and the placeholder underneath reads as an answer to it.
        menu.addItem(.sectionHeader(title: loc("Recent Clips")))

        // When the app lock is on and the unlocked window has expired the
        // titles are redacted — the dropdown would otherwise show 48
        // characters of every recent clip (enough for a whole password) with
        // no authentication at all. The paste action itself is gated too.
        let redacted = !isUnlocked
        let recent = store.recent(limit: 5)
        if recent.isEmpty {
            let placeholder = NSMenuItem(title: loc("No clips yet"), action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        } else {
            for item in recent {
                let menuItem = NSMenuItem(
                    title: Self.menuTitle(for: item, redacted: redacted),
                    action: #selector(pasteRecent(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                // Store the id, never the model: the menu can stay open for
                // minutes while the watcher keeps capturing, and enforceCap
                // can delete these very items underneath it.
                menuItem.representedObject = item.uuid
                menu.addItem(menuItem)
            }
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: loc("Open MemoryClip"), action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let pauseItem = NSMenuItem(
            title: watcher.isPaused ? loc("Resume Capture") : loc("Pause Capture"),
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        pauseItem.state = watcher.isPaused ? .on : .off
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: loc("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Deleting the whole history is the one irreversible thing this menu
        // does, so it is kept out of the run above: Pause Capture is the item
        // people come here to click, and a destructive row directly beneath it
        // is one slipped pointer away. Here it has a separator between itself
        // and everything frequent, Settings above, and Quit across another
        // separator below.
        let nukeItem = NSMenuItem(title: loc("Clear All History…"), action: #selector(nukeHistory), keyEquivalent: "")
        nukeItem.target = self
        menu.addItem(nukeItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: loc("Quit MemoryClip"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Longest clip preview shown in a dropdown title.
    static let menuTitleLimit = 48

    /// Title for a quick-history row. `redacted` renders the clip's *kind*
    /// only, so a locked MemoryClip never puts clip contents on screen.
    static func menuTitle(for item: ClipItem, redacted: Bool = false) -> String {
        guard !redacted else {
            switch item.kind {
            case .text: return loc("Text clip")
            case .richText: return loc("Rich text clip")
            case .link: return loc("Link")
            case .image: return loc("Image")
            case .file: return loc("File")
            case .color: return loc("Color")
            }
        }
        switch item.kind {
        case .text, .richText, .link:
            let flattened = (item.text ?? "")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let title = String(flattened.prefix(menuTitleLimit))
            return title.isEmpty ? loc("Clip") : title
        case .image:
            return loc("Image")
        case .file:
            // Through `ClipDisplay`, which decodes first: the dropdown is
            // where a screenshot's stored name is most visible, and taking
            // the last component off the raw `absoluteString` put
            // "Screenshot%202026-08-16%20at%2019.16.06.png" in the menu.
            let title = ClipDisplay.displayNames(item.fileURLStrings)
            return title.isEmpty ? loc("File") : title
        case .color:
            return loc("Color %@", item.colorHex ?? "")
        }
    }

    // MARK: Menu actions

    @objc private func pasteRecent(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? UUID else { return }
        let target = frontmostAtMenuOpen
        gated(reason: loc("Unlock MemoryClip to paste a clip")) { [weak self] in
            self?.performPaste(uuid: uuid, target: target)
        }
    }

    /// Re-resolve the clip by id at click time: the model captured when the
    /// menu was built may have been deleted by cap/retention enforcement
    /// while the menu sat open, and pasting a deleted model is a crash
    /// waiting to happen.
    private func performPaste(uuid: UUID, target: NSRunningApplication?) {
        guard let item = store.items(withUUIDs: [uuid]).first, !item.isDeleted else {
            log.notice("Menu paste skipped: the clip no longer exists")
            return
        }
        pasteService.paste(item, plainOnly: false, target: target)
    }

    @objc private func openPanel() {
        // Routed through PanelController.show(), which applies the Touch ID
        // gate before the panel (and thus history) becomes visible.
        panelController.show()
    }

    // The whole-history export used to live here, as two more dropdown items.
    // It is a rare, bulk-disclosure action rather than quick access to a
    // recent clip, so it moved to Settings → History; see
    // `HistoryExportController`, which took the confirmation alert, the
    // always-authenticate gate and the paged writer with it.

    @objc private func togglePause() {
        watcher.isPaused.toggle()
        updateIcon()
    }

    @objc private func nukeHistory() {
        NSApp.activate()
        // Destructive and irreversible — always behind the lock.
        authenticating(reason: loc("Unlock MemoryClip to delete clipboard history")) { [weak self] in
            self?.confirmNuke()
        }
    }

    private func confirmNuke() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc("Delete entire clipboard history?")
        alert.informativeText = loc("This permanently removes all clips, including pinned ones.")
        alert.addButton(withTitle: loc("Delete Everything"))
        alert.addButton(withTitle: loc("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.nukeAll()
        }
    }

    @objc private func openSettings() {
        openSettingsWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
