import AppKit

/// Small floating window showing a QR code for a link clip (Phase 2).
///
/// One window instance is reused across showings. It floats like the panel,
/// hides on app deactivation, and closes via Esc or the close button.
/// "Copy Link" writes the URL to the pasteboard and marks the write as our
/// own so the capture watcher doesn't re-capture it.
@MainActor
final class QRWindowController: NSObject, NSWindowDelegate {
    /// Frame of the clip panel (when visible) so the QR window can be placed
    /// next to it; falls back to screen center. Wired by PanelController.
    var panelFrame: (@MainActor () -> NSRect)?

    private let watcher: PasteboardWatcher
    private var panel: KeyablePanel?
    private var imageView: NSImageView?
    private var currentLink: String?

    init(watcher: PasteboardWatcher) {
        self.watcher = watcher
        super.init()

        // Like the clip panel: hide explicitly on deactivation instead of
        // relying on hidesOnDeactivate, which would bring the window back on
        // reactivation without the panel's Touch ID gate having run.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appDidResignActive() {
        guard let panel, panel.isVisible else { return }
        currentLink = nil
        panel.orderOut(nil)
    }

    /// Show (or update) the QR window for the clip's link text.
    func show(for item: ClipItem) {
        guard let link = item.text, !link.isEmpty,
              let image = QRService.image(for: link, size: 240) else { return }

        ensurePanel()
        guard let panel, let imageView else { return }

        currentLink = link
        imageView.image = image
        panel.title = URL(string: link)?.host() ?? link

        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Panel construction

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = loc("QR Code")
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: loc("Copy Link"), target: self, action: #selector(copyLink))
        copyButton.bezelStyle = .rounded
        // Return copies the link; Esc closes the window (KeyablePanel's
        // cancelOperation override).
        copyButton.keyEquivalent = "\r"
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(imageView)
        content.addSubview(copyButton)
        panel.contentView = content

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            imageView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 240),
            imageView.heightAnchor.constraint(equalToConstant: 240),
            copyButton.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
            copyButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        ])

        self.panel = panel
        self.imageView = imageView
    }

    /// Reposition next to the clip panel when it's visible, otherwise center
    /// on the screen.
    private func position(_ panel: NSPanel) {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = panel.frame.size
        let anchor = panelFrame?() ?? .zero

        guard anchor != .zero else {
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            ))
            return
        }

        // Prefer the right side of the panel; fall back to the left.
        var originX = anchor.maxX + 8
        if originX + size.width > visibleFrame.maxX - 8 {
            originX = anchor.minX - size.width - 8
        }
        originX = min(max(originX, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let originY = min(
            max(anchor.midY - size.height / 2, visibleFrame.minY + 8),
            visibleFrame.maxY - size.height - 8
        )
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    // MARK: Actions

    @objc private func copyLink() {
        guard let link = currentLink else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        watcher.noteOwnWrite()
    }

    // MARK: NSWindowDelegate

    /// Esc / close button: hide without releasing (window is reused).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        currentLink = nil
        sender.orderOut(nil)
        return false
    }
}
