import AppKit
import SwiftData
import UniformTypeIdentifiers

/// Writes the entire clipboard history to a JSON or CSV file, with the
/// ceremony that bulk disclosure demands: a fresh authentication, a warning
/// that spells out what the file holds, and a save panel.
///
/// This lived in `StatusController` while the two "Export History as…" items
/// were in the menu-bar dropdown. The dropdown is for the clip copied a moment
/// ago; the export is a rare, whole-history action, so it moved to Settings →
/// History — and the flow had to leave `StatusController` with it, because a
/// settings pane is a plain SwiftUI struct with no reference to the store.
///
/// A singleton with the store handed to it at launch is how the rest of the
/// settings window already reaches app state: the Privacy pane talks to
/// `AppLockService.shared`, the About pane's button calls
/// `OnboardingController.shared.show()`. It also keeps the modal AppKit
/// sequence (NSAlert → NSSavePanel → NSAlert on failure) out of a view body,
/// where a `runModal()` has no business being.
@MainActor
final class HistoryExportController {
    static let shared = HistoryExportController()

    /// The history to export, wired by `AppDelegate` once the store exists.
    ///
    /// Weak because `AppDelegate` owns the store for the life of the process —
    /// this is a reference to it, not a second owner that would keep a
    /// SwiftData container alive past termination.
    weak var store: ClipStore?

    private init() {}

    // MARK: Export

    /// Authenticate, warn about what the file contains, then fetch the full
    /// history and write it via NSSavePanel.
    func exportHistory(asCSV: Bool) {
        NSApp.activate()
        // Bulk disclosure of the entire history — always behind the lock.
        authenticating(reason: "Unlock MemoryClip to export clipboard history") { [weak self] in
            self?.performExport(asCSV: asCSV)
        }
    }

    /// Run `body` behind the app lock, ALWAYS authenticating first.
    ///
    /// Deliberately not `StatusController`'s `gated(reason:)`, which reuses a
    /// recent unlock: exporting hands over every clip MemoryClip has ever
    /// seen, so it is worth a Touch ID prompt every single time.
    /// `AppLockService.gate` passes straight through when the lock is disabled
    /// or unavailable.
    private func authenticating(reason: String, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            guard await AppLockService.shared.gate(reason: reason) else { return }
            body()
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
        // Nothing to export before `AppDelegate` has handed the store over;
        // better to do nothing than to write an empty file that reads as a
        // history with no clips in it.
        guard let store else {
            log.error("Export skipped: no store")
            return
        }
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
}
