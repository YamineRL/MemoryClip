import AppKit
import KeyboardShortcuts

enum SettingsKeys {
    static let historyCap: String = "historyCap"
    static let retentionDays: String = "retentionDays"
    static let autoPaste: String = "autoPaste"
    static let vimMode: String = "vimMode"
    static let appearance: String = "appearance"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: ClipStore!
    private(set) var watcher: PasteboardWatcher!
    private(set) var pasteService: PasteService!
    private(set) var panelController: PanelController!
    private(set) var statusController: StatusController!
    private(set) var ocrCoordinator: OCRCoordinator!

    /// The deferred first maintenance pass (see `scheduleMaintenance`).
    private var maintenanceTask: Task<Void, Never>?

    /// How long after launch maintenance starts. Long enough for the status
    /// item, hot key and first paint to be in place; short enough that an
    /// expired clip is never visible for long.
    static let maintenanceStartDelay: Duration = .seconds(2)

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            SettingsKeys.historyCap: 200,
            SettingsKeys.retentionDays: 30,
            SettingsKeys.autoPaste: true,
            SettingsKeys.vimMode: false
        ])

        // Phase-2 defaults: sensitive-content filter (on) and app lock (off).
        SensitiveFilter.registerDefaults()
        AppLockService.registerDefaults()

        // Phase-3 default: on-device OCR of image clips (on).
        OCRCoordinator.registerDefaults()

        // Appearance override (System/Light/Dark), applied before any window
        // exists so the first paint is already in the chosen appearance.
        AppearanceSetting.registerDefaults()
        applyAppearanceSetting()

        _ = NSApp.setActivationPolicy(.accessory)

        guard let store = makeStore() else {
            NSApp.terminate(nil)
            return
        }
        self.store = store

        watcher = PasteboardWatcher(store: store)
        pasteService = PasteService(store: store, watcher: watcher)
        ocrCoordinator = OCRCoordinator(store: store)
        panelController = PanelController(store: store, pasteService: pasteService, watcher: watcher)
        statusController = StatusController(
            store: store,
            watcher: watcher,
            pasteService: pasteService,
            panelController: panelController
        )

        watcher.sourceAppProvider = { [weak self] in
            self?.panelController.previousApp
        }

        watcher.onCapture = { [weak self] kind in
            guard kind == .image else { return }
            self?.ocrCoordinator.processPending()
        }

        watcher.start()
        // Catch up on images captured while OCR was off or the app was down.
        ocrCoordinator.processPending()
        // Retention + cap enforcement — deferred off the launch path, then
        // periodic (not just once at launch: this agent can stay resident for
        // weeks).
        scheduleMaintenance()
        log.notice("MemoryClip started")

        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panelController.toggle()
            }
        }

        // Phase-4 polish: the first-run tour (shown once; re-openable from Settings).
        OnboardingController.shared.showIfFirstRun()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        watcher?.stop()
        ocrCoordinator?.stop()
        // Stop any in-flight queue run before the services it drives go away.
        panelController?.cancelQueue()
        store?.stopMaintenance()
    }

    // MARK: - Maintenance

    /// Start maintenance *after* the UI exists.
    ///
    /// `store.startMaintenance()` (retention, cap trimming and the thumbnail
    /// backfill) used to run synchronously inside
    /// `applicationDidFinishLaunching`, before the menu-bar item was created —
    /// so every one of those passes was launch latency the user waited on
    /// with no window and no menu-bar icon to show for it. Retention alone was
    /// 3.16 s against 24,080 expiring rows. None of it is urgent: an expired
    /// clip surviving two more seconds is invisible, whereas a menu bar that
    /// takes three seconds to appear is not.
    private func scheduleMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = Self.scheduleMaintenance(for: store, after: Self.maintenanceStartDelay)
    }

    /// Run the store's maintenance (and start its timer) after `delay`.
    ///
    /// Returns the task so the caller can cancel it — a quit during the delay
    /// must not start a fresh 15-minute timer on the way out.
    static func scheduleMaintenance(for store: ClipStore, after delay: Duration) -> Task<Void, Never> {
        Task { @MainActor [weak store] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let store else { return }
            store.startMaintenance()
        }
    }

    // MARK: - Store creation & recovery

    /// Open the store, recovering from failure instead of crashing.
    ///
    /// A `fatalError` here used to make any corrupt store, failed migration
    /// or full disk a permanent launch crash — and MemoryClip is an LSUIElement
    /// agent with no window, so the user saw nothing but a crash report.
    /// Returns nil only if even an in-memory container cannot be built.
    private func makeStore() -> ClipStore? {
        do {
            return try ClipStore()
        } catch {
            log.error("ClipStore open failed: \(error.localizedDescription)")
            return recoverStore(after: error)
        }
    }

    private func recoverStore(after error: Error) -> ClipStore? {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "MemoryClip could not open its clipboard history."
        alert.informativeText = """
            \(error.localizedDescription)

            You can move the damaged history aside and start a new one (the \
            old files are kept, not deleted), or run this session without \
            saving anything to disk.
            """
        alert.addButton(withTitle: "Reset History")
        alert.addButton(withTitle: "Run Without Saving")

        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                let quarantine = try ClipStore.moveStoreAside()
                log.notice("Moved damaged store aside to \(quarantine.lastPathComponent)")
                return try ClipStore()
            } catch {
                log.error("Store reset failed: \(error.localizedDescription)")
            }
        }

        // Last resort: run in memory so the app still works this session.
        do {
            let store = try ClipStore(inMemory: true)
            log.error("Running with an in-memory store; history will not persist")
            return store
        } catch {
            log.error("In-memory fallback failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Opens (or brings forward) the SwiftUI Settings window.
///
/// This is harder than it looks in an `.accessory` app. Three things bite:
///
/// 1. The only caller is the status-bar menu item, which fires while the menu
///    is still tearing down. Activation requests made in that window are
///    dropped, so the work is deferred one runloop turn.
/// 2. `sendAction(_:to:nil:from:)` walks the responder chain from the key
///    window. MemoryClip usually has *no* key window (the panel is ordered out on
///    resign-active), so the chain has nothing that answers
///    `showSettingsWindow:` and the send silently fails — which is exactly the
///    intermittent "Settings does nothing" bug. ⌘, never hit this because
///    AppKit dispatches the main-menu item straight to SwiftUI's own target.
/// 3. `PanelController.hide` can leave the app hidden via `NSApp.hide`, and a
///    hidden app will not order new windows in.
@MainActor
func openSettingsWindow() {
    // (1) Let the status menu finish dismissing before touching activation.
    DispatchQueue.main.async {
        // (3) Undo any lingering `NSApp.hide` before asking for a window.
        NSApp.unhide(nil)
        NSApp.activate()

        // (2) Try the modern selector, then the pre-Sonoma spelling. Both
        // return false when the responder chain has no settings target.
        let opened =
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            || NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)

        if !opened {
            log.error("Settings window action found no responder")
        }

        // Fronting has to wait for SwiftUI to actually build the window, and
        // an accessory app's fresh window can otherwise come up behind the
        // app that was frontmost.
        DispatchQueue.main.async {
            guard let window = settingsWindow() else {
                if !opened { log.error("Settings window never appeared") }
                return
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// The SwiftUI-managed Settings window, if it currently exists.
///
/// SwiftUI tags it with a stable private identifier; the title match is a
/// belt-and-braces fallback in case that identifier ever changes.
@MainActor
private func settingsWindow() -> NSWindow? {
    NSApp.windows.first { window in
        window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
            || window.frameAutosaveName == "com_apple_SwiftUI_Settings_window"
    }
}
