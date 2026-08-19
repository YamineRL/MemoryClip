import Foundation

/// What a sink hands back after writing a note.
///
/// `location` is stored on the clip as `ClipItem.notePath`, which is what makes
/// a second export update rather than duplicate — so for file destinations it
/// must be a real path, and for the others a locator a human can act on
/// ("Notes › MemoryClip"). Anything is better than an empty string here: an
/// empty `notePath` is indistinguishable from "no note exists".
struct NoteReceipt: Sendable, Equatable {
    /// Path, or a human-readable locator for non-file sinks.
    var location: String
    /// Something the UI can open to show the note, when there is one. nil is
    /// normal, not a failure — see `NotesAppSink` for a destination that
    /// genuinely has no openable address.
    var openURL: URL?

    init(location: String, openURL: URL? = nil) {
        self.location = location
        self.openURL = openURL
    }
}

/// One place a note can be written.
///
/// Deliberately narrow: a sink takes a finished `NoteDraft` and returns where
/// it put it. It never sees `ClipItem`, a `ModelContext` or the pasteboard, so
/// the AppleScript and `Process` paths below cannot accidentally touch
/// SwiftData from the wrong actor — the caller has already flattened the model
/// into a `Sendable` value before any of this runs.
///
/// `async` because two of the three conformers genuinely are: `NotesAppSink`
/// has to hop to the main actor for Apple events, and `ShortcutSink` awaits a
/// subprocess. `MarkdownVaultSink` is synchronous inside, and stays
/// `nonisolated` so its file I/O runs on the cooperative pool instead of
/// blocking whichever actor asked for a note.
///
/// Every failure is a `NoteError`, so the UI has one thing to catch and one
/// sentence to show.
protocol NoteSink: Sendable {
    /// Write `draft` as a new note.
    func write(_ draft: NoteDraft) async throws -> NoteReceipt

    /// Write `draft`, replacing the note previously written at
    /// `existingLocation` (a `ClipItem.notePath`) when the destination can
    /// address it.
    ///
    /// This is the re-export path. It is a separate method rather than a field
    /// on `NoteDraft` because "where the last note went" is a property of the
    /// clip's history, not of the note's content — and because a draft that
    /// carried its own destination path could not be composed before a sink
    /// was chosen.
    func write(_ draft: NoteDraft, replacing existingLocation: String?) async throws -> NoteReceipt
}

extension NoteSink {
    /// Destinations that cannot address a note they wrote earlier ignore
    /// `existingLocation` and create a new one.
    ///
    /// Only `MarkdownVaultSink` overrides this: a file has a path that can be
    /// overwritten. Apple Notes hands back a Core Data id that AppleScript can
    /// look up but that is not stable across a restore, and a Shortcut may put
    /// the note anywhere at all — for both, "update the existing one" is a
    /// promise this layer cannot keep, so it does not make it.
    ///
    /// Note this is NOT recursive: `write(_:)` is a protocol requirement in its
    /// own right, so a conformer that implements only it terminates here.
    func write(_ draft: NoteDraft, replacing existingLocation: String?) async throws -> NoteReceipt {
        _ = existingLocation
        return try await write(draft)
    }
}

/// Builds the sink for a destination out of the stored settings.
///
/// Separate from the sinks themselves so each of them takes plain values in its
/// initialiser (a vault URL, a folder name, a shortcut name) and can be tested
/// without `UserDefaults`. Everything that reads configuration — and therefore
/// everything that can discover the user has not finished configuring it — is
/// here, which is also why this is the only place `noDestinationConfigured` and
/// `folderUnavailable` are thrown.
enum NoteSinkFactory {
    /// The sink for `destination`, or the error explaining what the user still
    /// has to set up.
    ///
    /// - Parameters:
    ///   - destination: defaults to the user's current choice.
    ///   - defaults: injectable so tests can supply a suite.
    static func make(
        for destination: NoteDestination = .current,
        defaults: UserDefaults = .standard
    ) throws -> any NoteSink {
        switch destination {
        case .markdownVault:
            guard let vault = FolderBookmark.resolve(key: NoteSettingsKeys.vaultBookmark) else {
                // Either the user never picked a folder, or the bookmark no
                // longer resolves at all (the volume is gone). `resolve` cannot
                // tell those apart, and both are fixed the same way: pick a
                // folder again.
                throw NoteError.noDestinationConfigured(.markdownVault)
            }
            let path = vault.path(percentEncoded: false)
            // A bookmark can resolve to a folder that has since been deleted,
            // or to one macOS will no longer let this build open. Checking now
            // turns either into one clear sentence instead of a `copyItem`
            // failure three layers down — and they are told apart, because the
            // repairs are different and `fileExists` answers false for both.
            switch FolderAccess.read(vault) {
            case .readable: break
            case .refused: throw NoteError.folderNotPermitted(path)
            case .missing: throw NoteError.folderUnavailable(path)
            }

            let attachmentFolder = defaults.string(forKey: NoteSettingsKeys.vaultAttachmentFolder)
            return MarkdownVaultSink(
                vaultURL: vault,
                attachmentFolderName: attachmentFolder ?? MarkdownVaultSink.defaultAttachmentFolderName,
                useDateFolders: defaults.bool(forKey: NoteSettingsKeys.vaultDateFolders),
                copyAttachments: defaults.bool(forKey: NoteSettingsKeys.copyAttachments)
            )

        case .notesApp:
            let folder = (defaults.string(forKey: NoteSettingsKeys.notesAppFolder) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folder.isEmpty else { throw NoteError.noDestinationConfigured(.notesApp) }
            return NotesAppSink(folderName: folder)

        case .shortcut:
            let name = (defaults.string(forKey: NoteSettingsKeys.shortcutName) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Registered as "" on purpose — there is no sensible default
            // Shortcut, so this is the one destination that is unusable until
            // the user names one.
            guard !name.isEmpty else { throw NoteError.noDestinationConfigured(.shortcut) }
            return ShortcutSink(shortcutName: name)
        }
    }
}
