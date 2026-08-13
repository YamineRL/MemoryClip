import AppKit
import Combine
import SwiftUI

/// Observable state shared between PanelController and the SwiftUI panel.
@MainActor
final class PanelUIState: ObservableObject {
    /// Changes whenever the panel should refocus its search field.
    @Published var focusToken = UUID()
    /// Mirrors PasteboardWatcher.isPaused for the UI.
    @Published var isPaused = false
    /// True while the preview pane is open, so the panel window can grow
    /// upward to make room for it. The panel's bottom edge stays anchored.
    @Published var isExpanded = false
}

/// NSPanel subclass that can take keyboard focus (for typing search terms).
///
/// `cancelOperation` is overridden so Esc always dismisses the window, even
/// when focus has left the SwiftUI key handlers (Full Keyboard Access, a
/// footer menu, VoiceOver) — MemoryClip is an LSUIElement agent with no main menu,
/// so there is no ⌘W/⌘Q to fall back on. `performClose` keeps the window
/// delegate in the loop, which is what actually hides the window.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// Owns the floating clip panel: show/hide, previous-app tracking, hosting.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let uiState = PanelUIState()

    /// The app that was frontmost before the panel opened; paste targets go here.
    private(set) var previousApp: NSRunningApplication?

    /// Provides the menu-bar button's frame (screen coords). Wired by
    /// StatusController.
    ///
    /// No longer used for positioning: the panel is bottom-anchored and
    /// screen-centred rather than hung under the status item. Kept because
    /// StatusController owns the wiring and is not this change's to edit.
    var statusItemButtonFrame: (@MainActor () -> NSRect)?

    private let store: ClipStore
    private let pasteService: PasteService
    private let watcher: PasteboardWatcher
    private let qrController: QRWindowController
    private let queueService: QueueService
    private let noteCoordinator: NoteCoordinator

    private var panel: KeyablePanel?
    private var cancellables: Set<AnyCancellable> = []

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    init(
        store: ClipStore,
        pasteService: PasteService,
        watcher: PasteboardWatcher,
        noteCoordinator: NoteCoordinator
    ) {
        self.store = store
        self.pasteService = pasteService
        self.watcher = watcher
        self.qrController = QRWindowController(watcher: watcher)
        self.queueService = QueueService(store: store, pasteService: pasteService)
        self.noteCoordinator = noteCoordinator
        super.init()

        qrController.panelFrame = { [weak self] in
            self?.panel?.frame ?? .zero
        }

        // The panel must never come back on its own: `show()` is the only
        // path through the Touch ID gate, so AppKit's hidesOnDeactivate
        // (which orders the window back IN on reactivation, bypassing
        // `show()`) is replaced by an explicit hide on resign-active.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        // The preview pane does not fit inside the compact panel — the panel
        // is a 200-point-tall deck of cards, not a 560-point window any more —
        // so opening it grows the window instead.
        uiState.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                self?.applyPanelHeight(expanded: expanded, animated: true)
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Ordering the panel out here means the next appearance has to go
    /// through `show()` — and therefore through `AppLockService.gate` —
    /// and the focus-token bump clears search, selection and preview while
    /// the panel is hidden, so an unlocked history is never re-exposed.
    @objc private func appDidResignActive() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        previousApp = nil
        uiState.focusToken = UUID()
    }

    // MARK: Panel construction

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Design.Size.panelWidth,
                height: Design.Size.panelHeight
            ),
            // `.titled` and `.closable` are kept deliberately even though no
            // title bar is ever drawn: `KeyablePanel.cancelOperation` calls
            // `performClose`, and AppKit refuses to close a window that has no
            // close button. A `.borderless` panel would silently break Esc.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "MemoryClip"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The panel is a translucent slab hovering over the desktop. Without
        // BOTH of these the `.ultraThinMaterial` in the SwiftUI root just
        // tints an opaque window backdrop and the whole effect is lost —
        // and the rounded corners show as dark rectangles at the edges.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Shadow is derived from the layer's alpha, so it follows the
        // 28-point rounded rectangle rather than the window bounds.
        panel.hasShadow = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // Not hidesOnDeactivate: AppKit would order the panel back in on
        // reactivation without re-running the lock gate. See
        // `appDidResignActive`.
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let hostingView = NSHostingView(
            rootView: PanelView(uiState: uiState, queue: queueService, actions: makeActions())
                .modelContainer(store.container)
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.panel = panel
    }

    // MARK: Geometry

    /// Place the panel: full requested width (clamped to the screen), pinned
    /// to the bottom of the visible frame, centred horizontally.
    ///
    /// Height is the only thing that varies — the preview pane makes the panel
    /// taller — and the panel grows *upward* so the slab never appears to
    /// slide off the bottom of the screen.
    private func applyPanelHeight(expanded: Bool, animated: Bool) {
        guard let panel else { return }
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let margin = Design.Size.panelSideMargin
        let width = min(Design.Size.panelWidth, max(320, visibleFrame.width - margin * 2))
        let requested = expanded ? Design.Size.panelExpandedHeight : Design.Size.panelHeight
        let height = min(requested, visibleFrame.height - Design.Size.panelBottomMargin * 2)

        let frame = NSRect(
            x: (visibleFrame.midX - width / 2).rounded(),
            y: (visibleFrame.minY + Design.Size.panelBottomMargin).rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true, animate: animated && panel.isVisible)
    }

    /// Every closure captures `self` weakly: they are retained by the SwiftUI
    /// panel, which the controller owns, so a strong capture is a cycle.
    private func makeActions() -> PanelActions {
        PanelActions(
            paste: { [weak self] item, plain in
                guard let self else { return }
                let target = self.previousApp
                self.hide(restorePrevious: false)
                self.pasteService.paste(item, plainOnly: plain, target: target)
            },
            copyOnly: { [weak self] item in
                guard let self else { return }
                if self.pasteService.write(item, plainOnly: false) {
                    self.watcher.noteOwnWrite()
                    self.store.markUsed(item)
                }
            },
            copyExtractedText: { [weak self] item in
                guard let self else { return }
                let text = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard self.pasteService.writeText(text) else { return }
                self.watcher.noteOwnWrite()
                self.store.markUsed(item)
            },
            close: { [weak self] in
                self?.hide(restorePrevious: true)
            },
            applyTransform: { [weak self] item, transform in
                guard let self else { return }
                guard let text = item.text,
                      let result = TransformService.apply(transform, to: text),
                      result != text
                else { return }
                let clip = CapturedClip(
                    kind: .text,
                    text: result,
                    richTextData: nil,
                    imageData: nil,
                    fileURLStrings: [],
                    colorHex: nil,
                    hash: ContentParser.hashText("text:\(result)")
                )
                self.store.insert(clip, sourceBundleID: Bundle.main.bundleIdentifier, sourceAppName: "MemoryClip")
            },
            showQR: { [weak self] item in
                self?.qrController.show(for: item)
            },
            toggleQueue: { [weak self] item in
                self?.queueService.toggle(item)
            },
            pasteQueue: { [weak self] in
                guard let self else { return }
                let target = self.previousApp
                self.hide(restorePrevious: false)
                self.queueService.pasteAll(target: target)
            },
            saveNote: { [weak self] item in
                self?.saveNote(for: item)
            },
            openNote: { [weak self] item in
                self?.openNote(for: item)
            },
            revealInFinder: { item in
                guard let url = item.screenshotURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        )
    }

    // MARK: Notes

    /// Write (or rewrite) the note for a clip, reporting the outcome.
    ///
    /// The export is awaited off this call — it may run a model pass and
    /// then a subprocess — so the panel stays live while it happens. Only
    /// failure interrupts the user: a note that was written is reported by
    /// the row itself, which starts saying "noted".
    private func saveNote(for item: ClipItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.noteCoordinator.exportNote(for: item)
            if case .failure(let error) = result {
                self.presentNoteFailure(error)
            }
        }
    }

    /// Open the note already written for a clip.
    ///
    /// `notePath` is a path for file destinations and a human-readable
    /// locator for the others ("Notes › MemoryClip"), so this only opens what
    /// actually exists on disk — there is nothing to open for a note that
    /// lives inside another app.
    private func openNote(for item: ClipItem) {
        guard let path = item.notePath, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentNoteFailure(.folderUnavailable(path))
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Report a note failure where the user is actually looking.
    ///
    /// An alert rather than a log line: every one of these is something only
    /// the user can fix (pick a folder, grant Automation, name a Shortcut),
    /// and the action they just took produced no visible result otherwise.
    private func presentNoteFailure(_ error: NoteError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MemoryClip could not save the note."
        alert.informativeText = error.errorDescription ?? "Unknown error."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Settings…")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            openSettingsWindow()
        }
    }

    // MARK: Show / hide

    func toggle() {
        // Only OPENING is gated by the Touch ID lock (see show()); hiding is
        // always allowed so the hotkey can dismiss the panel without auth.
        isVisible ? hide(restorePrevious: true) : show()
    }

    func show() {
        Task { @MainActor in
            // Touch ID / passcode gate; fails open when disabled/unavailable.
            guard await AppLockService.shared.gate(reason: "Unlock MemoryClip clipboard history") else { return }

            self.ensurePanel()
            guard let panel = self.panel else { return }

            // Remember the app that owned focus before we opened, so paste can
            // restore it. Never record ourselves as the target.
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousApp = frontmost
            }

            // The panel is no longer a dropdown hanging off the menu bar: it
            // is a wide deck anchored to the BOTTOM of the screen, centred
            // horizontally, the way Deck presents itself. The status item's
            // frame is therefore no longer used as an anchor.
            self.applyPanelHeight(expanded: self.uiState.isExpanded, animated: false)

            self.uiState.isPaused = self.watcher.isPaused
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            self.uiState.focusToken = UUID()
        }
    }

    /// Abandon an in-flight queue run. Called at app teardown so a partially
    /// finished run cannot keep writing the pasteboard and synthesising ⌘V
    /// while MemoryClip is quitting.
    ///
    /// Deliberately NOT called from `hide(restorePrevious:)`: the `pasteQueue`
    /// action hides the panel *before* it starts the run, so cancelling on
    /// hide would tear down the very run the user just asked for.
    func cancelQueue() {
        queueService.cancel()
    }

    func hide(restorePrevious: Bool) {
        panel?.orderOut(nil)
        if restorePrevious {
            if let previousApp {
                previousApp.activate()
            } else {
                NSApp.hide(nil)
            }
        }
        previousApp = nil
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide(restorePrevious: true)
        return false
    }
}
