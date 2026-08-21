import Foundation
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

    init(inMemory: Bool = false) throws {
        let schema = Schema([ClipItem.self])
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
        }
    }

    // MARK: - On-disk location, permissions and legacy migration

    /// `~/Library/Application Support`.
    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
    }

    /// Directory holding MemoryClip's store, namespaced by bundle identifier.
    static var storeDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("app.memoryclip", isDirectory: true)
    }

    /// The store MemoryClip uses from now on.
    static var storeURL: URL {
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
    static func createStoreDirectory(at directory: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    /// Move a pre-existing store (and its -wal/-shm sidecars) to the new
    /// namespaced path. No-op unless the legacy store exists AND the new one
    /// does not, so it runs exactly once and can never clobber live data.
    ///
    /// Failures are surfaced: silently starting with an empty history would
    /// look, to the user, exactly like losing it.
    @discardableResult
    static func migrateLegacyStore(from legacy: URL, to destination: URL) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacy.path) else { return false }
        guard !fileManager.fileExists(atPath: destination.path) else { return false }

        // Copy first, then remove: a crash mid-migration leaves the original
        // intact rather than a half-moved pair of files.
        var copied: [URL] = []
        do {
            for suffix in storeSidecarSuffixes {
                let source = legacy.appendingSuffixToLastPathComponent(suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let target = destination.appendingSuffixToLastPathComponent(suffix)
                try fileManager.copyItem(at: source, to: target)
                copied.append(target)
            }
            // Image clips over the inlining threshold live in a `.NAME_SUPPORT`
            // directory beside the store, keyed by the store's file name. It
            // has to travel with the store or every large image goes missing.
            let legacySupport = externalStorageDirectory(forStoreAt: legacy)
            if fileManager.fileExists(atPath: legacySupport.path) {
                let target = externalStorageDirectory(forStoreAt: destination)
                try fileManager.copyItem(at: legacySupport, to: target)
                copied.append(target)
            }
        } catch {
            // Roll back partial copies so the next launch retries cleanly.
            for url in copied { try? fileManager.removeItem(at: url) }
            throw error
        }

        for suffix in storeSidecarSuffixes {
            let source = legacy.appendingSuffixToLastPathComponent(suffix)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.removeItem(at: source)
            }
        }
        try? fileManager.removeItem(at: externalStorageDirectory(forStoreAt: legacy))
        log.notice("Migrated clipboard store to the namespaced path (\(copied.count) files)")
        return true
    }

    /// chmod 0600 the store and its sidecars — the store holds every clip the
    /// user ever copied and must not be readable by other local accounts.
    static func restrictPermissions(forStoreAt url: URL) {
        let fileManager = FileManager.default
        for suffix in storeSidecarSuffixes {
            let target = url.appendingSuffixToLastPathComponent(suffix)
            guard fileManager.fileExists(atPath: target.path) else { continue }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        restrictPermissions(forExternalStorageOf: url)
    }

    /// Core Data keeps large `.externalStorage` blobs in a `.NAME_SUPPORT`
    /// directory beside the store, which it creates world-readable (0755/0644).
    /// Those files are clip contents like any other, so they get the same
    /// owner-only treatment as the store itself.
    static func externalStorageDirectory(forStoreAt url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent(".\(name)_SUPPORT", isDirectory: true)
    }

    static func restrictPermissions(forExternalStorageOf url: URL) {
        let fileManager = FileManager.default
        let root = externalStorageDirectory(forStoreAt: url)
        guard fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for case let entry as URL in enumerator {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            try? fileManager.setAttributes(
                [.posixPermissions: isDirectory ? 0o700 : 0o600],
                ofItemAtPath: entry.path
            )
        }
    }

    /// Move a broken store out of the way (keeping it for forensics/recovery)
    /// so a fresh one can be created. Returns the directory it was moved to.
    @discardableResult
    static func moveStoreAside() throws -> URL {
        let fileManager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let quarantine = storeDirectory.appendingPathComponent("Damaged-\(stamp)", isDirectory: true)
        try fileManager.createDirectory(
            at: quarantine,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for suffix in storeSidecarSuffixes {
            let source = storeURL.appendingSuffixToLastPathComponent(suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(
                at: source,
                to: quarantine.appendingPathComponent(source.lastPathComponent)
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
            sourceAppName: sourceAppName
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
    /// - Returns: how many were new.
    @discardableResult
    func insertImported(_ items: [ClipItem]) -> Int {
        var inserted = 0
        // A file can hold the same clip twice, and a pending insert is not
        // reliably visible to the fetch below, so identity is tracked here as
        // well as in the store.
        var seen = Set<String>()
        for item in items {
            guard seen.insert(item.contentHash).inserted else { continue }
            guard fetchByHash(item.contentHash).isEmpty else { continue }
            context.insert(item)
            inserted += 1
        }
        guard inserted > 0 else { return 0 }
        save()
        if items.contains(where: { $0.kind == .image }) {
            scheduleThumbnailBackfill()
        }
        return inserted
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
        let hash = ContentParser.hashText("file:" + url.absoluteString)
        if let existing = fetchByHash(hash).first {
            // Already known — most likely the user copied the file in Finder
            // before (or after) the watcher saw it. Adopt it as a screenshot
            // so it joins the OCR and note pipelines, and float it.
            existing.isScreenshot = true
            existing.createdAt = createdAt
            save()
            if !existing.thumbnailAttempted { scheduleThumbnailBackfill() }
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
            isScreenshot: true
        )
        context.insert(item)
        save()
        enforceCap()
        scheduleThumbnailBackfill()
        return item
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
    func applyOCR(_ text: String?, toClipWith uuid: UUID) {
        guard let item = item(withUUID: uuid) else { return }

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
    func applyThumbnail(_ data: Data?, toClipWith uuid: UUID, rewritingBlob blob: Data? = nil) {
        guard let item = item(withUUID: uuid) else { return }
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
            let pending: [(uuid: UUID, payload: ImagePayload?)] = pendingThumbnails(limit: batchSize)
                .map { ($0.uuid, $0.imagePayload) }
            guard !pending.isEmpty else { return }

            for entry in pending {
                if Task.isCancelled { return }
                guard let payload = entry.payload else {
                    applyThumbnail(nil, toClipWith: entry.uuid)
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
                    applyThumbnail(thumbnail, toClipWith: entry.uuid, rewritingBlob: data)
                } else {
                    applyThumbnail(thumbnail, toClipWith: entry.uuid)
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
        item.isPinned.toggle()
        save()
    }

    func delete(_ item: ClipItem) {
        context.delete(item)
        save()
    }

    /// Delete the entire history (pinned items included).
    ///
    /// A batch delete: fetching every row and deleting it object-by-object
    /// froze the UI for 7.4 s at 50k clips (3.1 s in-memory), all of it on
    /// the main actor.
    func nukeAll() {
        do {
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
    func applyRefinement(
        title: String?,
        summary: String?,
        text: String?,
        tags: [String],
        language: String? = nil,
        translation: TranslatedText? = nil,
        toClipWith uuid: UUID
    ) {
        guard let item = item(withUUID: uuid) else { return }

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
            let combined = [title, summary, text, translation?.text]
                .compactMap { $0 }
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
    func applyNote(path: String, exportedAt: Date = .now, toClipWith uuid: UUID) {
        guard let item = item(withUUID: uuid) else { return }
        item.notePath = path
        item.noteExportedAt = exportedAt
        save()
    }

    /// Record the calendar event created from this clip, or clear it with nil
    /// when the event has been undone. Non-nil is what marks the clip as
    /// already scheduled.
    func applyCalendarEvent(_ identifier: String?, toClipWith uuid: UUID) {
        guard let item = item(withUUID: uuid) else { return }
        item.calendarEventID = identifier
        save()
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
        enforceCap()
        scheduleThumbnailBackfill()
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
        guard cap > 0 else { return }

        // A capture is one row over the cap, so the common case is the exact
        // path below. A user lowering the cap in Settings (or a first launch
        // against a big imported history) can be tens of thousands over, and
        // deleting those one object at a time took 6.6 s on the main actor —
        // hence the batch pass first.
        while true {
            let overflow = unpinnedCount() - cap
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
        guard days > 0 else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) else {
            return
        }

        // Batch delete: the expired rows never have to be materialized
        // (2.9 s object-by-object at 50k clips).
        do {
            try context.delete(
                model: ClipItem.self,
                where: #Predicate { !$0.isPinned && $0.createdAt < cutoff }
            )
            save()
        } catch {
            log.error("ClipStore enforceRetention failed: \(error.localizedDescription)")
        }
    }

    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            log.error("ClipStore save failed: \(error.localizedDescription)")
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
