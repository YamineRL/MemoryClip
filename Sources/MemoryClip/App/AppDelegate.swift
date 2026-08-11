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

/// Opens (or brings forward) the Settings window.
///
/// The status menu item fires while the menu is still tearing down, and
/// activation requests made in that window are dropped, so the work is
/// deferred one runloop turn. Everything else lives in
/// `SettingsWindowController`.
@MainActor
func openSettingsWindow() {
    DispatchQueue.main.async {
        SettingsWindowController.shared.show()
    }
}
