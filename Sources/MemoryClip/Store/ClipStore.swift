import Foundation
import SQLite3
import SwiftData

/// SwiftData-backed store for clipboard history.
@MainActor
final class ClipStore {
    let container: ModelContainer

    var context: ModelContext { container.mainContext }

    private var maintenanceTimer: Timer?

    /// Guards the thumbnail backfill so overlapping runs cannot both decode
    /// the same clips (the drain awaits, so a second caller can arrive).
    private var isBackfillingThumbnails = false

    /// The vault captures seal through: the sealer, the dedup HMAC key and
    /// the "Not a Secret" allow-list. nil only for an in-memory store whose
    /// test did not bring one — every real store has its own.
    let secrets: SecretVault?

    /// `secrets` defaults to the vault beside the store; nil is only ever
    /// handed in by an in-memory store whose test wants no vault at all.
    init(inMemory: Bool = false, secrets: SecretVault? = nil) throws {
        let schema = Schema([ClipItem.self, Pinboard.self])
        self.secrets = secrets ?? (inMemory ? nil : SecretVault(directory: Self.storeDirectory))
        if inMemory {
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
        } else {
            let url = try Self.prepareStoreLocation()
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(url: url)]
            )
            Self.restrictPermissions(forStoreAt: url)
            // The container opened the migrated store: only now may the
            // legacy source be retired. A crash or failed open leaves it in
            // place for the next launch to stage again.
            Self.finalizeLegacyMigration()
        }
    }

    // MARK: - On-disk location, permissions and legacy migration

    /// `~/Library/Application Support`.
    ///
    /// `nonisolated` (like the accessors below it) because it is pure path
    /// arithmetic: the disk-usage readout walks it from a detached task,
    /// which a main-actor path helper would make impossible.
    nonisolated static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
    }

    /// Directory holding MemoryClip's store, namespaced by bundle identifier.
    nonisolated static var storeDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("app.memoryclip", isDirectory: true)
    }

    /// The store MemoryClip uses from now on.
    nonisolated static var storeURL: URL {
        storeDirectory.appendingPathComponent("MemoryClip.store")
    }

    /// Where `ModelConfiguration(isStoredInMemoryOnly: false)` used to land:
    /// SwiftData's GENERIC default name, directly in Application Support,
    /// mode 644 and therefore world-readable — and shared with any other
    /// unsandboxed SwiftData app that also took the default.
    static var legacyStoreURL: URL {
        applicationSupportDirectory.appendingPathComponent("default.store")
    }

    /// SQLite sidecar suffixes that must travel with the store file.
    static let storeSidecarSuffixes = ["", "-wal", "-shm"]

    /// Create the store directory (0700), migrate any legacy store into it,
    /// and return the URL the container should open.
    static func prepareStoreLocation() throws -> URL {
        try createStoreDirectory(at: storeDirectory)
        try migrateLegacyStore(from: legacyStoreURL, to: storeURL)
        return storeURL
    }

    /// Create `directory` owner-only (0700), tightening it if it already
    /// exists with looser permissions.
    ///
    /// A chmod that fails is thrown rather than swallowed: the store holds
    /// every clip the user ever copied, and "0700 assumed" is a privacy
    /// claim the caller must not make on a guess.
    static func createStoreDirectory(at directory: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            } catch {
                log.error("Could not tighten permissions on \(directory.lastPathComponent): \(error.localizedDescription)")
                throw error
            }
        }
    }

    /// Staging directory a legacy migration copies into before anything is
    /// renamed into place. Its PRESENCE is the completion marker: files land
    /// at the destination only by rename out of staging, so a destination
    /// with a sibling staging directory still standing is by construction
    /// incomplete — the next launch moves it aside and stages again.
    nonisolated static func migrationStagingDirectory(forStoreAt destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).migrating", isDirectory: true)
    }

    /// Whether `url` is a Core Data store holding a ClipItem table — the
    /// ownership check the legacy migration runs before adopting a generic
    /// `default.store`. `default.store` is the name EVERY unsandboxed
    /// SwiftData app takes when it does not pick one, so presence alone is
    /// not evidence the file is MemoryClip's.
    static func looksLikeClipStore(_ url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ZCLIPITEM'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Move a pre-existing store (and its -wal/-shm sidecars and external
    /// storage) to the new namespaced path. No-op unless the legacy store
    /// exists AND the new one does not.
    ///
    /// Restart-safe: every file is copied into a staging directory first,
    /// then RENAMED into place only once the whole set is staged. A crash
    /// mid-copy leaves the staging directory standing and the legacy source
    /// untouched — the next launch discards the partial destination and
    /// stages again, instead of treating a half-copied store as migrated.
    /// The legacy source is deleted by `finalizeLegacyMigration`, after the
    /// destination has actually opened.
    ///
    /// A `default.store` that does not look like MemoryClip's (no
    /// `ZCLIPITEM` table) is neither adopted nor deleted — it belongs to
    /// some other app that took the same default.
    ///
    /// Failures are surfaced: silently starting with an empty history would
    /// look, to the user, exactly like losing it.
    @discardableResult
    static func migrateLegacyStore(from legacy: URL, to destination: URL) throws -> Bool {
        let fileManager = FileManager.default
        let staging = migrationStagingDirectory(forStoreAt: destination)

        // A previous interrupted run: the destination files are partial and
        // the staging directory holds whatever it managed to copy. Both go
        // aside; the legacy source is still there to copy afresh.
        if fileManager.fileExists(atPath: staging.path) {
            if fileManager.fileExists(atPath: destination.path) {
                try moveStoreAside(forStoreAt: destination)
            }
            try? fileManager.removeItem(at: staging)
        }

        guard fileManager.fileExists(atPath: legacy.path) else { return false }
        guard !fileManager.fileExists(atPath: destination.path) else { return false }

        // Copy into staging, then rename out: nothing appears at the
        // destination until the whole store is staged, and the staged set
        // is either fully renamed or provably incomplete.
        var staged: [URL] = []
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for suffix in storeSidecarSuffixes {
                let source = legacy.appendingSuffixToLastPathComponent(suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let target = staging.appendingPathComponent(source.lastPathComponent)
                try fileManager.copyItem(at: source, to: target)
                staged.append(target)
            }
            // Image clips over the inlining threshold live in a `.NAME_SUPPORT`
            // directory beside the store, keyed by the store's file name. It
            // has to travel with the store or every large image goes missing.
            let legacySupport = externalStorageDirectory(forStoreAt: legacy)
            if fileManager.fileExists(atPath: legacySupport.path) {
                let target = staging
                    .appendingPathComponent(legacySupport.lastPathComponent, isDirectory: true)
                try fileManager.copyItem(at: legacySupport, to: target)
                staged.append(target)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }

        // Probe the staged copy — never the original. Opening a SQLite store
        // rewrites its -shm even in readonly mode, and the legacy source has
        // to survive byte-for-byte until the destination has committed. A
        // `default.store` that fails the probe is foreign: discard the
        // staged copies and leave the file exactly where it was.
        guard looksLikeClipStore(staging.appendingPathComponent(legacy.lastPathComponent)) else {
            try? fileManager.removeItem(at: staging)
            log.notice("Skipped legacy migration: \(legacy.lastPathComponent) is not a MemoryClip store")
            return false
        }

        // Commit: rename every staged item into place. The destination file
        // names differ from the legacy ones (`default.store` →
        // `MemoryClip.store`, `.default_SUPPORT` → `.MemoryClip_SUPPORT`),
        // so each rename retargets, not just relocates.
        for item in staged {
            let name = item.lastPathComponent
            let target: URL
            if name.hasPrefix(".") {
                target = externalStorageDirectory(forStoreAt: destination)
            } else if name.hasSuffix("-wal") {
                target = destination.appendingSuffixToLastPathComponent("-wal")
            } else if name.hasSuffix("-shm") {
                target = destination.appendingSuffixToLastPathComponent("-shm")
            } else {
                target = destination
            }
            try fileManager.moveItem(at: item, to: target)
        }
        try? fileManager.removeItem(at: staging)
        log.notice("Migrated clipboard store to the namespaced path (\(staged.count) files)")
        return true
    }

    /// Delete the legacy store after the migrated destination has opened.
    ///
    /// Runs from `init` once the container is live — never inside the copy
    /// itself — so the source survives every failure mode that could still
    /// leave the destination unreadable. `legacy` is injectable so the
    /// migration tests can finalize a temp store rather than the real path.
    static func finalizeLegacyMigration(legacy: URL = legacyStoreURL) {
        let fileManager = FileManager.default
        for suffix in storeSidecarSuffixes {
            let source = legacy.appendingSuffixToLastPathComponent(suffix)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.removeItem(at: source)
            }
        }
        try? fileManager.removeItem(at: externalStorageDirectory(forStoreAt: legacy))
    }

    /// chmod 0600 the store and its sidecars — the store holds every clip the
    /// user ever copied and must not be readable by other local accounts.
    ///
    /// Failures are logged rather than swallowed: "owner-only" is a privacy
    /// claim, and a chmod that silently failed would make the claim a lie
    /// nothing ever surfaces. (Still non-throwing: a store that cannot be
    /// tightened is warned about, not made unusable — the user's own account
    /// can always read it.)
    static func restrictPermissions(forStoreAt url: URL) {
        let fileManager = FileManager.default
        for suffix in storeSidecarSuffixes {
            let target = url.appendingSuffixToLastPathComponent(suffix)
            guard fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: target.path
                )
            } catch {
                log.error("Could not tighten permissions on \(target.lastPathComponent): \(error.localizedDescription)")
            }
        }
        restrictPermissions(forExternalStorageOf: url)
    }

    /// Core Data keeps large `.externalStorage` blobs in a `.NAME_SUPPORT`
    /// directory beside the store, which it creates world-readable (0755/0644).
    /// Those files are clip contents like any other, so they get the same
    /// owner-only treatment as the store itself.
    nonisolated static func externalStorageDirectory(forStoreAt url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent(".\(name)_SUPPORT", isDirectory: true)
    }

    static func restrictPermissions(forExternalStorageOf url: URL) {
        let fileManager = FileManager.default
        let root = externalStorageDirectory(forStoreAt: url)
        guard fileManager.fileExists(atPath: root.path) else { return }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        } catch {
            log.error("Could not tighten permissions on \(root.lastPathComponent): \(error.localizedDescription)")
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for case let entry as URL in enumerator {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: isDirectory ? 0o700 : 0o600],
                    ofItemAtPath: entry.path
                )
            } catch {
                log.error("Could not tighten permissions on \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// The history's footprint on this Mac: the store's directory walked
    /// recursively, which covers the store file, its -wal/-shm sidecars and
    /// the `.NAME_SUPPORT` folder `externalStorageDirectory` names. The
    /// folder sits inside that directory, so one walk sums all of it
    /// exactly once.
    ///
    /// `storeURL` is the default, the same URL `prepareStoreLocation` hands
    /// the container.
    nonisolated static func historyDiskUsage(storeAt url: URL = storeURL) -> Int64 {
        diskUsage(under: url.deletingLastPathComponent())
    }

    /// Every regular file under `directory`, summed. Hidden entries count
    /// (the external-storage folder is dot-prefixed) while a symlink
    /// contributes nothing: a screenshot clip is a link to wherever macOS
    /// saved the file, and this bill must never reach it. (The enumerator
    /// does not descend into a symlinked directory either.)
    nonisolated static func diskUsage(under directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }

    /// Move a broken store out of the way (keeping it for forensics/recovery)
    /// so a fresh one can be created. Returns the directory it was moved to.
    ///
    /// The whole store travels as one unit — database, -wal/-shm sidecars
    /// AND the `.NAME_SUPPORT` external-blob directory — so the quarantine is
    /// a recoverable store, not a database whose image payloads stayed behind.
    @discardableResult
    static func moveStoreAside(forStoreAt url: URL = storeURL) throws -> URL {
        let fileManager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let quarantine = url.deletingLastPathComponent()
            .appendingPathComponent("Damaged-\(stamp)", isDirectory: true)
        try fileManager.createDirectory(
            at: quarantine,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for suffix in storeSidecarSuffixes {
            let source = url.appendingSuffixToLastPathComponent(suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(
                at: source,
                to: quarantine.appendingPathComponent(source.lastPathComponent)
            )
        }
        let support = externalStorageDirectory(forStoreAt: url)
        if fileManager.fileExists(atPath: support.path) {
            try fileManager.moveItem(
                at: support,
                to: quarantine.appendingPathComponent(support.lastPathComponent, isDirectory: true)
            )
        }
        return quarantine
    }

    /// Insert a freshly captured clip. Deduplicates by content hash (a repeat
    /// floats the existing item to the top) and trims history to the cap.
    func insert(_ clip: CapturedClip, sourceBundleID: String?, sourceAppName: String?) {
        if let existing = fetchByHash(clip.hash).first {
            // Duplicate: float to top and refresh source info.
            existing.createdAt = .now
            existing.sourceBundleID = sourceBundleID
            existing.sourceAppName = sourceAppName
            save()
            return
        }

        let item = ClipItem(
            kind: clip.kind,
            text: clip.text,
            richTextData: clip.richTextData,
            imageData: clip.imageData,
            fileURLStrings: clip.fileURLStrings,
            colorHex: clip.colorHex,
            contentHash: clip.hash,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            originalText: clip.originalText
        )
        // Saved before the trim so the cap counts the row that was just
        // captured: `fetchCount` is answered by SQLite, which cannot see an
        // insert that is still pending in the context.
        context.insert(item)
        save()
        enforceCap()

        // Thumbnailing decodes an image, so it happens off the capture path;
        // the row shows a placeholder for the few milliseconds until it lands.
        if item.kind == .image {
            scheduleThumbnailBackfill()
        }
    }

    /// Add clips restored from an export file, keeping everything already here.
    ///
    /// Identity is `contentHash`, the same rule `insert` deduplicates a
    /// re-copied clip by — but a clip the history already holds is DROPPED
    /// here rather than floated to the top. An import restores clips that were
    /// copied long ago, so stamping them `.now` would reorder a history nobody
    /// just copied into, and rewriting the stored row would take a pin with
    /// it. Nothing already in the store is written to at all.
    ///
    /// The cap is deliberately not enforced: a trim would delete stored clips
    /// to make room for imported ones, which is not what "import" may do. The
    /// maintenance pass that runs every 15 minutes applies it on its own terms.
    ///
    /// - Parameter items: clips built by `ExportService.item(from:)`, each
    ///   already carrying its derived hash.
    /// - Returns: the clips that were actually inserted, so the caller can
    ///   file exactly those into pinboards (a clip the store already held is
    ///   left untouched, boards and all).
    @discardableResult
    func insertImported(_ items: [ClipItem]) -> [ClipItem] {
        var inserted: [ClipItem] = []
        // A file can hold the same clip twice, and a pending insert is not
        // reliably visible to the fetch below, so identity is tracked here as
        // well as in the store.
        var seen = Set<String>()
        for item in items {
            guard seen.insert(item.contentHash).inserted else { continue }
            guard fetchByHash(item.contentHash).isEmpty else { continue }
            context.insert(item)
            inserted.append(item)
        }
        guard !inserted.isEmpty else { return [] }
        save()
        if items.contains(where: { $0.kind == .image }) {
            scheduleThumbnailBackfill()
        }
        return inserted
    }

    // MARK: - Pinboards (PRD 06)

    /// Every pinboard, in chip order.
    func pinboards() -> [Pinboard] {
        Pinboard.all(in: context)
    }

    /// One board row for an import: the normalized name, the colour the file
    /// claimed when it names a real one, `order` as given.
    private func createImportBoard(
        named raw: String,
        colorHint: String?,
        order: Int,
        boards: [Pinboard]
    ) -> Pinboard? {
        guard let name = Pinboard.normalizedName(raw) else { return nil }
        let color = PinboardColor(named: colorHint) ?? PinboardColor.nextUnused(in: boards)
        let board = Pinboard(name: name, colorName: color.rawValue, order: order)
        context.insert(board)
        return board
    }

    /// Recreate the pinboards an export lists, appending any that do not
    /// exist yet in the file's order. Names merge case-insensitively: an
    /// existing board keeps its own colour and position, and only the
    /// missing ones are created.
    ///
    /// - Returns: the live boards keyed by lowercased name, for the caller's
    ///   clip-filing pass.
    @discardableResult
    func importPinboards(_ records: [PinboardExport]) -> [String: Pinboard] {
        var boards: [String: Pinboard] = [:]
        var nextOrder = -1
        for board in Pinboard.all(in: context) {
            boards[board.name.lowercased()] = board
            nextOrder = max(nextOrder, board.order)
        }
        var changed = false
        for record in records {
            let key = record.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard boards[key] == nil,
                  let board = createImportBoard(
                      named: record.name,
                      colorHint: record.color,
                      order: nextOrder + 1,
                      boards: Array(boards.values)
                  )
            else { continue }
            nextOrder = board.order
            boards[key] = board
            changed = true
        }
        if changed { save() }
        return boards
    }

    /// File freshly imported clips into the boards their records name.
    ///
    /// `pairs` must be narrowed to the clips `insertImported` actually
    /// accepted: the import leaves a clip the store already holds untouched,
    /// boards included. A `pinboard` name no top-level record describes is
    /// created on the spot, taking its colour from the clip's
    /// `pinboardColor` hint (or the next unused one). Boards the export
    /// describes but no clip references are still created: a board with no
    /// members is a real board.
    func fileImported(
        _ pairs: [(item: ClipItem, record: ClipExport)],
        pinboards records: [PinboardExport]
    ) {
        var boards = importPinboards(records)
        var nextOrder = (boards.values.map(\.order).max() ?? -1) + 1
        var filed = false
        for (item, record) in pairs {
            guard let raw = record.pinboard,
                  let name = Pinboard.normalizedName(raw) else { continue }
            let key = name.lowercased()
            if boards[key] == nil,
               let board = createImportBoard(
                   named: name,
                   colorHint: record.pinboardColor,
                   order: nextOrder,
                   boards: Array(boards.values)
               ) {
                nextOrder += 1
                boards[key] = board
            }
            guard let board = boards[key] else { continue }
            // The order the file carried is written back verbatim: into a
            // fresh board it restores the export's manual order; into an
            // existing one it may tie a member's, which `comesBefore`
            // absorbs by createdAt.
            item.file(into: board, order: record.pinboardOrder)
            filed = true
        }
        if filed { save() }
    }

    /// Record a screenshot that landed in the screenshot folder.
    ///
    /// The clip stores a REFERENCE — `fileURLStrings` holds the path and
    /// `imageData` stays empty — so a screenshot costs a thumbnail rather
    /// than its full weight, and pasting it hands over a file URL exactly as
    /// a file copied in Finder would.
    ///
    /// The content hash matches `ContentParser`'s file hashing, so copying
    /// the same screenshot in Finder floats this row rather than creating a
    /// second one.
    ///
    /// - Returns: the clip, whether newly inserted or the existing row this
    ///   screenshot deduplicated onto. nil only if the insert failed.
    @discardableResult
    func insertScreenshot(at url: URL, createdAt: Date = .now) -> ClipItem? {
        let signature = Self.signature(ofFileAt: url)
        let hash = ContentParser.hashText("file:" + url.absoluteString)
        if let existing = fetchByHash(hash).first {
            // Already known — most likely the user copied the file in Finder
            // before (or after) the watcher saw it. Adopt it as a screenshot
            // so it joins the OCR and note pipelines, and float it.
            existing.isScreenshot = true
            existing.createdAt = createdAt
            // A file rewritten in place keeps its URL — and its hash — but is
            // not the same pixels. Everything derived from the previous file
            // is stale; reset it so OCR and thumbnailing run again.
            if existing.screenshotSignature != signature {
                existing.screenshotSignature = signature
                existing.ocrText = nil
                existing.ocrAttempted = false
                existing.thumbnailData = nil
                existing.thumbnailAttempted = false
                existing.refinedTitle = nil
                existing.refinedSummary = nil
                existing.refinedText = nil
                existing.refinedTags = []
                existing.refineAttempted = false
                existing.translatedText = nil
                existing.sourceLanguage = nil
                existing.notePath = nil
                existing.noteExportedAt = nil
                existing.contentRevision += 1
            }
            save()
            scheduleThumbnailBackfill()
            return existing
        }

        let item = ClipItem(
            kind: .file,
            fileURLStrings: [url.absoluteString],
            contentHash: hash,
            // There is no originating app to record: the screenshot came
            // from the system, not from a copy in some window. Naming it
            // here is what lets the panel label the row "Screenshot".
            sourceBundleID: Self.screenshotSourceBundleID,
            sourceAppName: Self.screenshotSourceName,
            createdAt: createdAt,
            isScreenshot: true,
            screenshotSignature: signature
        )
        context.insert(item)
        save()
        enforceCap()
        scheduleThumbnailBackfill()
        return item
    }

    /// The "same file?" answer for a path: byte size plus modification date.
    /// Deliberately not a content hash — a screenshot can be tens of
    /// megabytes, and the watcher's question (was this file rewritten since
    /// it was recorded?) is answered by the filesystem metadata that changed
    /// with it.
    static func signature(ofFileAt url: URL) -> String? {
        // `URL.resourceValues` caches previously fetched keys PER URL
        // INSTANCE — asking the same URL object twice answers with the first
        // stat it took, which is exactly the file-replaced-in-place case this
        // signature exists to detect. `attributesOfItem` reads live every
        // call.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        // Millisecond precision: a file replaced in place lands seconds or
        // more apart, while sub-millisecond differences are stat/Date
        // representation noise — the same logical file must always produce
        // the same signature.
        return "\(size.int64Value):\(String(format: "%.3f", modified.timeIntervalSince1970))"
    }

    /// Identity recorded on screenshot clips, standing in for a source app.
    static let screenshotSourceBundleID = "com.apple.screencapture"
    static let screenshotSourceName = "Screenshot"

    /// The newest clip whose contentHash matches, if any.
    func fetchByHash(_ hash: String) -> [ClipItem] {
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.contentHash == hash },
            sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return fetch(descriptor)
    }

    /// Most recent clips (pinned items included), newest first.
    func recent(limit: Int) -> [ClipItem] {
        var descriptor = FetchDescriptor<ClipItem>(
            sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return fetch(descriptor)
    }

    /// Every clip in the store, pinned or not: the "1,203 clips" half of the
    /// Storage readout in Settings. A `fetchCount`, so no row materializes.
    func clipCount() -> Int {
        do {
            return try context.fetchCount(FetchDescriptor<ClipItem>())
        } catch {
            log.error("ClipStore clipCount failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// Clips carrying pixels that still need OCR, newest first.
    ///
    /// Two shapes qualify: pasteboard image clips, and screenshot clips
    /// (kind `.file`, flagged) whose pixels are on disk. Ordinary file clips
    /// are deliberately excluded — copying a folder of PDFs in Finder should
    /// not queue a hundred recognition passes.
    func pendingOCR(limit: Int = 20) -> [ClipItem] {
        let imageKind = ClipKind.image.rawValue
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate {
                ($0.kindRaw == imageKind || $0.isScreenshot) && !$0.ocrAttempted
            },
            sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return fetch(descriptor)
    }

    /// Store an OCR result (or the lack of one) against a clip. Marks the
    /// clip as attempted either way so it is not re-queued.
    ///
    /// `revision` is the `contentRevision` the job was launched against:
    /// the result is dropped when the row has been edited, sealed, or
    /// otherwise changed since, because it describes content that is gone.
    /// A sealed clip accepts nothing — OCR output is searchable plaintext,
    /// exactly what sealing removed from the row.
    func applyOCR(_ text: String?, toClipWith uuid: UUID, revision: Int) {
        guard let item = item(withUUID: uuid),
              !item.isSecret,
              item.contentRevision == revision
        else { return }

        // Vision output is persisted AND indexed for search, so it needs the
        // same sensitive-data guard as captured text: a screenshot of a
        // checkout page or a recovery-codes sheet would otherwise turn a
        // secret into searchable plaintext.
        var accepted = text
        if let text, SensitiveFilter.isFilteringEnabled, SensitiveFilter.isLikelyCardNumber(text) {
            accepted = nil
            log.notice("Dropped OCR text: likely card number in image clip")
        }

        item.ocrText = accepted
        item.ocrAttempted = true
        save()
    }

    /// Clips matching the given uuids (order not guaranteed) — used by
    /// queue mode to resolve its stored ids back to live models.
    ///
    /// One indexed, limit-1 fetch per uuid rather than a single
    /// `Set.contains` predicate: that form is NOT translated to SQL, so it
    /// materialized and scanned the entire table — measured 12.8 ms for ten
    /// ids at 50k rows, against a flat 1.3 ms here at any table size. (Below
    /// ~1k rows the scan was the cheaper of the two, by half a millisecond;
    /// the constant-time version is the one that stays usable.)
    func items(withUUIDs uuids: [UUID]) -> [ClipItem] {
        guard !uuids.isEmpty else { return [] }
        var found: [ClipItem] = []
        found.reserveCapacity(uuids.count)
        var seen = Set<UUID>()
        for uuid in uuids where seen.insert(uuid).inserted {
            var descriptor = FetchDescriptor<ClipItem>(
                predicate: #Predicate { $0.uuid == uuid }
            )
            descriptor.fetchLimit = 1
            if let item = fetch(descriptor).first {
                found.append(item)
            }
        }
        return found
    }

    // MARK: - Thumbnails

    /// Clips carrying pixels that still have no thumbnail, newest first —
    /// pasteboard images and screenshot references alike.
    func pendingThumbnails(limit: Int = 8) -> [ClipItem] {
        let imageKind = ClipKind.image.rawValue
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate {
                ($0.kindRaw == imageKind || $0.isScreenshot) && !$0.thumbnailAttempted
            },
            sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return fetch(descriptor)
    }

    /// Store a generated thumbnail (or the lack of one) against a clip.
    /// Marks the clip as attempted either way so an undecodable blob is not
    /// re-decoded on every pass.
    /// - Parameter blob: when given, the image payload is written back
    ///   unchanged. That looks pointless but moves a pre-existing inline blob
    ///   into external storage, which is what stops it being materialized on
    ///   every fetch — clips captured before that attribute existed would
    ///   otherwise keep their bytes in the row forever.
    /// `revision` is the `contentRevision` the thumbnail was launched
    /// against — the write-back is dropped when the row changed since,
    /// because a thumbnail of the previous payload is a picture of content
    /// that is gone, and the blob rewrite would resurrect an old image.
    /// A sealed clip accepts nothing.
    func applyThumbnail(
        _ data: Data?,
        toClipWith uuid: UUID,
        revision: Int,
        rewritingBlob blob: Data? = nil
    ) {
        guard let item = item(withUUID: uuid),
              !item.isSecret,
              item.contentRevision == revision
        else { return }
        item.thumbnailData = data
        item.thumbnailAttempted = true
        if let blob { item.imageData = blob }
        save()
    }

    /// Generate the missing thumbnails, oldest backlog last, in small batches.
    ///
    /// Lazy by design (the OCR coordinator pattern): thumbnailing every image
    /// clip at launch would read every blob back into memory, which is the
    /// very cost thumbnails exist to avoid. A batch is bounded so at most a
    /// handful of full images are resident at once, and decoding happens off
    /// the main actor.
    func backfillThumbnails(batchSize: Int = 8) async {
        guard !isBackfillingThumbnails else { return }
        isBackfillingThumbnails = true
        defer { isBackfillingThumbnails = false }

        while !Task.isCancelled {
            let pending: [(uuid: UUID, revision: Int, payload: ImagePayload?)] =
                pendingThumbnails(limit: batchSize)
                    .map { ($0.uuid, $0.contentRevision, $0.imagePayload) }
            guard !pending.isEmpty else { return }

            for entry in pending {
                if Task.isCancelled { return }
                guard let payload = entry.payload else {
                    applyThumbnail(nil, toClipWith: entry.uuid, revision: entry.revision)
                    continue
                }
                let thumbnail = await Task.detached(priority: .utility) {
                    ClipThumbnail.make(from: payload)
                }.value
                // The blob rewrite only applies to inline payloads (it is what
                // migrates a pre-externalStorage row out of its column). A
                // screenshot clip has no blob to move — its bytes are the
                // user's file and must stay there, untouched.
                if case .data(let data) = payload {
                    applyThumbnail(
                        thumbnail,
                        toClipWith: entry.uuid,
                        revision: entry.revision,
                        rewritingBlob: data
                    )
                } else {
                    applyThumbnail(thumbnail, toClipWith: entry.uuid, revision: entry.revision)
                }
            }
        }
    }

    /// Kick off a backfill without waiting for it.
    func scheduleThumbnailBackfill(batchSize: Int = 8) {
        guard !isBackfillingThumbnails else { return }
        Task { @MainActor [weak self] in
            await self?.backfillThumbnails(batchSize: batchSize)
        }
    }

    func togglePinned(_ item: ClipItem) {
        // Both rules at once: pinning an expiring secret clears its expiry
        // (`togglePinned`), and a board member that loses its pin leaves the
        // board with it (`unpin`) - "Unpin" must never strand a clip in a
        // board it is no longer in.
        if item.isPinned { item.unpin() } else { item.togglePinned() }
        save()
    }

    func delete(_ item: ClipItem) {
        context.delete(item)
        save()
    }

    /// Delete the entire history (pinned items included). Pinboards survive:
    /// they are groupings, not history, so a wipe leaves them standing empty.
    ///
    /// A batch delete: fetching every row and deleting it object-by-object
    /// froze the UI for 7.4 s at 50k clips (3.1 s in-memory), all of it on
    /// the main actor. A batch delete bypasses relationship rules, so the
    /// board memberships are detached first; otherwise every board's `clips`
    /// would keep pointing at rows that no longer exist.
    func nukeAll() {
        do {
            for board in Pinboard.all(in: context) {
                for clip in board.clips {
                    clip.pinboard = nil
                    clip.pinboardOrder = nil
                }
            }
            save()
            try context.delete(model: ClipItem.self)
            save()
            log.notice("nukeAll: deleted all clips")
        } catch {
            log.error("nukeAll failed: \(error.localizedDescription)")
        }
    }

    /// Stamp lastUsedAt after a successful paste/copy-back.
    func markUsed(_ item: ClipItem) {
        item.lastUsedAt = .now
        save()
    }

    // MARK: - Secrets

    /// What must happen to a capture the detector has opinions about. The
    /// watcher switches on this before the clip becomes a row.
    enum SecretDisposition {
        /// Not a secret — or one the allow-list cleared: store it as usual.
        case ordinary
        /// "Don't keep it" mode: the plaintext stays only on the pasteboard
        /// the user copied it to; nothing is stored.
        case drop(SecretKind)
        /// "Keep it encrypted" mode: seal and store through the vault.
        case protect(SecretKind, plaintext: String)
    }

    /// Classify one capture against the secrets rules, in the order the
    /// rules run: the allow-list's verdict first (it is a verdict, not a
    /// suggestion — `classify` is not asked again for an allow-listed
    /// string), then the detector, then the mode picker.
    ///
    /// `clip.text` is the value examined — for a rich-text capture that is
    /// its plain-text form, which is all the detector needs.
    func secretDisposition(for clip: CapturedClip, sourceBundleID: String?) -> SecretDisposition {
        guard let vault = secrets else { return .ordinary }
        guard let text = clip.text, !text.isEmpty else { return .ordinary }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !vault.allows(trimmed) else { return .ordinary }
        guard let kind = SecretDetector.classify(
            text,
            sourceBundleID: sourceBundleID,
            allowGenericToken: SecretSettings.detectsGenericTokens
        ) else { return .ordinary }
        switch SecretSettings.effectiveMode {
        case .keepEncrypted:
            return .protect(kind, plaintext: text)
        case .drop:
            return .drop(kind)
        case .keepPlain:
            return .ordinary
        }
    }

    /// Store a capture the detector called a secret: ciphertext, a label
    /// and a mask — never the plaintext. The dedup identity is an HMAC of
    /// the trimmed plaintext under the vault's key, so re-copying a secret
    /// floats its row rather than writing a twin. One-time codes are the
    /// deliberate exception: each message is a different code, so dedup is
    /// disabled by hashing a fresh uuid instead.
    ///
    /// - Returns: the row, or nil when sealing failed — a secret that could
    ///   not be sealed is dropped, never stored in the clear.
    @discardableResult
    func insertSecret(
        kind: SecretKind,
        plaintext: String,
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> ClipItem? {
        guard let vault = secrets else { return nil }
        let trimmed = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)

        let hash = kind == .oneTimeCode
            ? vault.hash(UUID().uuidString, for: .dedup)
            : vault.hash(trimmed, for: .dedup)
        if let existing = fetchByHash(hash).first {
            existing.createdAt = .now
            existing.sourceBundleID = sourceBundleID
            existing.sourceAppName = sourceAppName
            save()
            return existing
        }

        let cipher: Data
        do {
            cipher = try vault.seal(plaintext)
        } catch {
            log.error("Secret sealing failed; the clip was dropped, not stored in the clear: \(error.localizedDescription)")
            return nil
        }

        let item = ClipItem(
            kind: .text,
            contentHash: hash,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            isSecret: true,
            secretCipher: cipher,
            secretLabel: kind.label,
            secretMasked: SecretMask.mask(trimmed, kind: kind),
            expiresAt: kind == .oneTimeCode && SecretSettings.forgetsOneTimeCodes
                ? Date(timeIntervalSinceNow: SecretSettings.oneTimeCodeLifetime)
                : nil
        )
        context.insert(item)
        save()
        enforceCap()
        return item
    }

    /// Turn an ordinary clip into a secret in place. No authentication: the
    /// plaintext is already on this machine — what changes is where it
    /// lives.
    ///
    /// Every field that ever carried the plaintext or a derivative of it is
    /// wiped; a note or event already exported is NOT retracted (the file
    /// and the calendar entry live outside the store). Only a clip whose
    /// payload is its `text` can be marked — an image's pixels are the
    /// secret, and sealing `text` would leave them standing.
    ///
    /// - Returns: false when the clip could not be sealed; it is left as is.
    @discardableResult
    func markAsSecret(_ item: ClipItem) -> Bool {
        guard let vault = secrets, !item.isSecret else { return false }
        guard let plaintext = item.text, !plaintext.isEmpty else { return false }
        // Only a clip whose whole payload is its text may be sealed. Pixels
        // (`imageData`), file references and screenshot state are payload the
        // cipher does not cover — a row carrying them is rejected rather
        // than half-sealed, which is what the comment above has always
        // promised and what an imported/inconsistent row could otherwise
        /// violate. Residual derived fields with no payload behind them
        /// (a thumbnail without its image) are wiped below, not rejected.
        guard item.imageData?.isEmpty != false,
              item.fileURLStrings.isEmpty,
              !item.isScreenshot
        else {
            log.notice("markAsSecret refused: clip carries a non-text payload")
            return false
        }
        let cipher: Data
        do {
            cipher = try vault.seal(plaintext)
        } catch {
            log.error("markAsSecret: sealing failed, clip left unchanged: \(error.localizedDescription)")
            return false
        }
        let trimmed = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = SecretDetector.classify(
            trimmed,
            sourceBundleID: item.sourceBundleID,
            allowGenericToken: SecretSettings.detectsGenericTokens
        ) ?? .genericToken

        item.text = nil
        item.richTextData = nil
        item.ocrText = nil
        item.originalText = nil
        item.refinedTitle = nil
        item.refinedSummary = nil
        item.refinedText = nil
        item.refinedTags = []
        item.translatedText = nil
        item.clipTranslationText = nil
        item.clipTranslationSource = nil
        item.clipTranslationTarget = nil
        item.sourceLanguage = nil
        item.notePath = nil
        item.noteExportedAt = nil
        item.calendarEventID = nil
        item.thumbnailData = nil
        item.colorHex = nil
        item.kind = .text
        item.isSecret = true
        item.secretCipher = cipher
        item.secretLabel = kind.label
        item.secretMasked = SecretMask.mask(trimmed, kind: kind)
        item.contentHash = vault.hash(trimmed, for: .dedup)
        // The same expiry policy captured one-time codes live under: a code
        // converted by hand forgets itself on the same clock, and a pin —
        // already on the clip or added later — is what lifts it.
        item.expiresAt = kind == .oneTimeCode && SecretSettings.forgetsOneTimeCodes && !item.isPinned
            ? Date(timeIntervalSinceNow: SecretSettings.oneTimeCodeLifetime)
            : nil
        // Every outstanding background result is now stale: sealed or not,
        // the content it was computed against is gone.
        item.contentRevision += 1
        save()
        return true
    }

    /// "Not a Secret": the caller has already authenticated and opened the
    /// ciphertext once; the plaintext's hash joins the allow-list (so the
    /// detector never speaks for it again) and the row becomes an ordinary
    /// clip again.
    func markNotSecret(_ item: ClipItem, plaintext: String) {
        guard let vault = secrets, item.isSecret else { return }
        vault.allow(plaintext.trimmingCharacters(in: .whitespacesAndNewlines))
        item.isSecret = false
        item.secretCipher = nil
        item.secretLabel = nil
        item.secretMasked = nil
        item.expiresAt = nil
        item.text = plaintext
        item.contentHash = ContentParser.hashText("text:\(plaintext)")
        item.contentRevision += 1
        save()
    }

    /// How many stored clips are sealed secrets — the export sheet's
    /// "N secrets were not exported" line reads it.
    func secretCount() -> Int {
        do {
            return try context.fetchCount(
                FetchDescriptor<ClipItem>(predicate: #Predicate { $0.isSecret })
            )
        } catch {
            log.error("ClipStore secretCount failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// Stored plaintext that the detector would call a secret — the number
    /// behind Settings' "N clips already in your history look like secrets".
    /// Secrets themselves are skipped by `text == nil`; the detector runs on
    /// what is left, in Swift, because its rules are not SQL.
    func plaintextSecretCandidateCount() -> Int {
        plaintextSnapshots().filter { snapshot in
            SecretDetector.classify(
                snapshot.text,
                sourceBundleID: snapshot.sourceBundleID,
                allowGenericToken: SecretSettings.detectsGenericTokens
            ) != nil
        }.count
    }

    /// (uuid, text, sourceBundleID) of every non-secret text clip — Sendable
    /// snapshots, so the Settings pane's "already in your history" scan can
    /// classify them OFF the main actor instead of holding it while the
    /// detector works.
    func plaintextSnapshots() -> [(uuid: UUID, text: String, sourceBundleID: String?)] {
        fetch(FetchDescriptor<ClipItem>(
            predicate: #Predicate { !$0.isSecret && $0.text != nil }
        )).map { ($0.uuid, $0.text ?? "", $0.sourceBundleID) }
    }

    /// Seal the listed plaintext clips in place — the pass behind Settings'
    /// "Encrypt N Secrets…". `markAsSecret` wipes each row field by field;
    /// the count returned is what actually moved, so a clip that could not
    /// be sealed is left out of it rather than silently counted.
    @discardableResult
    func encryptSecrets(uuids: Set<UUID>) -> Int {
        items(withUUIDs: Array(uuids)).filter { !$0.isSecret }.reduce(0) { count, item in
            markAsSecret(item) ? count + 1 : count
        }
    }

    /// Delete every secret whose `expiresAt` has passed. Runs from the
    /// maintenance timer and again each time the panel opens, so a dead
    /// code is gone before the user can see it rather than within minutes.
    func expireSecrets() {
        let doomed = fetch(FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.expiresAt != nil && !$0.isPinned }
        )).filter { $0.expiresAt ?? .distantFuture < .now }
        guard !doomed.isEmpty else { return }
        for item in doomed {
            context.delete(item)
        }
        save()
    }

    // MARK: - Refinement and notes

    /// Clips whose extracted text has not been through the local model yet,
    /// newest first.
    ///
    /// The `ocrText != nil` half is what keeps this queue tied to recognition:
    /// a clip is only a refinement candidate once there is something to
    /// refine, so the queue is naturally empty until OCR has run. Clips whose
    /// recognition found nothing legible have `ocrText == nil` and never
    /// enter it.
    ///
    /// The minimum-length rule is applied by the caller rather than here:
    /// SwiftData predicates cannot express `String.count`, and doing it in
    /// SQL would mean a raw fetch. The over-fetch is bounded by `limit`.
    func pendingRefinement(limit: Int = 8) -> [ClipItem] {
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.ocrText != nil && !$0.refineAttempted },
            sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return fetch(descriptor)
    }

    /// Store a refinement result (or the lack of one) against a clip.
    ///
    /// `refineAttempted` is set either way, so a clip the model could not
    /// handle — unavailable, refused, or an implausible rewrite — is never
    /// re-queued forever. Same contract as `applyOCR`.
    ///
    /// The sensitive-content guard runs here for the same reason it runs on
    /// OCR text: the model's output is persisted AND ends up in a note file
    /// outside the 0600 store, so a card number that survived recognition
    /// must not be laundered through refinement into plaintext on disk. The
    /// translation is guarded with it and dropped with it — a card number
    /// translated into English is still a card number.
    ///
    /// - Parameters:
    ///   - language: what the clip's text was recognised as, when it is not
    ///     English. Recorded whether or not a translation came of it — a
    ///     vault query for "what did I capture in Arabic" should find the
    ///     notes this Mac could not translate as well as the ones it could.
    ///   - translation: the English rendering of `ocrText`, when the clip was
    ///     not already in English. nil clears any earlier one, which is what
    ///     a clip whose language could not be translated should end up with.
    ///   - revision: the `contentRevision` the refinement job was launched
    ///     against. A result computed from content that has since been
    ///     edited, sealed or deleted is dropped rather than stamped onto
    ///     the new state — and a sealed clip accepts no derived plaintext
    ///     at all.
    func applyRefinement(
        title: String?,
        summary: String?,
        text: String?,
        tags: [String],
        language: String? = nil,
        translation: TranslatedText? = nil,
        toClipWith uuid: UUID,
        revision: Int
    ) {
        guard let item = item(withUUID: uuid),
              !item.isSecret,
              item.contentRevision == revision
        else { return }

        var acceptedText = text
        var acceptedTitle = title
        var acceptedSummary = summary
        // Tags follow the text they were derived from. Held as a variable
        // rather than inferred from `acceptedText == nil` at the assignment
        // below, because a translated clip legitimately has tags and NO
        // refined text: its body stays the original language and the model
        // labelled the translation.
        var acceptedTags = acceptedText == nil && translation == nil ? [] : tags
        var acceptedTranslation = translation
        if SensitiveFilter.isFilteringEnabled {
            // Tags are persisted AND emitted into note front matter, so they
            // face the same card-number check as the text fields — a number
            // the model returned only as a tag must not reach disk.
            let combined = ([title, summary, text, translation?.text]
                .compactMap { $0 } + [tags.joined(separator: " ")])
                .joined(separator: "\n")
            if !combined.isEmpty, SensitiveFilter.isLikelyCardNumber(combined) {
                acceptedText = nil
                acceptedTitle = nil
                acceptedSummary = nil
                acceptedTags = []
                acceptedTranslation = nil
                log.notice("Dropped refinement: likely card number in refined text")
            }
        }

        item.refinedTitle = acceptedTitle
        item.refinedSummary = acceptedSummary
        item.refinedText = acceptedText
        item.refinedTags = acceptedTags
        item.translatedText = acceptedTranslation?.text
        item.sourceLanguage = language ?? acceptedTranslation?.sourceLanguage
        item.refineAttempted = true
        save()
    }

    /// Record where a note for this clip was written. Non-nil `notePath` is
    /// what makes the next export update the same note instead of writing a
    /// second one.
    ///
    /// `revision` is the `contentRevision` the export was launched against:
    /// a note written for content that has since been edited or sealed is
    /// not recorded — and a sealed clip gains no reference to a file it was
    /// converted to stop pointing at.
    func applyNote(path: String, exportedAt: Date = .now, toClipWith uuid: UUID, revision: Int) {
        guard let item = item(withUUID: uuid),
              !item.isSecret,
              item.contentRevision == revision
        else { return }
        item.notePath = path
        item.noteExportedAt = exportedAt
        save()
    }

    /// Record the calendar event created from this clip, or clear it with nil
    /// when the event has been undone. Non-nil is what marks the clip as
    /// already scheduled.
    ///
    /// `revision` is the `contentRevision` the event's details were detected
    /// on: recording the identifier under a clip whose content has changed
    /// would tie it to an appointment it no longer describes. Clearing
    /// passes `revision: nil` — an undo is always allowed to un-record
    /// itself.
    ///
    /// - Returns: whether the identifier was recorded. False lets the
    ///   caller un-create the event rather than leave it orphaned in the
    ///   user's calendar, unattributable to any clip.
    @discardableResult
    func applyCalendarEvent(_ identifier: String?, toClipWith uuid: UUID, revision: Int? = nil) -> Bool {
        guard let item = item(withUUID: uuid) else { return false }
        if identifier != nil {
            guard !item.isSecret, item.contentRevision == revision else { return false }
        }
        item.calendarEventID = identifier
        save()
        return true
    }

    /// One clip by uuid — the indexed, limit-1 lookup the write-back paths
    /// share.
    func item(withUUID uuid: UUID) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.uuid == uuid }
        )
        descriptor.fetchLimit = 1
        return fetch(descriptor).first
    }

    // MARK: - Editing

    /// Replace a clip's text with the edited draft.
    ///
    /// Kind and content hash are re-derived from the edited string through
    /// the same rules capture runs (`ContentParser.parseText`), so a link
    /// fixed into a sentence comes out `.text` and a URL typed over a note
    /// comes out `.link`; a rich-text clip flattens to whatever its new text
    /// parses as, and its `richTextData` is always cleared.
    ///
    /// If another clip already carries the resulting hash the edit merges
    /// rather than leaving a duplicate: this clip is the survivor, it keeps
    /// the older of the two `createdAt` dates, a pin on either side
    /// survives, and anything only the duplicate held (note, event, source,
    /// refinement, translation: all still true of this identical text)
    /// moves across before the row goes. `createdAt` otherwise does not
    /// move, the clip keeps its place in the list, and
    /// `notePath`/`calendarEventID` stay: the note and the event still
    /// exist, and an export should update them, not write a second one.
    ///
    /// Everything derived from the old text is dropped (all `refined*`,
    /// `refineAttempted`, `translatedText`, `sourceLanguage` and the
    /// `clipTranslation*` cache) because it describes content that is gone.
    /// `refineAttempted` resets to false so the pipeline may refine the new
    /// text (it only picks up clips that also have `ocrText`, which an
    /// edited clip cannot grow here, so nothing re-queues spontaneously).
    ///
    /// - Returns: the pre-edit snapshot the caller keeps for the session
    ///   undo, or nil when the clip is not an editable kind.
    @discardableResult
    func applyEdit(_ item: ClipItem, newText: String) -> ClipEdit.Snapshot? {
        guard ClipDisplay.canEdit(item) else { return nil }
        let snapshot = ClipEdit.Snapshot(
            uuid: item.uuid,
            text: item.text,
            richTextData: item.richTextData,
            kind: item.kind,
            colorHex: item.colorHex,
            contentHash: item.contentHash
        )

        if let parsed = ContentParser.parseText(newText) {
            item.kind = parsed.kind
            item.text = parsed.text
            item.colorHex = parsed.colorHex
            item.contentHash = parsed.hash
        } else {
            // A copy never produces whitespace-only text, but an existing
            // clip is not deleted by editing it to one: it stays, as plain
            // text carrying exactly what was typed.
            item.kind = .text
            item.text = newText
            item.colorHex = nil
            item.contentHash = ContentParser.hashText("text:" + newText)
        }
        item.richTextData = nil

        // Everything derived from the previous text is stale now.
        item.refinedTitle = nil
        item.refinedSummary = nil
        item.refinedText = nil
        item.refinedTags = []
        item.refineAttempted = false
        item.sourceLanguage = nil
        item.translatedText = nil
        item.clipTranslationText = nil
        item.clipTranslationSource = nil
        item.clipTranslationTarget = nil

        // The content changed: results still in flight for the old text
        // (refinement, translation, note export) must be refused by the
        // write-backs rather than stamped onto the new.
        item.contentRevision += 1

        // Merge every other clip already carrying the new hash into this one
        // (fetchByHash's limit-1 would answer only the newest match, and the
        // edited row itself can be it, so the merge fetches them all).
        //
        // The edited row is the survivor: same hash means same content, so
        // the merge is a union. The older creation date wins (the clip was
        // copied then, whatever row carried it), a pin on either side stays
        // pinned, the fresher lastUsedAt wins, and data the survivor lacks,
        // like a note path, a calendar event, source app, and any refinement
        // or translation still valid for this identical text, is absorbed
        // rather than thrown away with the duplicate.
        let hash = item.contentHash
        let duplicates = fetch(FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.contentHash == hash }
        )).filter { $0 !== item }
        for duplicate in duplicates {
            if duplicate.createdAt < item.createdAt {
                item.createdAt = duplicate.createdAt
            }
            if let used = duplicate.lastUsedAt, item.lastUsedAt.map({ used > $0 }) ?? true {
                item.lastUsedAt = used
            }
            item.isPinned = item.isPinned || duplicate.isPinned
            if item.notePath == nil {
                item.notePath = duplicate.notePath
                item.noteExportedAt = duplicate.noteExportedAt
            }
            if item.calendarEventID == nil {
                item.calendarEventID = duplicate.calendarEventID
            }
            if item.sourceBundleID == nil {
                item.sourceBundleID = duplicate.sourceBundleID
                item.sourceAppName = duplicate.sourceAppName
            }
            if item.refinedTitle == nil {
                item.refinedTitle = duplicate.refinedTitle
                item.refinedSummary = duplicate.refinedSummary
                item.refinedText = duplicate.refinedText
                item.refinedTags = duplicate.refinedTags
                item.refineAttempted = item.refineAttempted || duplicate.refineAttempted
            }
            if item.translatedText == nil {
                item.translatedText = duplicate.translatedText
                item.sourceLanguage = item.sourceLanguage ?? duplicate.sourceLanguage
            }
            if item.clipTranslationText == nil {
                item.clipTranslationText = duplicate.clipTranslationText
                item.clipTranslationSource = duplicate.clipTranslationSource
                item.clipTranslationTarget = duplicate.clipTranslationTarget
            }
            context.delete(duplicate)
        }

        save()
        return snapshot
    }

    /// Put a clip back to what `applyEdit` returned: the panel's in-memory
    /// undo, held for the session only. No-op when the clip is gone.
    func restoreEdit(_ snapshot: ClipEdit.Snapshot) {
        guard let item = item(withUUID: snapshot.uuid) else { return }
        item.text = snapshot.text
        item.richTextData = snapshot.richTextData
        item.kind = snapshot.kind
        item.colorHex = snapshot.colorHex
        item.contentHash = snapshot.contentHash
        item.contentRevision += 1
        save()
    }

    // MARK: - Periodic maintenance

    /// Run retention + cap enforcement now, and then every `interval`.
    ///
    /// Both used to be one-shot: `enforceRetention` ran only at launch (so a
    /// Mac left running for weeks never expired anything) and `enforceCap`
    /// only inside `insert` (so lowering the cap in Settings did nothing
    /// until the next copy).
    func startMaintenance(interval: TimeInterval = 900) {
        stopMaintenance()
        performMaintenance()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performMaintenance()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
    }

    func stopMaintenance() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
    }

    /// One maintenance pass: expire old clips, trim to the cap, and top up
    /// any missing thumbnails (clips captured before thumbnails existed).
    func performMaintenance() {
        enforceRetention()
        expireSecrets()
        enforceCap()
        scheduleThumbnailBackfill()
    }

    /// A history limit the History pane can change, in one shape for the
    /// two pickers because the confirmation sheet and the enforcement below
    /// must agree on what "lowering this" deletes.
    enum HistoryLimit {
        /// Keep at most this many unpinned clips. 0 is the stored value for
        /// Unlimited, which is already what `enforceCap` reads it as.
        case cap(Int)
        /// Sweep unpinned clips older than this many days. 0 is Forever.
        case retentionDays(Int)

        /// The number written into the setting.
        var value: Int {
            switch self {
            case .cap(let cap): return cap
            case .retentionDays(let days): return days
            }
        }
    }

    /// How many unpinned clips applying `limit` would delete right now.
    ///
    /// The History pane's confirmation sheet counts with this and
    /// `enforceCap`/`enforceRetention` count with it too. One function is
    /// what makes the sheet's "Delete N older clips?" a promise rather than
    /// an estimate: a confirmation can never lie about its own number.
    func deletionCount(under limit: HistoryLimit) -> Int {
        switch limit {
        case .cap(let cap):
            guard cap > 0 else { return 0 }
            return max(0, unpinnedCount() - cap)
        case .retentionDays(let days):
            guard let cutoff = Self.retentionCutoff(days: days) else { return 0 }
            do {
                return try context.fetchCount(
                    FetchDescriptor<ClipItem>(predicate: expiredPredicate(olderThan: cutoff))
                )
            } catch {
                log.error("ClipStore deletion count failed: \(error.localizedDescription)")
                return 0
            }
        }
    }

    /// The instant before which a `days` retention window expires clips, or
    /// nil when `days` is 0 or less (the stored meaning of Forever). The
    /// preview count and the delete both draw the line here.
    static func retentionCutoff(days: Int, now: Date = .now) -> Date? {
        guard days > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: now)
    }

    /// What retention deletes: unpinned clips created before `cutoff`.
    /// Written once, as a value, so `deletionCount` and `enforceRetention`
    /// run the very same predicate rather than two kept equal by hand.
    private func expiredPredicate(olderThan cutoff: Date) -> Predicate<ClipItem> {
        #Predicate { !$0.isPinned && $0.createdAt < cutoff }
    }

    /// Trim history down to the configured cap (UserDefaults historyCap).
    /// Pinned clips are exempt; a cap of 0 (or less) means unlimited.
    ///
    /// This runs on every capture, so it must not scale with history size.
    /// It used to fetch EVERY unpinned row, fully materialized and sorted,
    /// just to compute `count - cap` — 14.6 ms per ⌘C at the default cap of
    /// 200 and 373 ms at 5000. Now a `fetchCount` decides whether anything
    /// needs trimming at all, and only the doomed rows are materialized.
    func enforceCap() {
        let cap = UserDefaults.standard.integer(forKey: SettingsKeys.historyCap)

        // A capture is one row over the cap, so the common case is the exact
        // path below. A user lowering the cap in Settings (or a first launch
        // against a big imported history) can be tens of thousands over, and
        // deleting those one object at a time took 6.6 s on the main actor —
        // hence the batch pass first.
        while true {
            // `deletionCount` is the arithmetic the Settings confirmation
            // previews, so the number the user agreed to delete is the
            // number deleted here.
            let overflow = deletionCount(under: .cap(cap))
            guard overflow > 0 else { return }
            if overflow <= Self.exactTrimLimit {
                trimOldestUnpinned(count: overflow)
                return
            }
            guard batchTrimOldestUnpinned(overflow: overflow) else {
                // No progress (every candidate shares one timestamp): fall
                // back to the exact path rather than spin.
                trimOldestUnpinned(count: overflow)
                return
            }
        }
    }

    /// Above this many surplus rows, the trim switches from object deletes to
    /// a batch delete.
    static let exactTrimLimit = 64

    private func unpinnedCount() -> Int {
        do {
            return try context.fetchCount(FetchDescriptor<ClipItem>(predicate: #Predicate { !$0.isPinned }))
        } catch {
            log.error("ClipStore fetchCount failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// Delete the `count` oldest unpinned clips. Only those rows are
    /// materialized — the whole point of the `fetchLimit`.
    private func trimOldestUnpinned(count: Int) {
        guard count > 0 else { return }
        var doomed = FetchDescriptor<ClipItem>(
            predicate: #Predicate { !$0.isPinned },
            sortBy: [SortDescriptor(\ClipItem.createdAt, order: .forward)]
        )
        doomed.fetchLimit = count
        for item in fetch(doomed) {
            context.delete(item)
        }
        save()
    }

    /// Batch-delete unpinned clips strictly older than the `overflow`-th
    /// oldest one, without materializing any of them. Strictly-older keeps it
    /// exact when several clips share a timestamp: the leftovers are handled
    /// by the next loop iteration. Returns false when it deleted nothing.
    private func batchTrimOldestUnpinned(overflow: Int) -> Bool {
        var boundaryDescriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { !$0.isPinned },
            sortBy: [SortDescriptor(\ClipItem.createdAt, order: .forward)]
        )
        boundaryDescriptor.fetchOffset = overflow - 1
        boundaryDescriptor.fetchLimit = 1
        guard let boundary = fetch(boundaryDescriptor).first?.createdAt else { return false }

        let before = unpinnedCount()
        do {
            try context.delete(
                model: ClipItem.self,
                where: #Predicate { !$0.isPinned && $0.createdAt < boundary }
            )
            save()
        } catch {
            log.error("ClipStore batch trim failed: \(error.localizedDescription)")
            return false
        }
        return unpinnedCount() < before
    }

    /// Drop unpinned clips older than the configured retention window.
    /// A retentionDays value of 0 (or less) means keep forever.
    func enforceRetention() {
        let days = UserDefaults.standard.integer(forKey: SettingsKeys.retentionDays)
        // `deletionCount` is the arithmetic the Settings confirmation
        // previews, as it is for the cap: the number the user agreed to
        // delete is the number deleted here.
        guard deletionCount(under: .retentionDays(days)) > 0,
              let cutoff = Self.retentionCutoff(days: days) else { return }

        // Batch delete: the expired rows never have to be materialized
        // (2.9 s object-by-object at 50k clips). The predicate is the same
        // value `deletionCount` counts, so a confirmed sheet always deletes
        // exactly what it showed.
        do {
            try context.delete(
                model: ClipItem.self,
                where: expiredPredicate(olderThan: cutoff)
            )
            save()
        } catch {
            log.error("ClipStore enforceRetention failed: \(error.localizedDescription)")
        }
    }

    /// Persist pending changes. Returns false when the save threw — the
    /// caller deciding whether a write "happened" (dedup state, pipeline
    /// bookkeeping, UI claims) must check rather than assume: a swallowed
    /// failure here used to be indistinguishable from success.
    @discardableResult
    func save() -> Bool {
        guard context.hasChanges else { return true }
        do {
            try context.save()
            return true
        } catch {
            log.error("ClipStore save failed: \(error.localizedDescription)")
            return false
        }
    }

    private func fetch(_ descriptor: FetchDescriptor<ClipItem>) -> [ClipItem] {
        do {
            return try context.fetch(descriptor)
        } catch {
            log.error("ClipStore fetch failed: \(error.localizedDescription)")
            return []
        }
    }
}

private extension URL {
    /// "…/MemoryClip.store" + "-wal" → "…/MemoryClip.store-wal". Appending to the last path
    /// component rather than the path keeps this correct for any file name.
    func appendingSuffixToLastPathComponent(_ suffix: String) -> URL {
        guard !suffix.isEmpty else { return self }
        return deletingLastPathComponent()
            .appendingPathComponent(lastPathComponent + suffix)
    }
}

/// `try? context.save()` in a view is the same trap `ClipStore.save()` used
/// to be: the UI shows the action done while nothing persisted, and a
/// wedged store reads as an empty one. The store's own paths log; calls
/// made straight on the context — pinning, filing, deleting, renaming —
/// get the same treatment through these.
extension ModelContext {
    /// Persist, logging a failure instead of dropping it.
    func saveLogged(_ file: StaticString = #fileID, _ line: UInt = #line) {
        do {
            try save()
        } catch {
            log.error("Store write at \(file):\(line) was not persisted: \(error.localizedDescription)")
        }
    }

    /// Fetch, or nil with the failure logged — `try?`'s shape, minus its
    /// silence. A nil here still reads as "no rows" to the caller, but the
    /// failure at least reaches the log.
    func fetchLogged<T>(
        _ descriptor: FetchDescriptor<T>,
        _ file: StaticString = #fileID,
        _ line: UInt = #line
    ) -> [T]? {
        do {
            return try fetch(descriptor)
        } catch {
            log.error("Store read at \(file):\(line) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// `fetchCount` with the same treatment as `fetchLogged`.
    func fetchCountLogged<T>(
        _ descriptor: FetchDescriptor<T>,
        _ file: StaticString = #fileID,
        _ line: UInt = #line
    ) -> Int? {
        do {
            return try fetchCount(descriptor)
        } catch {
            log.error("Store count at \(file):\(line) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Batch delete with the same treatment as `saveLogged`.
    func deleteLogged<T: PersistentModel>(
        model: T.Type,
        _ file: StaticString = #fileID,
        _ line: UInt = #line
    ) {
        do {
            try delete(model: model)
        } catch {
            log.error("Store delete at \(file):\(line) failed: \(error.localizedDescription)")
        }
    }
}
