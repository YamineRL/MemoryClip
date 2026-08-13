import Foundation

/// Writes the note as a `.md` file into the folder the user picked.
///
/// The default destination, and the only one that needs no permission dialog,
/// no other app running and no network: the note is a file the user owns, in a
/// folder they chose, in a format that outlives MemoryClip.
///
/// Everything here runs inside `FolderBookmark.withAccess(to:)`. The vault is
/// normally somewhere macOS guards (`~/Documents`, iCloud Drive), and the grant
/// that came from the open panel is only live while the security scope is held
/// — outside it, the same `copyItem` fails with a permission error that reads
/// like a bug in this file.
///
/// `write` is `nonisolated` and its body is synchronous file I/O: a nonisolated
/// `async` function runs on the cooperative pool, so copying a 12 MB screenshot
/// into the vault never blocks the main actor even though the caller is the UI.
struct MarkdownVaultSink: NoteSink {
    /// The default attachment subfolder, matching `registerDefaults`.
    static let defaultAttachmentFolderName = "attachments"

    /// How much of a candidate note is read to check whether it is ours.
    /// Front matter sits at the top; reading the whole file would mean pulling
    /// in every megabyte of a long note to answer a yes/no question.
    static let frontMatterProbeBytes = 4096

    let vaultURL: URL
    let attachmentFolderName: String
    let copyAttachments: Bool

    init(
        vaultURL: URL,
        attachmentFolderName: String = defaultAttachmentFolderName,
        copyAttachments: Bool = true
    ) {
        self.vaultURL = vaultURL
        self.attachmentFolderName = attachmentFolderName
        self.copyAttachments = copyAttachments
    }

    // MARK: - NoteSink

    func write(_ draft: NoteDraft) async throws -> NoteReceipt {
        try await write(draft, replacing: nil)
    }

    /// Write the note, reusing an existing file when this clip already has one.
    ///
    /// **Idempotency contract**, in the order it is applied:
    ///
    /// 1. `existingLocation` (the clip's `notePath`) wins, when it still points
    ///    at a file inside this vault. The caller knows more than we can
    ///    discover, and honouring it means a note the user renamed or moved
    ///    within their vault keeps being updated rather than being re-created
    ///    under its original name.
    /// 2. Otherwise the deterministic name is tried: `fileNameStem` is a pure
    ///    function of the draft, so a re-export lands on the same
    ///    `<stem>.md`. If that file exists AND its front matter carries this
    ///    clip's `memoryclip-uuid`, it is ours and gets overwritten.
    /// 3. Otherwise a free name is allocated with ` 2`, ` 3`, … — the file at
    ///    `<stem>.md` is somebody else's note that happens to collide, and
    ///    silently overwriting a user's file is not a trade this makes.
    ///
    /// What it deliberately does NOT do is scan the vault for a note carrying
    /// the uuid. A real Obsidian vault is tens of thousands of files; finding
    /// the note would mean reading the head of every one of them on every
    /// export, and the answer is already available for free in steps 1 and 2.
    /// The cost of getting it wrong is one duplicate note, not data loss.
    func write(_ draft: NoteDraft, replacing existingLocation: String?) async throws -> NoteReceipt {
        guard draft.hasContent else { throw NoteError.nothingToWrite }

        return try FolderBookmark.withAccess(to: vaultURL) {
            try writeWithinScope(draft, replacing: existingLocation)
        }
    }

    // MARK: - Writing

    private func writeWithinScope(_ draft: NoteDraft, replacing existingLocation: String?) throws -> NoteReceipt {
        let fileManager = FileManager.default
        let vaultPath = vaultURL.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: vaultPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            // The folder was reachable when the sink was built and is not any
            // more (unmounted volume, iCloud evicted the folder). Same recovery
            // as never having picked one.
            throw NoteError.folderUnavailable(vaultPath)
        }

        // Copy the image FIRST: composition reads `attachmentFileName`, and an
        // Obsidian embed only resolves for a file inside the vault.
        var draft = draft
        if copyAttachments {
            draft.attachmentFileName = copiedAttachmentName(for: draft)
        }

        let destination = destinationURL(for: draft, replacing: existingLocation)
        let markdown = NoteComposer.markdown(for: draft)

        do {
            // Atomic: the write goes to a temp file in the same directory and
            // is renamed over the target. Without it, an overwrite that fails
            // partway (disk full, iCloud yanking the folder) leaves the user
            // with a truncated version of a note they already had.
            try Data(markdown.utf8).write(to: destination, options: .atomic)
        } catch {
            throw NoteError.writeFailed(error.localizedDescription)
        }

        // Path and title are user data — the unified log outlives the note and
        // survives the user deleting their history, so a public path would be a
        // durable record of what they capture and where they keep it.
        log.notice("Wrote note to \(destination.path(percentEncoded: false), privacy: .private)")
        return NoteReceipt(location: destination.path(percentEncoded: false), openURL: destination)
    }

    /// Where this note should be written — see the contract on `write`.
    private func destinationURL(for draft: NoteDraft, replacing existingLocation: String?) -> URL {
        let fileManager = FileManager.default

        if let existingLocation, !existingLocation.isEmpty {
            let existing = URL(filePath: existingLocation)
            if isInsideVault(existing), fileManager.fileExists(atPath: existing.path(percentEncoded: false)) {
                return existing
            }
            // Falling through is the interesting case: the recorded path is in
            // a vault the user has since switched away from, or the file is
            // gone. Either way the right answer is a new file HERE, not a write
            // into the old folder — which we may not even have access to.
        }

        let stem = NoteComposer.fileNameStem(for: draft)
        let preferred = vaultURL.appending(path: "\(stem).md")
        if fileManager.fileExists(atPath: preferred.path(percentEncoded: false)),
           fileCarriesUUID(preferred, uuid: draft.clipUUID) {
            return preferred
        }

        return NoteComposer.uniqueURL(directory: vaultURL, stem: stem, extension: "md") { url in
            fileManager.fileExists(atPath: url.path(percentEncoded: false))
        }
    }

    /// Whether `url` sits under the vault.
    ///
    /// Symlinks are resolved on both sides so `/var/…` and `/private/var/…`
    /// compare equal — the same path can come back either way depending on
    /// which API produced it. This is a "did the user change vaults" check, not
    /// a security boundary: nothing here is defending against a hostile path,
    /// only against writing into a folder we no longer hold a grant for.
    private func isInsideVault(_ url: URL) -> Bool {
        let root = vaultURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let candidate = url.resolvingSymlinksInPath().path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(prefix)
    }

    /// Whether the file at `url` is a note MemoryClip wrote for `uuid`.
    ///
    /// Reads only the head of the file — front matter is the first thing in the
    /// document, and this question comes up on every export.
    private func fileCarriesUUID(_ url: URL, uuid: UUID) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.frontMatterProbeBytes),
              let head = String(data: data, encoding: .utf8)
        else { return false }
        return head.contains(uuid.uuidString)
    }

    // MARK: - Attachments

    /// Copy the screenshot into the vault, returning the file name to embed.
    ///
    /// Copying is the default (`NoteSettingsKeys.copyAttachments`) for two
    /// reasons a link cannot cover:
    ///
    /// - An Obsidian `![[…]]` embed resolves by searching the vault. A file on
    ///   the Desktop is not in the vault, so the note would show a link where
    ///   the user expects the picture.
    /// - Screenshots are transient by nature — the whole point of the Desktop
    ///   folder is that it gets emptied. A note whose image lives there is a
    ///   note that breaks the first time the user tidies up, and they will not
    ///   find out until months later when they open it.
    ///
    /// Returns nil — degrading to the `file://` link in `NoteComposer` — rather
    /// than throwing on failure. Losing the embed is a worse note; losing the
    /// note because its picture could not be copied is a lost capture.
    private func copiedAttachmentName(for draft: NoteDraft) -> String? {
        guard let source = draft.sourceFileURL, source.isFileURL else { return nil }
        let fileManager = FileManager.default
        let sourcePath = source.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: sourcePath) else {
            log.notice("Note attachment missing at \(sourcePath, privacy: .private)")
            return nil
        }

        let folder = attachmentFolderURL()
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            log.error("Could not create attachment folder: \(error.localizedDescription)")
            return nil
        }

        // Extension carried over from the source so Obsidian (and Quick Look,
        // and everything else) still knows what the bytes are. A screenshot
        // with no extension is possible if the user renamed it.
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let stem = NoteComposer.fileNameStem(for: draft)

        // Re-exporting the same clip must not pile up `… 2.png`, `… 3.png`
        // beside the one copy that is already there. Same name and same byte
        // count is a good enough identity test for an immutable screenshot, and
        // it costs one `stat` — hashing 12 MB on every export would not.
        let preferred = folder.appending(path: "\(stem).\(ext)")
        if let existing = fileSize(of: preferred), existing == fileSize(of: source) {
            return preferred.lastPathComponent
        }

        let target = NoteComposer.uniqueURL(directory: folder, stem: stem, extension: ext) { url in
            fileManager.fileExists(atPath: url.path(percentEncoded: false))
        }
        do {
            try fileManager.copyItem(at: source, to: target)
        } catch {
            log.error("Could not copy note attachment: \(error.localizedDescription)")
            return nil
        }
        // Only the last component: an Obsidian embed is resolved by name across
        // the whole vault, so this keeps working if the user reorganises their
        // attachments folder later.
        return target.lastPathComponent
    }

    /// The attachment folder inside the vault.
    ///
    /// The setting is a user-typed string, so it is decomposed and rebuilt
    /// rather than appended blind: `../../` or a leading `/` would otherwise
    /// place MemoryClip's copies outside the vault entirely — somewhere the
    /// embed cannot resolve and the user is not expecting files to appear.
    /// Nested folders (`assets/screenshots`) are allowed, since Obsidian users
    /// really do organise that way.
    private func attachmentFolderURL() -> URL {
        let components = attachmentFolderName
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map(NoteComposer.sanitizedFileNameComponent)

        guard !components.isEmpty else {
            return vaultURL.appending(path: Self.defaultAttachmentFolderName)
        }
        return components.reduce(vaultURL) { $0.appending(path: $1) }
    }

    private func fileSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
