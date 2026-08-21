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
        authenticating(reason: loc("Unlock MemoryClip to export clipboard history")) { [weak self] in
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
        // Reached through the Touch ID gate, which is another process's sheet:
        // the cooperative `NSApp.activate()` that used to stand here can be
        // refused, leaving the confirmation alert behind the Settings window
        // that raised it — on an agent app with nothing in the Dock to click.
        WindowFocus.restoreAfterSystemPrompt()
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
            // The name is whatever the user typed into the save panel, so it
            // is their data and not ours to publish: the unified log outlives
            // the export and survives "Clear All History", and a default name
            // is only the default until someone types something about what
            // they were exporting. The count stays public — it is the number
            // anyone triaging a failed export actually needs, and it says
            // nothing about what was in the clips.
            log.notice("Exported \(count) clips to \(url.lastPathComponent, privacy: .private)")
        } catch ExportFailure.fetch(let error) {
            // A partially written file is worse than none: it looks like a
            // complete history but silently stops part way.
            try? FileManager.default.removeItem(at: url)
            log.error("Export failed to fetch history: \(error.localizedDescription)")
            presentError(
                message: loc("Could not read the clipboard history."),
                informative: error.localizedDescription
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            log.error("Export failed: \(error.localizedDescription)")
            presentError(
                message: loc("Export failed."),
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

    // MARK: Import

    /// Authenticate, spell out what an import does, then merge a JSON export
    /// into the history.
    func importHistory() {
        NSApp.activate()
        // Writes into the same thing the export reads out of — behind the
        // same lock, for the same reason.
        authenticating(reason: loc("Unlock MemoryClip to import clipboard history")) { [weak self] in
            self?.performImport()
        }
    }

    /// What reading an export back in did.
    struct ImportOutcome: Sendable, Equatable {
        /// Clips written into the history.
        var inserted: Int
        /// Records the history already held, left exactly as they were.
        var skipped: Int
    }

    private func performImport() {
        WindowFocus.restoreAfterSystemPrompt()
        guard let store else {
            log.error("Import skipped: no store")
            return
        }
        guard confirmImport() else { return }

        // No `FolderBookmark`: the panel is itself the grant, and it covers
        // the one read that happens before this function returns. Bookmarks
        // are for the folders MemoryClip goes back to later without asking —
        // the vault, the screenshot folder — which this file is not.
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.allowedContentTypes = [.json]
        openPanel.prompt = loc("Import")
        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }

        do {
            let outcome = try Self.readImport(from: url, store: store)
            // Counts only, and the file name stays private, exactly as the
            // export logs it: the name is the user's and the unified log
            // outlives the history it describes.
            log.notice("Imported \(outcome.inserted) clips, \(outcome.skipped) already stored, from \(url.lastPathComponent, privacy: .private)")
            presentImportOutcome(outcome)
        } catch {
            log.error("Import failed: \(error.localizedDescription)")
            presentError(
                message: loc("Import failed."),
                informative: error.localizedDescription
            )
        }
    }

    /// Read the JSON export at `url` into `store`. Returns what it did.
    ///
    /// Read whole, where the export streams. `JSONDecoder` has no incremental
    /// array API, so a history exported with its images costs its own size in
    /// memory for the length of the import — which is the price of the
    /// all-or-nothing contract: a file that fails to decode has changed
    /// nothing, and there is no half-restored history to explain.
    static func readImport(from url: URL, store: ClipStore) throws -> ImportOutcome {
        let text = try String(contentsOf: url, encoding: .utf8)
        let items = try ExportService.items(from: ExportService.imports(fromJSON: text))
        let inserted = store.insertImported(items)
        return ImportOutcome(inserted: inserted, skipped: items.count - inserted)
    }

    /// Say what an import will and will not touch before the panel opens.
    private func confirmImport() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = loc("Import clips from a JSON export?")
        alert.informativeText = loc(
            "The clips in the file are added to this Mac's history, keeping the dates and pins they were exported with.\n\nNothing is deleted or replaced: a clip already in your history is left exactly as it is, and importing the same file twice adds it once."
        )
        alert.addButton(withTitle: loc("Choose File…"))
        alert.addButton(withTitle: loc("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Report what the import added, and what it recognised and left alone.
    ///
    /// An alert rather than a log line, on the pattern the panel reports a
    /// failed note with: the user pressed something and the Settings window in
    /// front of them shows no history, so an import that says nothing is an
    /// import that looks like it did nothing.
    private func presentImportOutcome(_ outcome: ImportOutcome) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = loc("Imported %d clips.", outcome.inserted)
        alert.informativeText = loc(
            "%d clips in the file were already in your history and were left as they are.",
            outcome.skipped
        )
        alert.addButton(withTitle: loc("OK"))
        alert.runModal()
    }

    /// Spell out exactly what the exported file contains before writing it.
    private func confirmExport(asCSV: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc("Export your entire clipboard history?")
        let payload = asCSV
            ? loc("every clip's text, source app and timestamps")
            : loc("every clip's text, source app, timestamps and Base64 copies of image and rich-text clips")
        alert.informativeText = loc(
            "The file is UNENCRYPTED plain text containing %@ — including any passwords, tokens or other secrets you have copied.\n\nMemoryClip writes it readable by your user account only, but anyone who can open the file can read your whole history. Store it somewhere you trust, or delete it when done.",
            payload
        )
        alert.addButton(withTitle: loc("Export…"))
        alert.addButton(withTitle: loc("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentError(message: String, informative: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: loc("OK"))
        alert.runModal()
    }
}
