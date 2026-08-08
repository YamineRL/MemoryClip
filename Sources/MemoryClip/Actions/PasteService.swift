import AppKit
import Carbon.HIToolbox

/// Writes clips back to the pasteboard and simulates ⌘V into the target app.
@MainActor
final class PasteService {
    /// What a paste attempt actually managed to do.
    enum PasteOutcome: Sendable, Equatable {
        /// Nothing was written — the clip carried no usable payload.
        case failed
        /// The clip is on the pasteboard; no ⌘V was sent (auto-paste off, or
        /// no target app). The user's own ⌘V still works.
        case copiedOnly
        /// The clip is on the pasteboard and ⌘V was posted to the target.
        case pasted
        /// The clip is on the pasteboard but the target app never became (or
        /// stopped being) frontmost, so no keystroke was sent — sending one
        /// would have typed the clip into whatever app has focus now.
        case targetLost

        /// True when the clip reached the pasteboard at all.
        var wroteClipboard: Bool { self != .failed }
    }

    /// A validated pasteboard payload. Built *before* the pasteboard is
    /// cleared, so a clip that cannot be written never destroys what the
    /// user already had on their clipboard.
    struct Payload: Equatable {
        enum Entry: Equatable {
            case string(NSPasteboard.PasteboardType, String)
            case data(NSPasteboard.PasteboardType, Data)
        }

        var entries: [Entry] = []
        var urls: [URL] = []

        /// Clear and write. Only called once the payload is known good.
        func apply(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            if !urls.isEmpty {
                pasteboard.writeObjects(urls as [NSURL])
            }
            for entry in entries {
                switch entry {
                case let .string(type, value):
                    pasteboard.setString(value, forType: type)
                case let .data(type, value):
                    pasteboard.setData(value, forType: type)
                }
            }
        }
    }

    /// Seconds to wait after activating the target before looking for it at
    /// the front — an app needs a beat to actually come forward.
    static let activationDelay: TimeInterval = 0.2
    /// How long to keep waiting for the target to become frontmost before
    /// giving up on the synthetic ⌘V.
    static let activationTimeout: TimeInterval = 0.6
    /// Poll interval while waiting for the target to come forward.
    static let activationPollInterval: TimeInterval = 0.05
    /// Time the target app is given to consume the ⌘V before a caller is
    /// allowed to overwrite the pasteboard (queue mode).
    static let settleDelay: TimeInterval = 0.25

    private let store: ClipStore
    private let watcher: PasteboardWatcher
    /// The pasteboard every paste targets. Injectable so tests can round-trip
    /// through a private `NSPasteboard(name:)` instead of the user's clipboard.
    private let pasteboard: NSPasteboard

    init(store: ClipStore, watcher: PasteboardWatcher, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.watcher = watcher
        self.pasteboard = pasteboard
    }

    // MARK: Writing

    /// Build the pasteboard representations for a clip, or nil when the clip
    /// carries nothing writable. Pure — touches no pasteboard.
    ///
    /// `plainOnly` strips rich formatting; for a rich-text clip with no plain
    /// text stored, the plain text is derived from the RTF rather than
    /// silently pasting an empty string.
    static func payload(for item: ClipItem, plainOnly: Bool) -> Payload? {
        switch item.kind {
        case .text:
            guard let text = item.text else { return nil }
            return Payload(entries: [.string(.string, text)])

        case .link:
            guard let text = item.text else { return nil }
            return Payload(entries: [
                .string(.string, text),
                .string(NSPasteboard.PasteboardType("public.url"), text),
            ])

        case .richText:
            if plainOnly {
                // Same precondition as the rich branch below: a clip with no
                // plain text AND no RTF to derive it from is not pasteable.
                guard let text = plainText(for: item) else { return nil }
                return Payload(entries: [.string(.string, text)])
            }
            if let richTextData = item.richTextData, !richTextData.isEmpty {
                var payload = Payload(entries: [.data(.rtf, richTextData)])
                if let text = item.text {
                    payload.entries.append(.string(.string, text))
                }
                return payload
            }
            guard let text = item.text else { return nil }
            return Payload(entries: [.string(.string, text)])

        case .image:
            guard let imageData = item.imageData, !imageData.isEmpty else { return nil }
            return Payload(entries: [.data(imageType(for: imageData), imageData)])

        case .file:
            let urls = item.fileURLStrings.compactMap { URL(string: $0) }
            guard !urls.isEmpty else { return nil }
            return Payload(urls: urls)

        case .color:
            guard let hex = item.colorHex else { return nil }
            return Payload(entries: [.string(.string, hex)])
        }
    }

    /// Plain text for a rich-text clip: the stored plain string when there is
    /// one, otherwise the text extracted from the RTF payload.
    static func plainText(for item: ClipItem) -> String? {
        if let text = item.text, !text.isEmpty { return text }
        if let data = item.richTextData,
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil),
           !attributed.string.isEmpty {
            return attributed.string
        }
        return item.text
    }

    /// Identify image bytes by magic number so the payload is declared with
    /// the UTI a receiving app can actually decode. Unknown bytes fall back
    /// to TIFF, which is what the pasteboard historically assumed.
    static func imageType(for data: Data) -> NSPasteboard.PasteboardType {
        func matches(_ prefix: [UInt8]) -> Bool {
            guard data.count >= prefix.count else { return false }
            return data.prefix(prefix.count).elementsEqual(prefix)
        }
        if matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if matches([0xFF, 0xD8, 0xFF]) { return NSPasteboard.PasteboardType("public.jpeg") }
        if matches(Array("GIF87a".utf8)) || matches(Array("GIF89a".utf8)) {
            return NSPasteboard.PasteboardType("com.compuserve.gif")
        }
        if matches([0x25, 0x50, 0x44, 0x46]) { return .pdf }               // %PDF
        if matches([0x49, 0x49, 0x2A, 0x00]) { return .tiff }              // little-endian TIFF
        if matches([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }              // big-endian TIFF
        return .tiff
    }

    /// Write the clip's payload onto the pasteboard. `plainOnly` strips
    /// rich formatting (text clips). Returns true when something was written.
    ///
    /// The pasteboard is cleared only once a writable payload exists, so a
    /// false return leaves the user's existing clipboard intact.
    @discardableResult
    func write(_ item: ClipItem, plainOnly: Bool, to target: NSPasteboard? = nil) -> Bool {
        guard let payload = Self.payload(for: item, plainOnly: plainOnly) else { return false }
        payload.apply(to: target ?? pasteboard)
        return true
    }

    /// Write a bare string onto the pasteboard — used for an image clip's
    /// extracted text, which has no `ClipItem` payload of its own.
    ///
    /// Empty input returns false without clearing, matching `write`: a clip
    /// with nothing to give must not destroy the user's clipboard.
    @discardableResult
    func writeText(_ text: String, to target: NSPasteboard? = nil) -> Bool {
        guard !text.isEmpty else { return false }
        Payload(entries: [.string(.string, text)]).apply(to: target ?? pasteboard)
        return true
    }

    // MARK: Pasting

    /// Write the clip, activate `target`, and post ⌘V to it.
    ///
    /// Fire-and-forget: the pasteboard write happens synchronously, the
    /// keystroke lands later. Callers that must sequence several pastes
    /// should use `pasteAndWait` instead.
    @discardableResult
    func paste(_ item: ClipItem, plainOnly: Bool, target: NSRunningApplication?) -> Bool {
        guard writeAndMarkUsed(item, plainOnly: plainOnly) else { return false }
        guard Self.isAutoPasteEnabled, let target else { return true }
        Task { @MainActor [weak self] in
            _ = await self?.activateAndPost(target: target)
        }
        return true
    }

    /// Write the clip and, when auto-paste is on, post ⌘V — returning only
    /// once the keystroke has been delivered and the target has had time to
    /// consume it. Queue mode sequences on this instead of a fixed delay.
    @discardableResult
    func pasteAndWait(
        _ item: ClipItem,
        plainOnly: Bool,
        target: NSRunningApplication?
    ) async -> PasteOutcome {
        guard writeAndMarkUsed(item, plainOnly: plainOnly) else { return .failed }
        guard Self.isAutoPasteEnabled, let target else { return .copiedOnly }
        guard await activateAndPost(target: target) else { return .targetLost }
        try? await Task.sleep(for: .seconds(Self.settleDelay))
        return .pasted
    }

    private static var isAutoPasteEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.autoPaste)
    }

    private func writeAndMarkUsed(_ item: ClipItem, plainOnly: Bool) -> Bool {
        guard write(item, plainOnly: plainOnly) else { return false }
        watcher.noteOwnWrite()
        store.markUsed(item)
        return true
    }

    /// Bring `target` forward and post ⌘V to it — but only while it really is
    /// the frontmost app. Returns false when it never came forward (or lost
    /// focus again), in which case NO keystroke is sent: the clip is already
    /// on the pasteboard, so the user's own ⌘V remains the fallback, and we
    /// never type a clip into whatever window happens to have focus.
    private func activateAndPost(target: NSRunningApplication) async -> Bool {
        let pid = target.processIdentifier
        target.activate()
        try? await Task.sleep(for: .seconds(Self.activationDelay))

        var waited: TimeInterval = 0
        while true {
            if Task.isCancelled { return false }
            // Checked immediately before posting, so the window between the
            // check and the keystroke is as small as it can be.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                Self.postCommandV(pid: pid)
                return true
            }
            guard waited < Self.activationTimeout else {
                log.notice("Auto-paste skipped: target app is not frontmost")
                return false
            }
            try? await Task.sleep(for: .seconds(Self.activationPollInterval))
            waited += Self.activationPollInterval
        }
    }

    /// Post a synthetic ⌘V key event to the process (CGEvent, the standard
    /// pasteboard-manager pattern).
    ///
    /// Note: macOS may drop synthetic key events into other apps unless the
    /// user grants Accessibility — the clip is already on the clipboard at
    /// this point, so manual ⌘V remains the fallback.
    ///
    /// Callers must confirm the pid is frontmost first (see
    /// `activateAndPost`); posting blind can deliver the clip into whatever
    /// field that app happens to have focused.
    nonisolated static func postCommandV(pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let virtualKey = CGKeyCode(kVK_ANSI_V)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }
}
