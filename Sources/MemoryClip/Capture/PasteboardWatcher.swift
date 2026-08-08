import AppKit
import OSLog

/// Polls `NSPasteboard.changeCount` and hands new content to the store.
@MainActor
final class PasteboardWatcher {
    /// When true the watcher skips capture (user toggled pause).
    var isPaused: Bool = false

    /// Provides the app that owned focus before MemoryClip, so captures can record
    /// their source. Wired by AppDelegate to `PanelController.previousApp`.
    var sourceAppProvider: (@MainActor () -> NSRunningApplication?)?

    /// Called after a clip is stored. Wired by AppDelegate to kick off
    /// background OCR for freshly captured images (Phase 3).
    var onCapture: (@MainActor (ClipKind) -> Void)?

    private let store: ClipStore
    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    private var timer: Timer?

    /// - Parameter pasteboard: injectable so tests can drive the full capture
    ///   path against their own pasteboard instead of the user's clipboard.
    init(store: ClipStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        // Seed with the current count so content already on the clipboard at
        // launch is NOT captured.
        self.lastChangeCount = pasteboard.changeCount
    }

    /// Start polling the general pasteboard.
    func start() {
        stop()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stop polling and release the timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Record the current changeCount as "our own write" so the next poll
    /// doesn't capture what PasteService just put there.
    func noteOwnWrite() {
        lastChangeCount = pasteboard.changeCount
    }

    private func tick() {
        if isPaused {
            // Track the count while paused so resuming doesn't replay the
            // backlog that accumulated during the pause.
            lastChangeCount = pasteboard.changeCount
            return
        }

        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        let source = resolveSourceApp()
        capture(
            from: pasteboard,
            sourceBundleID: source?.bundleIdentifier,
            sourceAppName: source?.localizedName
        )
    }

    /// Parse, filter and (maybe) store one pasteboard snapshot.
    ///
    /// Internal rather than private so tests can exercise the REAL capture
    /// path — filter wiring included — instead of only the pure predicates.
    /// Returns true when a clip was stored.
    @discardableResult
    func capture(
        from pasteboard: NSPasteboard,
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> Bool {
        // Phase 2 sensitive-data guard: never capture from credential
        // managers. App-identity based (no window titles — we hold no
        // Accessibility/Screen Recording permissions; see SensitiveFilter).
        //
        // The app name is logged `.private`: the unified log keeps a durable,
        // timestamped record that survives nukeAll, and a public name would
        // turn it into a history of every time the user opened their password
        // manager plus an inventory of which ones are installed.
        if SensitiveFilter.isFilteringEnabled,
           SensitiveFilter.isBlocked(bundleID: sourceBundleID, name: sourceAppName) {
            log.notice(
                "Skipped capture: credential app (\(sourceAppName ?? "unknown", privacy: .private))"
            )
            return false
        }

        guard let clip = ContentParser.parse(pasteboard) else { return false }

        // Card check applies to EVERY kind that carries text. Restricting it
        // to .text/.link missed the common case: anything copied from an app
        // that also offers public.rtf (Safari, Notes, Mail, Word, Excel) is
        // classified .richText by ContentParser and would slip straight past.
        if SensitiveFilter.isFilteringEnabled,
           let text = clip.text, !text.isEmpty,
           SensitiveFilter.isLikelyCardNumber(text) {
            log.notice("Skipped capture: likely card number in \(clip.kind.rawValue, privacy: .public) clip")
            return false
        }

        store.insert(
            clip,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
        log.notice("Captured \(clip.kind.rawValue, privacy: .public) clip")
        onCapture?(clip.kind)
        return true
    }

    /// Best-effort resolution of the app the copy originated from.
    private func resolveSourceApp() -> NSRunningApplication? {
        if NSApp.isActive {
            // We are frontmost (panel/hotkey flow): ask for the previous app.
            return sourceAppProvider?()
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        if frontmost.bundleIdentifier == Bundle.main.bundleIdentifier {
            return sourceAppProvider?()
        }
        return frontmost
    }
}
