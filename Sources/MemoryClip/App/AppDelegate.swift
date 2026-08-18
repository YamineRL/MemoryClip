import AppKit
import KeyboardShortcuts

enum SettingsKeys {
    static let historyCap: String = "historyCap"
    static let retentionDays: String = "retentionDays"
    static let autoPaste: String = "autoPaste"
    static let vimMode: String = "vimMode"
    static let appearance: String = "appearance"
    /// Which Settings pane was open last (a `SettingsPane` raw value).
    ///
    /// Lives here rather than in `NoteSettingsKeys` because it is a preference
    /// of the settings window itself, alongside `appearance`, not part of the
    /// screenshot → note pipeline those keys describe. Deliberately left out
    /// of `register(defaults:)`: the fallback belongs with the enum
    /// (`SettingsPane.default`), and registering a default here would mean two
    /// places to change if the first pane ever moves.
    static let settingsPane: String = "settingsPane"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: ClipStore!
    private(set) var watcher: PasteboardWatcher!
    private(set) var pasteService: PasteService!
    private(set) var panelController: PanelController!
    private(set) var statusController: StatusController!
    private(set) var ocrCoordinator: OCRCoordinator!
    private(set) var screenshotWatcher: ScreenshotWatcher!
    private(set) var noteCoordinator: NoteCoordinator!
    private(set) var calendarCoordinator: CalendarCoordinator!

    /// Answers the Undo and Open in Calendar buttons on the banner an
    /// automatically created event posts. Held for the life of the app
    /// because `UNUserNotificationCenter.delegate` is a weak reference.
    private var eventNotificationDelegate: EventNotificationDelegate?

    /// Watches for the user picking a different screenshot folder in
    /// Settings, so the watcher re-points without a relaunch.
    private var screenshotFolderObserver: (any NSObjectProtocol)?

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

        // Phase-5 defaults: screenshot capture (off — it needs a folder the
        // user has to grant access to), refinement (on) and automatic note
        // writing (off).
        NoteSettingsKeys.registerDefaults()

        // Calendar defaults: automatic creation (off) and its notification
        // (on). Registered here because the notification default is read as
        // false when its key was never registered, which would let an
        // automatically created event appear without saying so.
        CalendarSettingsKeys.registerDefaults()

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

        // The Settings window is built from plain SwiftUI structs that are
        // handed no services, so the History pane's export buttons reach the
        // store the way the About pane reaches the tour: through a singleton
        // controller. This is the one place that owns the store, so this is
        // the only place that can hand it over.
        HistoryExportController.shared.store = store

        watcher = PasteboardWatcher(store: store)
        pasteService = PasteService(store: store, watcher: watcher)
        ocrCoordinator = OCRCoordinator(store: store)
        screenshotWatcher = ScreenshotWatcher(store: store)
        noteCoordinator = NoteCoordinator(store: store)
        calendarCoordinator = CalendarCoordinator(store: store)
        panelController = PanelController(
            store: store,
            pasteService: pasteService,
            watcher: watcher,
            noteCoordinator: noteCoordinator,
            calendarCoordinator: calendarCoordinator
        )
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
            guard let self else { return }
            // An image carries no text yet, so it goes to recognition and the
            // calendar hears about it further down, from `onRecognition`.
            // Everything else arrives with whatever text it will ever have,
            // which makes capture the moment to look for an appointment in it.
            if kind == .image {
                self.ocrCoordinator.processPending()
            } else {
                self.offerNewestClipToCalendar()
            }
        }

        // A screenshot carries pixels exactly like a pasteboard image does —
        // it just keeps them on disk — so it joins the same recognition
        // queue, which is what feeds refinement and notes downstream.
        screenshotWatcher.onCapture = { [weak self] _ in
            self?.ocrCoordinator.processPending()
        }

        // …and recognised text hands on to refinement, which is what writes
        // the note. Without this the chain stopped at OCR: only the catch-up
        // call below ever started refinement, so a screenshot taken while the
        // app was running never became a note until the next launch.
        ocrCoordinator.onRecognition = { [weak self] recognized in
            guard let self else { return }
            self.noteCoordinator.processPending()
            // …and the same text is where a screenshot's appointment first
            // exists. Only the clips this batch produced text for are offered,
            // so nothing rescans the history.
            Task { @MainActor [weak self] in
                await self?.calendarCoordinator.autoCreateIfWanted(forClipsWith: recognized)
            }
        }

        // Registering the category and taking delivery of its buttons is all
        // that happens at launch; permission is asked for at the first banner
        // (see `EventNotifier`). Inert in a process with no bundle identifier,
        // which is every process that is not the built app.
        let notificationDelegate = EventNotificationDelegate(calendarCoordinator: calendarCoordinator)
        eventNotificationDelegate = notificationDelegate
        EventNotifier.install(delegate: notificationDelegate)

        screenshotFolderObserver = NotificationCenter.default.addObserver(
            forName: .memoryClipScreenshotFolderChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screenshotWatcher.folderDidChange()
            }
        }

        watcher.start()
        screenshotWatcher.start()
        // Catch up on images captured while OCR was off or the app was down.
        ocrCoordinator.processPending()
        // …and on text that was recognised but never refined, for the same
        // reason: the setting may have been off, or the app may have quit
        // mid-backlog.
        noteCoordinator.processPending()
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

        // An update is a new app to TCC, so the grants the last build had are
        // gone. Anything that was working and no longer is gets asked for
        // here, rather than failing silently at the next note or event. A
        // Mac that has lost nothing — including a first run, which has
        // nothing recorded yet — gets no window.
        PermissionRecoveryController.shared.showIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        watcher?.stop()
        screenshotWatcher?.stop()
        ocrCoordinator?.stop()
        noteCoordinator?.stop()
        if let screenshotFolderObserver {
            NotificationCenter.default.removeObserver(screenshotFolderObserver)
            self.screenshotFolderObserver = nil
        }
        // Stop any in-flight queue run before the services it drives go away.
        panelController?.cancelQueue()
        store?.stopMaintenance()
    }

    // MARK: - Calendar

    /// Offer the clip that was just captured to the calendar's automatic path.
    ///
    /// `PasteboardWatcher.onCapture` reports the *kind* it stored and
    /// `ClipStore.insert` hands nothing back, so the row is resolved here —
    /// and the newest row is it: capture is synchronous, this callback fires
    /// on the same actor immediately after the insert, and a duplicate paste
    /// floats the existing row to the top rather than adding a second one.
    ///
    /// The setting is read before the fetch as well as inside the coordinator,
    /// so that with the feature off — which is the default — a copy costs one
    /// `UserDefaults` read and no query at all.
    private func offerNewestClipToCalendar() {
        guard CalendarCoordinator.isAutoCreateEnabled,
              let item = store.recent(limit: 1).first else { return }
        Task { @MainActor [weak self] in
            await self?.calendarCoordinator.autoCreateIfWanted(for: item)
        }
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
        alert.messageText = loc("MemoryClip could not open its clipboard history.")
        alert.informativeText = loc(
            "%@\n\nYou can move the damaged history aside and start a new one (the old files are kept, not deleted), or run this session without saving anything to disk.",
            error.localizedDescription
        )
        alert.addButton(withTitle: loc("Reset History"))
        alert.addButton(withTitle: loc("Run Without Saving"))

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
/// The status menu item fires while its menu is still tracking, and an
/// activation request made in that window is dropped — the menu owns the
/// event loop, and when it finally lets go, macOS restores whichever app was
/// frontmost before the click. A window ordered in during that gets left
/// behind: on screen, in front, and not the key window, which is the exact
/// symptom of typing into a Settings pane and watching the keystrokes land
/// in Brave.
///
/// `DispatchQueue.main.async` looked like the deferral that avoids this and
/// is not: main-queue blocks drain in the run loop's COMMON modes, and
/// `NSEventTrackingRunLoopMode` is one of them, so the block ran inside the
/// very tracking loop it was meant to escape. `RunLoop.perform(inModes:)`
/// names the mode outright, and `.default` cannot run until tracking has
/// ended. Everything else lives in `SettingsWindowController`.
@MainActor
func openSettingsWindow() {
    RunLoop.main.perform(inModes: [.default]) {
        MainActor.assumeIsolated {
            SettingsWindowController.shared.show()
        }
    }
}
