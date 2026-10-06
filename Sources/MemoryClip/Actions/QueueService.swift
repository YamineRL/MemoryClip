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

    /// How a queue run ended — the progress and the reason, for the UI to
    /// report. `nil` while a run is in flight or before the first one.
    enum StopReason: Equatable {
        /// Every queued clip was handled: its ⌘V was posted, or — only
        /// possible on a one-item run — its value was left on the clipboard.
        /// (Posted, not confirmed: a synthetic event cannot acknowledge that
        /// the destination consumed it — see `PasteService.postCommandV`.)
        case finished(pasted: Int)
        /// The user or teardown stopped the run; handled entries are out,
        /// the rest stay queued for a retry.
        case cancelled
        /// The target app lost focus mid-run; handled entries are out, the
        /// rest stay queued.
        case targetLost
        /// Paste delivery is impossible (auto-paste off, or no target app),
        /// so a multi-clip run would only churn the clipboard — each write
        /// overwriting the last. Nothing ran; the queue is intact.
        case needsAutoPaste
    }

    @Published private(set) var order = QueueOrder()
    /// True while a queue run is pasting, so the UI can show progress.
    @Published private(set) var isPasting = false
    /// How the last run ended — read by the panel to say what happened and
    /// what is still queued.
    @Published private(set) var lastStopReason: StopReason?

    private let store: ClipStore
    private let pasteService: PasteService
    private var run: Task<Void, Never>?
    /// Identifies the run that currently owns `order` / `isPasting` / `run`.
    /// A run whose token no longer matches must not touch that state: it has
    /// been cancelled or superseded, and clearing it would wipe a NEWER run.
    private var currentRunID: UUID?
    /// Entries the in-flight run has already handled — completed pastes and
    /// delivered copies. Held on the service rather than inside the task so
    /// `cancel()` can retire them too: an interrupted run must not leave
    /// already-pasted clips queued to repeat on retry.
    private var completedInRun: Set<UUID> = []

    /// Whether a ⌘V can actually reach `target` — the question the multi-
    /// clip guard asks. Injectable so tests can drive the run loop without
    /// Accessibility trust or a real target application.
    var canDeliverPastes: (NSRunningApplication?) -> Bool = { PasteService.canAutoPaste(into: $0) }

    /// How one ordinary clip is pasted inside a run — injectable so tests
    /// exercise the run loop without delivering real keystrokes. nil takes
    /// the real `PasteService` path.
    var pasteStep: (@MainActor (ClipItem, NSRunningApplication?) async -> PasteService.PasteOutcome)?

    /// How a secret clip is pasted inside a run. `PanelController` wires it
    /// to `SecretsService.pasteOutcome`, which opens the cipher behind one
    /// prompt — the sealer's reuse window covers the whole batch — and writes
    /// the plaintext concealed. Unwired, or with a refused prompt, the clip
    /// is skipped rather than pasted as its mask.
    /// `@MainActor` like the rest of the queue: `ClipItem` is a main-actor
    /// model, and the run already hops actors for the pasteboard writes.
    var secretPaste: (@MainActor (ClipItem, NSRunningApplication?) async -> PasteService.PasteOutcome)?

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
    ///
    /// A run that cannot deliver keystrokes — auto-paste off, or no target
    /// app — is refused outright for a queue of more than one: each write
    /// would only replace the clipboard the previous clip just reached,
    /// leaving the queue "done" with nothing pasted but the last entry.
    /// With one item the copy itself is a sensible outcome, so a single
    /// entry runs regardless.
    func pasteAll(target: NSRunningApplication?, plainOnly: Bool = false) {
        guard !isPasting, !order.isEmpty else { return }
        let items = resolveItems()
        guard !items.isEmpty else {
            order.clear()
            lastStopReason = .finished(pasted: 0)
            return
        }
        guard items.count == 1 || canDeliverPastes(target) else {
            lastStopReason = .needsAutoPaste
            log.notice("Queue run declined: \(items.count) clips and no paste destination")
            return
        }

        isPasting = true
        lastStopReason = nil
        completedInRun = []
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
                guard !item.isDeleted else {
                    // A clip deleted mid-run can never be retried — its
                    // entry is retired like a handled one, not queued
                    // forever.
                    self.completedInRun.insert(item.uuid)
                    continue
                }
                let outcome: PasteService.PasteOutcome
                if item.isSecret {
                    // The row holds no payload `pasteAndWait` could write;
                    // the seam opens the cipher instead. A skipped secret
                    // does not abort the run the way `targetLost` does — it
                    // simply contributes nothing to the pasteboard.
                    outcome = await (self.secretPaste?(item, target) ?? .failed)
                } else if let pasteStep = self.pasteStep {
                    outcome = await pasteStep(item, target)
                } else {
                    outcome = await self.pasteService.pasteAndWait(
                        item,
                        plainOnly: plainOnly,
                        target: target
                    )
                }
                if outcome == .targetLost {
                    // The target app is no longer frontmost. Continuing would
                    // type the remaining clips into whatever now has focus.
                    aborted = true
                    log.notice("Queue run aborted after \(pasted) clips: target app lost focus")
                    break
                }
                // Only a delivered paste counts as done: `.failed` (empty
                // clip, refused secret prompt) and `.copiedOnly` inside a
                // multi-clip run leave the entry queued — the next clip's
                // write would evict its clipboard spot anyway.
                if outcome == .pasted {
                    self.completedInRun.insert(item.uuid)
                    pasted += 1
                } else if items.count == 1, outcome.wroteClipboard {
                    self.completedInRun.insert(item.uuid)
                    pasted += 1
                }
            }
            // Only the run that still owns the state may reset it — a
            // cancelled/superseded run must not clear a newer run's queue.
            guard self.currentRunID == token else { return }
            self.currentRunID = nil
            self.run = nil
            self.isPasting = false
            // Handled entries leave the queue whatever happened; failed and
            // unattempted ones stay — a retry must not repeat what already
            // pasted, and must not silently lose what never ran.
            for uuid in self.completedInRun {
                self.order.remove(uuid)
            }
            self.completedInRun = []
            if !Task.isCancelled && !aborted {
                self.lastStopReason = .finished(pasted: pasted)
                log.notice("Queue run finished: \(pasted) clips")
            } else {
                self.lastStopReason = aborted ? .targetLost : .cancelled
            }
        }
    }

    /// Cancel an in-flight queue run (panel closing, app teardown).
    ///
    /// Entries the run already handled are retired with it so a retry does
    /// not paste them twice; the rest stay queued for that retry. The
    /// cancelled task can no longer mutate any state because its run token
    /// is dropped here.
    func cancel() {
        guard let run else { return }
        currentRunID = nil
        run.cancel()
        self.run = nil
        isPasting = false
        for uuid in completedInRun {
            order.remove(uuid)
        }
        completedInRun = []
        lastStopReason = .cancelled
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
