import AppKit
import Combine

/// Ordered set of queued clip identifiers.
///
/// Pure value logic, split out from `QueueService` so ordering and
/// membership can be tested without a model context or a pasteboard.
struct QueueOrder: Equatable {
    private(set) var ids: [UUID] = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// 1-based position of `id` in the queue, or nil when not queued —
    /// the badge number shown on a queued row.
    func position(of id: UUID) -> Int? {
        ids.firstIndex(of: id).map { $0 + 1 }
    }

    /// Append when absent, remove when present. Removing renumbers the
    /// remaining entries implicitly (positions are index-derived).
    mutating func toggle(_ id: UUID) {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
    }

    mutating func remove(_ id: UUID) {
        ids.removeAll { $0 == id }
    }

    /// Drop entries no longer backed by a live clip (deleted / trimmed).
    mutating func retain(existing: Set<UUID>) {
        ids.removeAll { !existing.contains($0) }
    }

    mutating func clear() {
        ids.removeAll()
    }
}

/// Queue mode (Phase 3): mark several clips, then paste them in order.
///
/// Each item is written to the pasteboard and pasted into the target app,
/// and the run waits for the previous ⌘V to have actually been delivered
/// (`PasteService.pasteAndWait`) before overwriting the pasteboard with the
/// next clip — a fixed delay measured from the *write* races the keystroke
/// and makes a busy target skip or double-paste entries.
@MainActor
final class QueueService: ObservableObject {
    /// Extra pause between one paste completing and the next clip being
    /// written, on top of the settle time `PasteService` already waits.
    static let pasteInterval: TimeInterval = 0.35

    @Published private(set) var order = QueueOrder()
    /// True while a queue run is pasting, so the UI can show progress.
    @Published private(set) var isPasting = false

    private let store: ClipStore
    private let pasteService: PasteService
    private var run: Task<Void, Never>?
    /// Identifies the run that currently owns `order` / `isPasting` / `run`.
    /// A run whose token no longer matches must not touch that state: it has
    /// been cancelled or superseded, and clearing it would wipe a NEWER run.
    private var currentRunID: UUID?

    init(store: ClipStore, pasteService: PasteService) {
        self.store = store
        self.pasteService = pasteService
    }

    var isEmpty: Bool { order.isEmpty }
    var count: Int { order.count }

    func isQueued(_ item: ClipItem) -> Bool { order.contains(item.uuid) }

    func position(of item: ClipItem) -> Int? { order.position(of: item.uuid) }

    func toggle(_ item: ClipItem) {
        order.toggle(item.uuid)
    }

    func clear() {
        order.clear()
    }

    /// Paste every queued clip into `target`, in queue order, then clear
    /// the queue. Entries whose clip has since been deleted are skipped.
    func pasteAll(target: NSRunningApplication?, plainOnly: Bool = false) {
        guard !isPasting, !order.isEmpty else { return }
        let items = resolveItems()
        guard !items.isEmpty else {
            order.clear()
            return
        }

        isPasting = true
        let token = UUID()
        currentRunID = token
        run = Task { @MainActor [weak self] in
            guard let self else { return }
            var pasted = 0
            var aborted = false
            for (index, item) in items.enumerated() {
                if Task.isCancelled { break }
                if index > 0 {
                    try? await Task.sleep(for: .seconds(Self.pasteInterval))
                    if Task.isCancelled { break }
                }
                guard !item.isDeleted else { continue }
                let outcome = await self.pasteService.pasteAndWait(
                    item,
                    plainOnly: plainOnly,
                    target: target
                )
                if outcome == .targetLost {
                    // The target app is no longer frontmost. Continuing would
                    // type the remaining clips into whatever now has focus.
                    aborted = true
                    log.notice("Queue run aborted after \(pasted) clips: target app lost focus")
                    break
                }
                if outcome.wroteClipboard { pasted += 1 }
            }
            // Only the run that still owns the state may reset it — a
            // cancelled/superseded run must not clear a newer run's queue.
            guard self.currentRunID == token else { return }
            self.currentRunID = nil
            self.run = nil
            self.isPasting = false
            if !Task.isCancelled && !aborted {
                self.order.clear()
                log.notice("Queue run finished: \(pasted) clips")
            }
        }
    }

    /// Cancel an in-flight queue run (panel closing, app teardown).
    ///
    /// The queue itself is left intact so the user can retry; the cancelled
    /// task can no longer mutate any state because its run token is dropped
    /// here.
    func cancel() {
        guard let run else { return }
        currentRunID = nil
        run.cancel()
        self.run = nil
        isPasting = false
    }

    /// Live clips for the queued ids, in queue order. Also prunes ids whose
    /// clip no longer exists.
    private func resolveItems() -> [ClipItem] {
        let found = store.items(withUUIDs: order.ids)
        let byID = Dictionary(found.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        order.retain(existing: Set(byID.keys))
        return order.ids.compactMap { byID[$0] }
    }
}
