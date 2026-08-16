import AppKit
import QuickLookUI

/// One clip as Quick Look sees it: a file on disk and a name for it.
///
/// The URL is already resolved by the time this exists. `QLPreviewItem` is
/// not main-actor-isolated, so a lazily-resolving item would have to reach
/// SwiftData from whatever thread Quick Look happened to ask on;
/// `QuickLookController` resolves each clip inside the data-source callback
/// instead, which AppKit does guarantee to run on the main thread.
final class QuickLookClipItem: NSObject, QLPreviewItem {
    /// The clip this stands for, so the panel's selection can follow Quick
    /// Look's when it closes.
    let uuid: UUID
    private let url: URL?
    private let title: String

    init(uuid: UUID, title: String, url: URL?) {
        self.uuid = uuid
        self.title = title
        self.url = url
    }

    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}

/// Drives the real `QLPreviewPanel` for the clip panel.
///
/// The genuine article rather than a window of our own: Quick Look is a
/// system gesture with system behaviour attached (Space and Escape close it,
/// the arrows walk the list, the zoom, the share button, the "Open with"), and
/// none of that survives being reimplemented.
///
/// The price is that `QLPreviewPanel` is *controller-based*: it does not take
/// a data source from whoever opened it, it walks the key window's responder
/// chain asking each responder whether it will control the panel, and closes
/// again if nobody answers. `KeyablePanel` is the link in that chain we own
/// outright — everything below it belongs to SwiftUI — so it forwards the
/// three control methods here.
@MainActor
final class QuickLookController: NSObject {
    /// The window Quick Look was summoned from, made key again afterwards so
    /// the panel is exactly where it was: same clip, preview pane still open,
    /// and Escape still the way out of it.
    weak var host: NSWindow?

    /// What Quick Look is paging through, unresolved.
    ///
    /// The clip is held weakly: a clip can be deleted while the panel is up
    /// (the retention trim runs on a timer, and the panel is not key to stop
    /// it), and a strong reference here would keep a deleted row alive to be
    /// read afterwards.
    private struct Entry {
        let uuid: UUID
        let title: String
        weak var clip: ClipItem?
    }

    private var entries: [Entry] = []
    /// Items already resolved to a file, keyed by clip. Paging back onto a
    /// clip must not write its temp file a second time.
    private var resolved: [UUID: QuickLookClipItem] = [:]
    /// Where in `entries` the panel should open.
    private var startIndex = 0
    /// Handed the clip Quick Look was showing when it closed. Cleared as it
    /// fires, so a second relinquish cannot report the same visit twice.
    private var onClose: ((UUID) -> Void)?
    /// True while the app is putting Quick Look away itself — the panel being
    /// hidden, the app deactivating — rather than the user dismissing it.
    ///
    /// Without it, ending control would order the clip panel back in on top of
    /// a hide already under way, and an unlocked history would reappear.
    private var isDismissing = false

    // MARK: - Presenting

    /// Show `items` full size, positioned on `index`.
    ///
    /// The list is a snapshot: Quick Look pages through the panel's filtered
    /// clips as they were when it opened, which is what makes ← and → behave
    /// like arrowing through a Finder folder. Clips captured while it is up
    /// join the panel's list, not this one.
    func show(items: [ClipItem], startingAt index: Int, onClose: @escaping (UUID) -> Void) {
        guard !items.isEmpty, items.indices.contains(index) else { return }
        entries = items.map { Entry(uuid: $0.uuid, title: QuickLook.title(for: $0), clip: $0) }
        resolved = [:]
        startIndex = index
        isDismissing = false
        self.onClose = onClose

        guard let panel = QLPreviewPanel.shared() else { return }
        // Already up and already ours — the user clicked back to the clip
        // panel without closing it and pressed Space again. Quick Look only
        // asks the responder chain when the controlling object CHANGES, so
        // `begin(_:)` will not run a second time and the new list has to be
        // installed here instead.
        if panel.isVisible, panel.dataSource === self {
            panel.reloadData()
            panel.currentPreviewItemIndex = startIndex
        }
        // Ordering the panel in is what makes Quick Look walk the responder
        // chain, find `KeyablePanel`, and call `begin(_:)` below.
        panel.makeKeyAndOrderFront(nil)
        // Again after the ordering, not only inside `begin(_:)`: that runs
        // *during* the ordering, and a level set mid-flight is the one a
        // window server that reasserts its own would overwrite.
        raiseAboveClipPanel(panel)
    }

    /// Put Quick Look above the clip panel.
    ///
    /// The clip panel floats over every ordinary window, so a Quick Look panel
    /// at the normal level would open *behind* the very panel it was summoned
    /// from. One level up from floating puts it back on top without disturbing
    /// the clip panel, which has to stay visible: it is what the user returns
    /// to when Quick Look closes.
    private func raiseAboveClipPanel(_ panel: QLPreviewPanel) {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    }

    /// Close Quick Look if it is up — the panel being hidden, the app being
    /// deactivated, the lock gate re-arming.
    ///
    /// `sharedPreviewPanelExists()` first: `shared()` *creates* the panel, so
    /// asking it to close would otherwise build one only to tear it down.
    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible
        else { return }
        isDismissing = true
        panel.orderOut(nil)
    }

    // MARK: - Responder-chain control

    /// Take control of the panel. Called through `KeyablePanel`.
    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        raiseAboveClipPanel(panel)
        // `reloadData` resets the current index, so the position is set after
        // it and not before.
        panel.reloadData()
        panel.currentPreviewItemIndex = startIndex
    }

    /// Give up control. Called when Quick Look closes.
    ///
    /// `entries` deliberately survive this: control is also relinquished when
    /// the key window changes, and a panel that came back to an emptied data
    /// source would show nothing. They are replaced wholesale by the next
    /// `show(items:startingAt:onClose:)` instead. The completion is what is
    /// cleared, so one visit reports one landing.
    func end(_ panel: QLPreviewPanel) {
        let landed = entries.indices.contains(panel.currentPreviewItemIndex)
            ? entries[panel.currentPreviewItemIndex].uuid
            : nil
        let handler = onClose
        let dismissing = isDismissing
        onClose = nil
        isDismissing = false

        // The clip panel never went away — it was merely no longer key — so
        // this restores the panel *and* its first responder, leaving the
        // search field focused the way the user left it. Skipped when the app
        // is the one closing Quick Look, because the panel is on its way out
        // too and ordering it front again would undo that.
        if !dismissing { host?.makeKeyAndOrderFront(nil) }
        if let landed { handler?(landed) }
    }

    // MARK: - Resolving

    /// The item for a row, resolved once and remembered.
    private func item(at index: Int) -> QuickLookClipItem? {
        guard entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        if let cached = resolved[entry.uuid] { return cached }
        let item = QuickLookClipItem(
            uuid: entry.uuid,
            title: entry.title,
            url: Self.previewURL(for: entry.clip)
        )
        resolved[entry.uuid] = item
        return item
    }

    /// The file Quick Look should read for a clip.
    ///
    /// Clips that already reference a file hand theirs straight over. A
    /// pasteboard image has only bytes, so this is where they are spilled to
    /// the caches directory — for the clip being looked at, at the moment it
    /// is looked at, rather than for a whole page of clips up front.
    private static func previewURL(for clip: ClipItem?) -> URL? {
        // A deleted row is not merely empty: reading its attributes after the
        // context has dropped it is undefined, so it is checked first.
        guard let clip, !clip.isDeleted else { return nil }
        switch QuickLook.source(for: clip) {
        case .file(let url):
            return url
        case .pasteboardImage:
            guard case .data(let data)? = clip.imagePayload else { return nil }
            do {
                return try QuickLookCache.fileURL(forClip: clip.uuid, imageData: data)
            } catch {
                log.error("Quick Look could not write a preview file: \(error.localizedDescription, privacy: .private)")
                return nil
            }
        case nil:
            return nil
        }
    }
}

// MARK: - QLPreviewPanelDataSource

// `@preconcurrency` on both conformances below: QuickLookUI predates strict
// concurrency and declares none of its protocols main-actor-isolated, while
// every one of these callbacks is in fact an AppKit main-thread callback. The
// attribute keeps the methods where they belong — on the main actor, next to
// the SwiftData rows they read — and turns the (impossible) off-thread call
// into a runtime trap rather than a silent data race.
extension QuickLookController: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        entries.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        item(at: index)
    }
}

// MARK: - QLPreviewPanelDelegate

extension QuickLookController: @preconcurrency QLPreviewPanelDelegate {
    /// Events Quick Look did not handle itself come back here.
    ///
    /// Space closing the panel is Quick Look's own behaviour and this is not
    /// meant to replace it — the panel gets first refusal and normally
    /// consumes the key. It is here for the case where it does not, so that
    /// Space, Escape, Escape always retraces the way in.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event?.type == .keyDown, event?.charactersIgnoringModifiers == " " else { return false }
        panel.orderOut(nil)
        return true
    }
}
