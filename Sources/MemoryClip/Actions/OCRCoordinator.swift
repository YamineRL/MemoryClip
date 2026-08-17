import Foundation

/// Drives background OCR over image clips (Phase 3).
///
/// Recognition itself is off-actor and runs several images at a time; only
/// the fetch of pending clips and the write-back of results touch the model
/// context, both on @MainActor. Clips are handed across the actor boundary as
/// (uuid, imageData) pairs because `ClipItem` is not Sendable — results come
/// back as (uuid, text) and are re-resolved by uuid before being written.
@MainActor
final class OCRCoordinator {
    /// UserDefaults key for the "extract text from images" setting.
    nonisolated static let enabledKey = "ocrEnabled"

    /// How many pending clips are fetched (and handed to the task group) at a
    /// time. Bounds how much image data is resident at once — a batch of
    /// pasteboard screenshots is ~1.3 MB each — and gives the drain a natural
    /// point to re-check the setting and pause. (Screenshot clips captured
    /// from the watched folder cost nothing here: they carry a URL that
    /// Vision opens itself, not bytes.)
    static let batchSize = 8

    /// How many images are recognized concurrently. Vision recognition is
    /// mostly single-threaded per request, so running one at a time used 1 of
    /// 10 cores; running all of them at once would take the machine over
    /// while the user is trying to work. Measured on an M1 Pro (10 cores,
    /// release, 1512x982 screenshots, ms per image): width 1 = 691, 2 = 400,
    /// 3 = 288, 4 = 270, 6 = 202, 8 = 198. Width 3 takes 2.4x off the serial
    /// cost; 4 adds only 6% more and 6 saturates the machine for the sake of
    /// background work the user is not waiting on.
    static let concurrency = 3

    /// Hard bound on the images one drain will process. `batchSize` alone
    /// never bounded anything: the drain loops and re-fetches until the queue
    /// is empty, so a 200-image backlog used to be one continuous run. When
    /// this bound is hit the drain ends and re-arms itself after
    /// `resumeDelay`, so a big backlog is worked through in bursts instead of
    /// monopolising the machine.
    static let maxImagesPerDrain = 64

    /// Breather between batches, so OCR never holds the recognizer (or the
    /// CPU) continuously.
    static let batchPause: Duration = .milliseconds(250)

    /// How long a bounded-out drain waits before picking the backlog back up.
    static let resumeDelay: Duration = .seconds(20)

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [enabledKey: true])
    }

    /// Nonisolated so the per-image check can run inside the task group,
    /// off the main actor. UserDefaults reads are thread-safe.
    nonisolated static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    /// Called on the main actor after a batch has had its recognition
    /// results applied, when at least one clip came back with text.
    ///
    /// Recognition is the *middle* of the pipeline, not the end: the text it
    /// writes is what refinement and note export consume. Without this hook
    /// those two only ever ran at launch, so a screenshot taken while the app
    /// was up was recognised and then sat there — the clip had `ocrText` and
    /// nothing ever asked for a note. AppDelegate wires this to
    /// `NoteCoordinator.processPending()`.
    ///
    /// Fired per batch rather than per drain so a long catch-up starts
    /// producing notes immediately instead of at the end of the backlog.
    ///
    /// The clips that produced text are named rather than merely counted,
    /// because the calendar's automatic path needs the clip and not just the
    /// news: a screenshot has no text when it is captured, so this is the
    /// first moment its appointment exists, and handing over the uuids is what
    /// lets that path act on exactly those clips instead of re-reading
    /// history. Refinement ignores the list and asks its own queue.
    var onRecognition: (@MainActor ([UUID]) -> Void)?

    private let store: ClipStore
    private var task: Task<Void, Never>?
    /// Identifies the drain that owns `task`. A run whose token no longer
    /// matches must not clear the handle: cancellation is cooperative and
    /// Vision does not check it, so a stopped run can still be unwinding
    /// while a NEW one is in flight, and clearing then would let a third
    /// drain start alongside it and OCR every image twice. The same token
    /// retires a scheduled resume after `stop()`.
    private var runID = 0
    /// Watches the OCR setting so flipping it ON drains the existing backlog
    /// immediately instead of waiting for the next capture or a restart.
    /// `nonisolated(unsafe)` only so `deinit` (which is nonisolated) can
    /// unregister it; the token is written once in `init` and never mutated
    /// afterwards.
    private nonisolated(unsafe) var settingsObserver: (any NSObjectProtocol)?
    private var lastKnownEnabled: Bool

    init(store: ClipStore) {
        self.store = store
        self.lastKnownEnabled = Self.isEnabled
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.settingDidChange()
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    /// Process every image clip that has not been through OCR yet. Calls
    /// while a run is in flight are ignored — the in-flight run picks up
    /// anything newly captured when it loops.
    ///
    /// The enabled check lives inside `drain`, which re-reads it as it goes,
    /// so turning the setting off mid-run stops the run.
    func processPending() {
        guard task == nil else { return }
        runID &+= 1
        let token = runID
        task = Task { @MainActor [weak self] in
            let backlogRemains = await self?.drain() ?? false
            guard let self, self.runID == token else { return }
            self.task = nil
            if backlogRemains {
                self.scheduleResume(token: token)
            }
        }
    }

    /// Cancel any in-flight recognition (app teardown).
    func stop() {
        task?.cancel()
        task = nil
        // Retire the token so the run still unwinding can't clear the handle
        // of whatever run starts next — and so a scheduled resume from that
        // run never fires.
        runID &+= 1
    }

    private func settingDidChange() {
        let enabled = Self.isEnabled
        guard enabled != lastKnownEnabled else { return }
        lastKnownEnabled = enabled
        if enabled {
            processPending()
        }
    }

    /// Pick the backlog back up after a drain hit `maxImagesPerDrain`.
    ///
    /// Deliberately untracked by `task` (the coordinator is idle while it
    /// waits, so a new capture can start a drain sooner); `runID` is what
    /// retires it, so `stop()` cancels the resume too.
    private func scheduleResume(token: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.resumeDelay)
            guard let self, self.runID == token else { return }
            self.processPending()
        }
    }

    /// Work through the pending queue in bounded batches.
    ///
    /// Returns true when it stopped because `maxImagesPerDrain` was reached
    /// and clips are still waiting, false when the queue drained, OCR was
    /// switched off, or the run was cancelled.
    private func drain() async -> Bool {
        var processed = 0
        while !Task.isCancelled {
            // Re-read every batch: the user can turn OCR off mid-run.
            guard Self.isEnabled else { return false }
            guard processed < Self.maxImagesPerDrain else {
                // Only report a backlog if something is actually left.
                return !store.pendingOCR(limit: 1).isEmpty
            }

            let pending: [(uuid: UUID, payload: ImagePayload)] = store
                .pendingOCR(limit: Self.batchSize)
                .compactMap { item in
                    guard let payload = item.imagePayload else {
                        // Nothing to read — an empty blob, or a screenshot
                        // whose file has been moved or deleted since it was
                        // captured. Mark it done so it stops coming back
                        // around; the clip keeps whatever thumbnail it has.
                        item.ocrAttempted = true
                        return nil
                    }
                    return (item.uuid, payload)
                }
            store.save()
            guard !pending.isEmpty else { return false }

            let results = await Self.recognizeAll(pending, concurrency: Self.concurrency)
            var recognized: [UUID] = []
            for (uuid, text) in results {
                // ocrAttempted is set here even when text is nil, so a clip
                // Vision could make nothing of is never re-queued forever.
                store.applyOCR(text, toClipWith: uuid)
                if let text {
                    recognized.append(uuid)
                    log.notice("OCR extracted \(text.count) characters from an image clip")
                }
            }
            processed += results.count
            // Only when there is text: a batch Vision made nothing of leaves
            // no clip pending refinement, so waking that stage would be a
            // query for an empty queue.
            if !recognized.isEmpty { onRecognition?(recognized) }

            // Anything skipped (OCR switched off, or cancelled, mid-batch)
            // is left pending on purpose: it is picked up when OCR is
            // switched back on.
            if results.count < pending.count { return false }

            try? await Task.sleep(for: Self.batchPause)
        }
        return false
    }

    /// Recognize a batch off the main actor, at most `concurrency` at a time.
    ///
    /// Only clips that were actually attempted come back; an image skipped
    /// because OCR was switched off (or the run was cancelled) is omitted
    /// rather than reported as "no text", so it stays queued.
    nonisolated static func recognizeAll(
        _ pending: [(uuid: UUID, payload: ImagePayload)],
        concurrency: Int
    ) async -> [(uuid: UUID, text: String?)] {
        guard !pending.isEmpty else { return [] }
        let width = max(1, min(concurrency, pending.count))

        return await withTaskGroup(of: (uuid: UUID, text: String?)?.self) { group in
            var results: [(uuid: UUID, text: String?)] = []
            results.reserveCapacity(pending.count)
            var index = 0
            var running = 0

            func harvest() async {
                if let result = await group.next() {
                    running -= 1
                    if let result { results.append(result) }
                }
            }

            while index < pending.count {
                if running == width { await harvest() }
                let entry = pending[index]
                index += 1
                running += 1
                group.addTask {
                    // Re-checked per image, not just per batch: a 40-image
                    // backlog is minutes of work, and switching OCR off must
                    // stop it promptly rather than at the next batch.
                    guard !Task.isCancelled, OCRCoordinator.isEnabled else { return nil }
                    return (entry.uuid, await OCRService.recognizeText(in: entry.payload))
                }
            }
            while running > 0 { await harvest() }
            return results
        }
    }
}
