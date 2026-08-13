import AppKit
import SwiftData
import UniformTypeIdentifiers

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
            let image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "MemoryClip (paused)")
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

        // When the app lock is on and the unlocked window has expired the
        // titles are redacted — the dropdown would otherwise show 48
        // characters of every recent clip (enough for a whole password) with
        // no authentication at all. The paste action itself is gated too.
        let redacted = !isUnlocked
        let recent = store.recent(limit: 5)
        if recent.isEmpty {
            let placeholder = NSMenuItem(title: "No clips yet", action: nil, keyEquivalent: "")
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

        let openItem = NSMenuItem(title: "Open MemoryClip", action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let pauseItem = NSMenuItem(
            title: watcher.isPaused ? "Resume Capture" : "Pause Capture",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        pauseItem.state = watcher.isPaused ? .on : .off
        menu.addItem(pauseItem)

        let nukeItem = NSMenuItem(title: "Clear All History…", action: #selector(nukeHistory), keyEquivalent: "")
        nukeItem.target = self
        menu.addItem(nukeItem)

        menu.addItem(.separator())

        let exportJSONItem = NSMenuItem(title: "Export History as JSON…", action: #selector(exportHistoryAsJSON), keyEquivalent: "")
        exportJSONItem.target = self
        menu.addItem(exportJSONItem)

        let exportCSVItem = NSMenuItem(title: "Export History as CSV…", action: #selector(exportHistoryAsCSV), keyEquivalent: "")
        exportCSVItem.target = self
        menu.addItem(exportCSVItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit MemoryClip", action: #selector(quit), keyEquivalent: "q")
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
            case .text: return "Text clip"
            case .richText: return "Rich text clip"
            case .link: return "Link"
            case .image: return "Image"
            case .file: return "File"
            case .color: return "Color"
            }
        }
        switch item.kind {
        case .text, .richText, .link:
            let flattened = (item.text ?? "")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let title = String(flattened.prefix(menuTitleLimit))
            return title.isEmpty ? "Clip" : title
        case .image:
            return "Image"
        case .file:
            let names = item.fileURLStrings.map { ($0 as NSString).lastPathComponent }
            let title = names.joined(separator: ", ")
            return title.isEmpty ? "File" : title
        case .color:
            return "Color \(item.colorHex ?? "")"
        }
    }

    // MARK: Menu actions

    @objc private func pasteRecent(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? UUID else { return }
        let target = frontmostAtMenuOpen
        gated(reason: "Unlock MemoryClip to paste a clip") { [weak self] in
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

    // MARK: Export

    @objc private func exportHistoryAsJSON() {
        exportHistory(asCSV: false)
    }

    @objc private func exportHistoryAsCSV() {
        exportHistory(asCSV: true)
    }

    /// Authenticate, warn about what the file contains, then fetch the full
    /// history and write it via NSSavePanel.
    private func exportHistory(asCSV: Bool) {
        NSApp.activate()
        // Bulk disclosure of the entire history — always behind the lock.
        authenticating(reason: "Unlock MemoryClip to export clipboard history") { [weak self] in
            self?.performExport(asCSV: asCSV)
        }
    }

    /// Clips pulled from the store, encoded and flushed per pass.
    ///
    /// The export used to Base64-encode every blob into one array before
    /// writing anything: 500 image clips (642 MB of blobs) meant ~856 MB of
    /// Base64 strings live at once, plus the encoded document on top. Writing
    /// a page at a time bounds that to one page — 50 screenshots is ~85 MB.
    static let exportPageSize = 50

    /// Which half of the export failed, so the alert can say which.
    enum ExportFailure: Error {
        case fetch(any Error)
    }

    private func performExport(asCSV: Bool) {
        NSApp.activate()
        guard confirmExport(asCSV: asCSV) else { return }

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = asCSV ? "memoryclip-history.csv" : "memoryclip-history.json"
        savePanel.allowedContentTypes = asCSV ? [.commaSeparatedText] : [.json]
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        do {
            let count = try Self.writeExport(to: url, asCSV: asCSV, store: store)
            log.notice("Exported \(count) clips to \(url.lastPathComponent, privacy: .public)")
        } catch ExportFailure.fetch(let error) {
            // A partially written file is worse than none: it looks like a
            // complete history but silently stops part way.
            try? FileManager.default.removeItem(at: url)
            log.error("Export failed to fetch history: \(error.localizedDescription)")
            presentError(
                message: "Could not read the clipboard history.",
                informative: error.localizedDescription
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            log.error("Export failed: \(error.localizedDescription)")
            presentError(
                message: "Export failed.",
                informative: error.localizedDescription
            )
        }
    }

    /// Stream the history to `url` a page at a time. Returns the clip count.
    ///
    /// The output is byte-identical to encoding the whole history in one go
    /// (`ExportService.Stream` backs both paths).
    static func writeExport(to url: URL, asCSV: Bool, store: ClipStore) throws -> Int {
        let fileManager = FileManager.default
        // Created owner-only up front rather than chmod'd afterwards: the
        // file is the plaintext of the user's entire clipboard history and
        // must never exist, even briefly, as umask-default 0644.
        try? fileManager.removeItem(at: url)
        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var stream = ExportService.Stream(format: asCSV ? .csv : .json)
        try handle.write(contentsOf: Data(stream.header.utf8))

        var written = 0
        while true {
            var descriptor = FetchDescriptor<ClipItem>(
                sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
            )
            descriptor.fetchOffset = written
            descriptor.fetchLimit = Self.exportPageSize

            let page: [ClipItem]
            do {
                page = try store.context.fetch(descriptor)
            } catch {
                throw ExportFailure.fetch(error)
            }
            guard !page.isEmpty else { break }

            for item in page {
                let chunk = try stream.chunk(for: ExportService.export(from: item))
                try handle.write(contentsOf: Data(chunk.utf8))
            }
            written += page.count
            if page.count < Self.exportPageSize { break }
        }

        try handle.write(contentsOf: Data(stream.footer.utf8))
        try handle.synchronize()
        // Belt and braces: a pre-existing file's mode survives createFile on
        // some volumes.
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
        return written
    }

    /// Spell out exactly what the exported file contains before writing it.
    private func confirmExport(asCSV: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export your entire clipboard history?"
        let payload = asCSV
            ? "every clip's text, source app and timestamps"
            : "every clip's text, source app, timestamps and Base64 copies of image and rich-text clips"
        alert.informativeText = """
            The file is UNENCRYPTED plain text containing \(payload) — including any passwords, \
            tokens or other secrets you have copied.

            MemoryClip writes it readable by your user account only, but anyone who can open the file \
            can read your whole history. Store it somewhere you trust, or delete it when done.
            """
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentError(message: String, informative: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func togglePause() {
        watcher.isPaused.toggle()
        updateIcon()
    }

    @objc private func nukeHistory() {
        NSApp.activate()
        // Destructive and irreversible — always behind the lock.
        authenticating(reason: "Unlock MemoryClip to delete clipboard history") { [weak self] in
            self?.confirmNuke()
        }
    }

    private func confirmNuke() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete entire clipboard history?"
        alert.informativeText = "This permanently removes all clips, including pinned ones."
        alert.addButton(withTitle: "Delete Everything")
        alert.addButton(withTitle: "Cancel")
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
