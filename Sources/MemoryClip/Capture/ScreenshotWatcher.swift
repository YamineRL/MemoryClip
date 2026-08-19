import Foundation
import OSLog

/// Notices screenshots as they land on disk and records each one as a clip.
///
/// ⇧⌘3/4/5 write a FILE and never touch the pasteboard, so `PasteboardWatcher`
/// is structurally blind to the way most screenshots are actually taken — only
/// ⌃⇧⌘4 ("copy to clipboard") ever reaches it. This watcher closes that gap by
/// watching the folder `screencapture` writes to.
///
/// What lands in the store is a *reference*: `ClipStore.insertScreenshot`
/// keeps the file URL and leaves `imageData` empty, so a captured screenshot
/// costs a thumbnail rather than its ~1.3 MB of pixels, and the file stays the
/// user's. Nothing here ever copies image bytes.
///
/// Three properties are worth stating up front, because they are what the rest
/// of the file is arranged around:
///
/// - **It never imports history.** A `screenshotLastSeen` mark in UserDefaults
///   is set to "now" the first time the feature is enabled, so switching it on
///   does not sweep in a Desktop's worth of old shots, and a relaunch does not
///   replay what was already captured.
/// - **It waits for the file to finish being written.** A screenshot's path
///   exists before its bytes do; see `isStable(previousSize:currentSize:)`.
/// - **The decisions are pure.** "Which of these entries should be captured",
///   "has the mark earned the right to advance", "how long before retrying"
///   are `nonisolated static` functions of their inputs, so the interesting
///   behaviour is testable without a real folder or a real screenshot.
@MainActor
final class ScreenshotWatcher {
    /// UserDefaults key for the "watch for screenshots" setting.
    nonisolated static let enabledKey = NoteSettingsKeys.screenshotCaptureEnabled

    /// Whether the user has switched screenshot watching on. The `false`
    /// default is registered by `NoteSettingsKeys.registerDefaults()`: this
    /// feature needs a folder the user has to grant access to, so it cannot
    /// be on out of the box.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// How long the folder has to go quiet before a scan runs.
    ///
    /// One screenshot is several vnode events on the directory (the entry
    /// appears, the bytes are written, the ` (2)` collision rename), and a
    /// ⇧⌘5 recording flushes even more. Scanning per event would enumerate
    /// the folder half a dozen times for one file; 400 ms folds a burst into
    /// a single pass while still feeling immediate.
    nonisolated static let debounceInterval: Duration = .milliseconds(400)

    /// How long to wait before re-measuring a candidate's size.
    ///
    /// The first vnode event arrives when the directory entry is created,
    /// which is *before* `screencapture` has written the PNG — capturing then
    /// yields a 0-byte or half-encoded file that OCR and thumbnailing both
    /// choke on. Measured on an M1 Pro, a full-screen PNG (~1.3 MB) is
    /// complete within ~60 ms of the entry appearing; 250 ms covers a 6K
    /// display and a slow external disk without making capture feel laggy.
    nonisolated static let stabilityInterval: Duration = .milliseconds(250)

    /// Ceiling on how many files one pass may capture.
    ///
    /// This bounds the catch-up on launch, which is the only pass that can
    /// face a large backlog: someone who took 300 screenshots with the app
    /// closed wants their recent ones, not a 300-row import that evicts the
    /// rest of their clipboard history through `enforceCap`. Newest first, so
    /// the bound drops the least interesting files.
    nonisolated static let maxCapturesPerPass = 20

    /// Longest wait between attempts to re-open a folder that has gone away.
    nonisolated static let maxReopenDelay: Duration = .seconds(30)

    /// The folder to watch: the one the user picked, else the one
    /// `screencapture` is configured to write to.
    ///
    /// The bookmark wins because it is the only one that carries *access*.
    /// `ScreenshotDetector.configuredLocation()` is a path read out of another
    /// app's preferences; it tells us where to look but grants nothing, and
    /// under TCC (or a future sandbox) reading `~/Desktop` on that basis alone
    /// gets a silent denial rather than files.
    nonisolated static func resolvedFolder() -> URL {
        FolderBookmark.resolve(key: NoteSettingsKeys.screenshotFolderBookmark)
            ?? ScreenshotDetector.configuredLocation()
    }

    /// Called on the main actor after each screenshot is stored. Wired by
    /// AppDelegate to kick off the downstream work (OCR, then optionally a
    /// note) for the clip that was just captured.
    var onCapture: (@MainActor (ClipItem) -> Void)?

    private let store: ClipStore

    /// The folder currently being watched. Re-resolved on start, on
    /// `folderDidChange()`, and before every re-open attempt — the bookmark
    /// may now point somewhere else, which is the whole reason a re-open is
    /// happening.
    private var folder: URL

    /// The live vnode source. The file descriptor it watches is owned by its
    /// cancel handler, which is the only thing that closes it.
    private var source: (any DispatchSourceFileSystemObject)?

    /// The debounce-then-scan task. Non-nil means a pass is pending or
    /// running; `rescanRequested` is how events arriving mid-pass are folded
    /// into exactly one follow-up rather than cancelling work in flight.
    private var scanTask: Task<Void, Never>?
    private var rescanRequested = false

    private var reopenTask: Task<Void, Never>?
    private var reopenAttempt = 0

    /// Files captured since the last pass that left nothing deferred.
    ///
    /// Only load-bearing while the mark is pinned behind a file that is still
    /// settling (see `advancedMark`): until it can move, the next pass sees
    /// the files it just captured as new again. Cleared as soon as the mark
    /// covers everything, so this never grows into a second history.
    private var recentlyCaptured: Set<URL> = []

    /// Whether `start()` has been called without a matching `stop()`. The
    /// setting observer outlives `stop()` (it is only torn down in `deinit`),
    /// so without this a defaults change during app teardown would re-open a
    /// descriptor nobody is going to close.
    private var isStarted = false

    /// Watches the enabled setting so toggling it in Settings takes effect
    /// immediately rather than at the next launch. `nonisolated(unsafe)` only
    /// so `deinit` can unregister it; written once in `init` and never
    /// mutated after.
    private nonisolated(unsafe) var settingsObserver: (any NSObjectProtocol)?
    private var lastKnownEnabled: Bool

    init(store: ClipStore) {
        self.store = store
        self.folder = Self.resolvedFolder()
        self.lastKnownEnabled = Self.isEnabled
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.settingDidChange()
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        // The descriptor cannot be closed from here: `source` is main-actor
        // state and `deinit` is not. `stop()` is the owner's job (AppDelegate
        // calls it on termination), and the watcher lives as long as the app
        // does, so there is no window where a descriptor outlives its watcher.
    }

    // MARK: - Lifecycle

    /// Begin watching, if the feature is switched on.
    ///
    /// Safe to call when the setting is off: the call is remembered, and the
    /// watch begins the moment the user enables it.
    func start() {
        isStarted = true
        guard Self.isEnabled else { return }
        guard source == nil else { return }

        folder = Self.resolvedFolder()
        seedLastSeenIfNeeded()
        openSource()
        // Catch up before the first event: screenshots taken while the app
        // was closed are exactly what the mark exists to make recoverable.
        // Only once the folder is actually open, though — a scan is a
        // directory listing, which is the other way to raise the prompt
        // `openSource` just declined to raise.
        if source != nil { scheduleScan() }
    }

    /// Stop watching and release the descriptor.
    func stop() {
        isStarted = false
        stopWatching()
    }

    /// Tear the watch down without forgetting that the app wants it running.
    /// Switching the setting off goes through here, so switching it back on
    /// re-enters `start()` rather than needing the app to ask again.
    private func stopWatching() {
        closeSource()
        scanTask?.cancel()
        scanTask = nil
        rescanRequested = false
        reopenTask?.cancel()
        reopenTask = nil
        reopenAttempt = 0
        recentlyCaptured.removeAll()
    }

    /// Re-point the watcher after the user picks a different folder in
    /// Settings.
    ///
    /// Picking a new folder resets the mark to "now": that folder's existing
    /// contents are history the user never asked to import, exactly as on
    /// first enable. Re-picking the SAME folder (which is what happens when
    /// someone re-grants access after a TCC reset) leaves the mark alone, so
    /// screenshots taken in the meantime are still caught up.
    func folderDidChange() {
        let resolved = Self.resolvedFolder()
        let isDifferentFolder = resolved.standardizedFileURL != folder.standardizedFileURL
        folder = resolved
        if isDifferentFolder {
            Self.recordLastSeen(.now)
            recentlyCaptured.removeAll()
            log.notice("Screenshot folder changed to \(resolved.path, privacy: .private)")
        }
        guard isStarted, Self.isEnabled else { return }
        closeSource()
        openSource()
        if source != nil { scheduleScan() }
    }

    private func settingDidChange() {
        let enabled = Self.isEnabled
        // Compare rather than react: this fires for EVERY defaults write in
        // the app (appearance, OCR, note destination), and re-opening the
        // vnode source on each one would churn a descriptor for nothing.
        guard enabled != lastKnownEnabled else { return }
        lastKnownEnabled = enabled
        guard isStarted else { return }
        if enabled {
            start()
        } else {
            stopWatching()
        }
    }

    // MARK: - The vnode source

    /// Open the folder and arm a source on it.
    private func openSource() {
        closeSource()

        // Ask before opening. `open` on a folder macOS guards is what puts a
        // consent dialog on screen, and this runs at launch — so without the
        // check the user meets a cold prompt with no explanation, seconds
        // before the window whose whole job is to explain it. `FolderAccess`
        // answers the same question silently; a refusal is left for that
        // window to offer, and `folderDidChange()` starts the watcher once the
        // grant comes back.
        // Opening a folder macOS guards is what puts a consent dialog on
        // screen, and this runs at launch — so it is gated on the ledger,
        // which is the only thing that answers "may we" without asking. An
        // unrecorded folder is left shut for the permission window to offer;
        // `folderDidChange()` starts the watcher the moment a grant lands, so
        // nothing here has to poll for one.
        guard !FolderAccess.isGuarded(folder) || PermissionLedger().worksUnderThisBuild(.filesAndFolders) else {
            log.notice("Not watching the screenshot folder: no folder access recorded for this build")
            return
        }

        // `O_EVTONLY` asks for a descriptor for event delivery only: it does
        // not count as a reference that would keep an unmounting volume busy,
        // which matters when the screenshot folder is on an external disk.
        let descriptor = FolderBookmark.withAccess(to: folder) {
            open(folder.path, O_EVTONLY)
        }
        guard descriptor >= 0 else {
            log.error("Could not watch screenshot folder \(self.folder.path, privacy: .private)")
            scheduleReopen()
            return
        }

        // The open succeeded, so the grant is real and belongs in the ledger:
        // TCC will not tell an app what it was allowed to do under a signature
        // it no longer has, and this is the moment the answer is known.
        PermissionLedger().noteGranted(.filesAndFolders)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            // Main queue because everything the handler goes on to touch —
            // the store, the debounce state, the callback — is main-actor
            // isolated. The work it schedules is a folder listing, not the
            // capture itself.
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleEvents() }
        }
        // The single owner of the descriptor. A cancel handler runs exactly
        // once per source, which is what makes this the one and only `close`
        // — closing in `closeSource` as well would risk shutting a number the
        // kernel has since handed to somebody else.
        source.setCancelHandler { close(descriptor) }
        source.resume()

        self.source = source
        reopenAttempt = 0
        log.notice("Watching screenshot folder \(self.folder.path, privacy: .private)")
    }

    private func closeSource() {
        guard let source else { return }
        self.source = nil
        source.cancel()
    }

    private func handleEvents() {
        guard let flags = source?.data else { return }
        // `.rename` and `.delete` here are about the WATCHED FOLDER itself,
        // not its contents (a file appearing, changing or being renamed
        // inside it all arrive as `.write` on the directory). The descriptor
        // now tracks a vnode that is no longer at this path, so it would keep
        // reporting events for a folder the user cannot see — or go silent
        // forever. Re-resolve and re-open instead.
        if flags.contains(.rename) || flags.contains(.delete) {
            log.notice("Screenshot folder moved or was deleted; re-opening")
            scheduleReopen()
            return
        }
        scheduleScan()
    }

    /// Try again later, with a backoff, after the folder went away.
    ///
    /// A folder can be missing for a long time (an unmounted volume, a Desktop
    /// mid-restore), so this retries rather than giving up — silently stopping
    /// is the failure mode this feature can least afford, since nothing in the
    /// UI would tell the user their screenshots stopped being captured.
    private func scheduleReopen() {
        closeSource()
        guard isStarted, Self.isEnabled else { return }
        guard reopenTask == nil else { return }

        reopenAttempt += 1
        let delay = Self.reopenDelay(forAttempt: reopenAttempt)
        reopenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.reopenTask = nil
            guard self.isStarted, Self.isEnabled else { return }
            // Re-resolve: the bookmark follows a folder that was moved, so
            // the retry is often for a different path than the one that died.
            self.folder = Self.resolvedFolder()
            self.openSource()
            if self.source != nil { self.scheduleScan() }
        }
    }

    // MARK: - Scanning

    /// Queue a pass, coalescing everything that arrives in the meantime.
    private func scheduleScan() {
        guard scanTask == nil else {
            // A pass is already pending or running. Cancelling it to restart
            // the debounce would mean a steady trickle of events could starve
            // capture entirely, and cancelling one mid-run would abandon its
            // settle wait; note the request and let it re-arm at the end.
            rescanRequested = true
            return
        }
        scanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard let self, !Task.isCancelled else { return }
            let deferredWork = await self.runScan()
            guard !Task.isCancelled else { return }
            self.scanTask = nil
            // Re-arm for files that were still being written, and for events
            // that landed while this pass was running.
            if deferredWork || self.rescanRequested {
                self.rescanRequested = false
                self.scheduleScan()
            }
        }
    }

    /// One pass: list, filter, wait for the candidates to settle, store.
    /// - Returns: true when at least one candidate was left for a later pass.
    private func runScan() async -> Bool {
        guard Self.isEnabled else { return false }
        let folder = self.folder
        // The mark is seeded on start, so the fallback is only reached if the
        // defaults were wiped mid-run; "now" is the safe reading of a missing
        // mark, since it imports nothing.
        let mark = Self.lastSeen ?? .now
        let namePrefix = ScreenshotDetector.namePrefix()
        let known = recentlyCaptured

        // Security scope held across the listing AND the screenshot test:
        // both read file metadata, and `isScreenshot` additionally asks
        // Spotlight about the file, which needs the same access.
        let candidates = FolderBookmark.withAccess(to: folder) {
            Self.entriesToCapture(
                from: Self.directoryEntries(of: folder),
                after: mark,
                limit: Self.maxCapturesPerPass
            )
            .filter { entry in
                guard !known.contains(entry.url) else { return false }
                return ScreenshotDetector.isScreenshot(at: entry.url, namePrefix: namePrefix)
            }
        }
        guard !candidates.isEmpty else { return false }

        try? await Task.sleep(for: Self.stabilityInterval)
        guard !Task.isCancelled, Self.isEnabled else { return false }

        var capturedDates: [Date] = []
        var capturedURLs: [URL] = []
        var deferredDates: [Date] = []

        FolderBookmark.withAccess(to: folder) {
            // Oldest first: the selection above is newest-first (that is what
            // the bound has to drop from), but storing in that order would
            // interleave a catch-up batch backwards against anything the user
            // copies while it runs.
            for entry in candidates.reversed() {
                let currentSize = ScreenshotDetector.fileSize(of: entry.url)
                guard Self.isStable(previousSize: entry.size, currentSize: currentSize) else {
                    deferredDates.append(entry.timestamp)
                    continue
                }
                // `createdAt` is the file's own timestamp, not "now": a
                // screenshot taken while the app was closed belongs in the
                // list where it happened, not at the top of it.
                guard let clip = store.insertScreenshot(at: entry.url, createdAt: entry.timestamp) else {
                    continue
                }
                capturedDates.append(entry.timestamp)
                capturedURLs.append(entry.url)
                // The file name is logged `.private`: it is chosen by the
                // user or by the window they shot ("Screenshot … at 14.02
                // — Payroll.png"), and the unified log outlives `nukeAll`.
                log.notice("Captured screenshot \(entry.url.lastPathComponent, privacy: .private)")
                onCapture?(clip)
            }
        }

        let advanced = Self.advancedMark(from: mark, captured: capturedDates, deferred: deferredDates)
        if advanced > mark { Self.recordLastSeen(advanced) }
        if deferredDates.isEmpty {
            // The mark now covers everything seen this pass, so the
            // belt-and-braces set has nothing left to protect against.
            recentlyCaptured.removeAll()
        } else {
            recentlyCaptured.formUnion(capturedURLs)
        }
        return !deferredDates.isEmpty
    }

    // MARK: - The "already seen" mark

    /// Timestamp of the newest screenshot already handled, or nil before the
    /// feature has ever been switched on.
    nonisolated static var lastSeen: Date? {
        UserDefaults.standard.object(forKey: NoteSettingsKeys.screenshotLastSeen) as? Date
    }

    nonisolated static func recordLastSeen(_ date: Date) {
        UserDefaults.standard.set(date, forKey: NoteSettingsKeys.screenshotLastSeen)
    }

    /// Set the mark to "now" the first time the watcher runs, so enabling the
    /// feature captures what happens NEXT rather than everything on the
    /// Desktop since 2019.
    private func seedLastSeenIfNeeded() {
        guard Self.lastSeen == nil else { return }
        Self.recordLastSeen(.now)
    }

    // MARK: - Pure decisions

    /// One directory entry, reduced to the three facts the decisions need.
    ///
    /// Deliberately not a `URL` plus lazy lookups: every field here comes out
    /// of the prefetched resource values of a single directory listing, so a
    /// pass costs one `getattrlistbulk` rather than three `stat`s per file.
    nonisolated struct Entry: Sendable, Equatable {
        let url: URL
        /// Creation date, falling back to modification date.
        let timestamp: Date
        /// Size in bytes at listing time.
        let size: Int
    }

    /// List `folder`, one level deep, with the metadata the pass needs.
    ///
    /// `contentsOfDirectory` never descends, and asking for the three keys up
    /// front lets the file system return them with the listing instead of
    /// faulting each one in on first access. Hidden files are skipped:
    /// `screencapture` writes nothing hidden, and `.DS_Store` churn is a
    /// meaningful share of the events this folder produces.
    ///
    /// Entries with no size (directories, and bundles such as `.screenflow`)
    /// drop out here rather than needing a separate `isDirectory` probe.
    nonisolated static func directoryEntries(
        of folder: URL,
        fileManager: FileManager = .default
    ) -> [Entry] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            log.error("Could not list screenshot folder \(folder.path, privacy: .private)")
            return []
        }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            guard let size = values.fileSize else { return nil }
            guard let timestamp = values.creationDate ?? values.contentModificationDate else { return nil }
            return Entry(url: url, timestamp: timestamp, size: size)
        }
    }

    /// Which entries this pass should consider, newest first and bounded.
    ///
    /// - Parameter after: the mark. Strictly greater, so a re-run over an
    ///   unchanged folder captures nothing — `>=` would re-capture the newest
    ///   file on every single event.
    /// - Parameter limit: hard bound, applied AFTER sorting so a backlog
    ///   yields the newest `limit` files rather than an arbitrary `limit`.
    ///
    /// Zero-byte entries are dropped rather than deferred: that is the shape
    /// of a screenshot whose bytes have not arrived yet, and the next event
    /// on the folder brings it back with a real size.
    nonisolated static func entriesToCapture(
        from entries: [Entry],
        after mark: Date,
        limit: Int
    ) -> [Entry] {
        guard limit > 0 else { return [] }
        return entries
            .filter { $0.size > 0 && $0.timestamp > mark }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    /// Whether a candidate has finished being written.
    ///
    /// Two measurements a `stabilityInterval` apart: same non-zero size means
    /// the encoder is done. `nil` means the file vanished between them (a
    /// screenshot the user deleted straight out of the notification thumbnail,
    /// or a temp file that got renamed into place), which is not stable and
    /// not worth capturing.
    nonisolated static func isStable(previousSize: Int, currentSize: Int?) -> Bool {
        guard let currentSize, currentSize > 0 else { return false }
        return currentSize == previousSize
    }

    /// Where the mark may move to after a pass.
    ///
    /// The mark is a *watermark*, not a cursor: everything at or before it is
    /// considered handled forever. So it may only advance past files that were
    /// actually captured, and never past one still settling — a screenshot
    /// that was mid-write while its slightly older neighbour was captured
    /// would otherwise fall behind the mark and never be looked at again.
    /// Hence the ceiling at the oldest deferred timestamp.
    ///
    /// Never moves backwards, so a file with a bogus future-then-corrected
    /// timestamp cannot reopen history.
    nonisolated static func advancedMark(
        from current: Date,
        captured: [Date],
        deferred: [Date]
    ) -> Date {
        let ceiling = deferred.min()
        let eligible = captured.filter { date in
            guard let ceiling else { return true }
            return date < ceiling
        }
        return ([current] + eligible).max() ?? current
    }

    /// Backoff before retrying a folder that could not be opened: 1s, 2s, 4s,
    /// 8s, 16s, then `maxReopenDelay` forever.
    ///
    /// Exponential because the two real causes have very different timescales
    /// — a folder being replaced by an atomic rename is back within a second,
    /// an unmounted volume may be gone for a day — and a fixed poll would have
    /// to pick one of them to be wrong about.
    nonisolated static func reopenDelay(forAttempt attempt: Int) -> Duration {
        guard attempt > 1 else { return .seconds(1) }
        let seconds = 1 << min(attempt - 1, 20)
        return min(.seconds(seconds), maxReopenDelay)
    }
}
