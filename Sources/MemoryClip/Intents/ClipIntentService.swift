import AppIntents
import AppKit
import Foundation
import UniformTypeIdentifiers

/// What an intent can answer from the store.
///
/// Every `perform()` funnels through here so the behaviour is tested
/// against an in-memory `ClipStore`; the running app only supplies the
/// real one via `live()`. The store is main-actor, so the service is too,
/// and everything it hands back is a Sendable value (`ClipEntity`,
/// `IntentFile`, `Bool`) — a `ClipItem` never crosses the boundary.
@MainActor
final class ClipIntentService {
    /// The ceiling Search Clips accepts (`limit` above it is clamped, not
    /// refused, so a sloppy shortcut still gets its best page).
    static let searchLimitMax = 100

    /// The errors a `perform()` can surface, phrased for the Shortcuts
    /// run sheet rather than for a log.
    enum IntentError: Error, LocalizedError {
        case locked
        case storeUnavailable
        case clipMissing
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .locked: return loc("MemoryClip is locked.")
            case .storeUnavailable: return loc("Could not open the clip store.")
            case .clipMissing: return loc("That clip is not in the history anymore.")
            case .copyFailed: return loc("That clip has nothing to put on the clipboard.")
            }
        }
    }

    private let store: ClipStore
    private let pasteboard: NSPasteboard
    /// The app-lock check, injectable so tests see it being consulted
    /// without a real LAContext.
    private let unlock: @MainActor () async -> Bool

    init(
        store: ClipStore,
        pasteboard: NSPasteboard = .general,
        unlock: (@MainActor () async -> Bool)? = nil
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.unlock = unlock ?? {
            await AppLockService.shared.gate(
                reason: loc("Unlock MemoryClip to answer a shortcut")
            )
        }
    }

    /// The service the intents use: the on-disk store, the general
    /// pasteboard, the real lock. Nil only when the store cannot be opened.
    static func live() -> ClipIntentService? {
        guard let store = try? ClipStore() else { return nil }
        return ClipIntentService(store: store)
    }

    /// Whether an intent may hand this clip's content out in clear.
    ///
    /// A named seam, not dead code: the `isSecret` column is feat/secrets'
    /// schema and does not exist on this branch, so nothing is withheld
    /// yet. The integration branch turns this into `!clip.isSecret`, which
    /// is why every read below funnels through it — secret rows are then
    /// invisible to `latest`, come back from `search` carrying no
    /// plaintext, and cannot be resolved for a copy.
    func isShareable(_ clip: ClipItem) -> Bool {
        true
    }

    /// The lock gate PRD 03 puts in front of everything but Open
    /// MemoryClip: passes immediately when the lock is off or the window
    /// is still open, otherwise runs one authentication.
    func requireUnlock() async throws {
        guard await unlock() else { throw IntentError.locked }
    }

    /// The clip behind a `ClipEntity` id, or nil when it is gone (or a
    /// row an intent must not read — see `isShareable`).
    private func item(for uuid: UUID) -> ClipItem? {
        store.items(withUUIDs: [uuid]).first(where: isShareable)
    }

    /// Newest clip of `kind`, newest-first.
    ///
    /// The fetch over-fetches a page because a stored row can be withheld
    /// without the predicate knowing (see `isShareable`): with a 1-row
    /// limit such a clip would hide the real answer behind it.
    func latest(kind: ClipKindOption) async throws -> ClipEntity? {
        try await requireUnlock()
        let filter = ClipFilter(type: kind.typeFilter)
        return try store.context
            .fetch(filter.fetchDescriptor(limit: ClipFilter.pageSize))
            .first(where: isShareable)
            .map(ClipEntity.init(clip:))
    }

    /// The file Shortcuts receives for the newest clip of a kind.
    func latestFile(kind: ClipKindOption) async throws -> IntentFile? {
        try await requireUnlock()
        let filter = ClipFilter(type: kind.typeFilter)
        guard let clip = try store.context
            .fetch(filter.fetchDescriptor(limit: ClipFilter.pageSize))
            .first(where: isShareable) else { return nil }
        return try intentFile(for: clip)
    }

    /// The panel's own search: the SQL predicate asks what it can (type,
    /// source, the longest term) and `refine` asks the rest, so what
    /// Shortcuts finds is what the panel would show.
    func search(query: String, limit: Int) async throws -> [ClipEntity] {
        try await requireUnlock()
        let clamped = max(1, min(limit, Self.searchLimitMax))
        let filter = ClipFilter(search: query)
        let page = try store.context.fetch(filter.fetchDescriptor(limit: ClipFilter.pageSize))
        return filter.refine(page)
            .filter(isShareable)
            .prefix(clamped)
            .map(ClipEntity.init(clip:))
    }

    /// The entity behind a `ClipEntity` id — how the Shortcuts picker
    /// resolves chosen clips.
    func resolve(_ uuid: UUID) async throws -> ClipEntity? {
        try await requireUnlock()
        return item(for: uuid).map(ClipEntity.init(clip:))
    }

    /// Put a clip back on the pasteboard through the same payload builder
    /// a panel copy uses. False when the clip has nothing writable (a
    /// withheld row, a file that no longer exists).
    @discardableResult
    func copy(uuid: UUID) async throws -> Bool {
        try await requireUnlock()
        guard let clip = item(for: uuid) else { return false }
        let writer = PasteService(
            store: store,
            watcher: PasteboardWatcher(store: store, pasteboard: pasteboard),
            pasteboard: pasteboard
        )
        return writer.write(clip, plainOnly: false)
    }

    /// The file Shortcuts receives for a clip: a real file reference for a
    /// file clip, the image bytes as PNG/JPEG for an image, and the clip's
    /// text as a .txt everywhere else — which Shortcuts hands back as
    /// Text when the next action asks for it.
    private func intentFile(for clip: ClipItem) throws -> IntentFile {
        if clip.kind == .file,
           let urlString = clip.fileURLStrings.first,
           let url = URL(string: urlString) {
            return IntentFile(fileURL: url)
        }
        if clip.kind == .image, let data = clip.imageData, !data.isEmpty {
            let type: UTType = PasteService.imageType(for: data) == .png ? .png : .jpeg
            return IntentFile(data: data, filename: "Clip.\(type.preferredFilenameExtension ?? "img")", type: type)
        }
        guard let text = clip.text else { throw IntentError.copyFailed }
        return IntentFile(data: Data(text.utf8), filename: "Clip.txt", type: .plainText)
    }
}
