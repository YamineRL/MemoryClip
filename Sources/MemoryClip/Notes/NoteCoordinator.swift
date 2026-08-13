import Foundation

/// Drives the last two stages of the screenshot pipeline: post-processing
/// recognised text with the on-device model, and writing notes.
///
/// The shape is `OCRCoordinator`'s, for the same reasons — a bounded drain
/// that re-reads its setting as it goes, a `runID` that stops a cancelled run
/// from clearing a live run's handle, and a deferred resume so a backlog is
/// worked through in bursts rather than in one continuous run. What differs
/// is the width: recognition runs three images at a time, refinement runs
/// ONE. `LanguageModelSession` throws `.concurrentRequests` when a second
/// request arrives while one is in flight, and the system model is a single
/// shared resource in any case — parallelism here would buy contention.
///
/// Everything that touches the model context stays on @MainActor; the model
/// call itself is awaited off it, and clips cross the boundary as
/// `(uuid, text)` because `ClipItem` is not Sendable.
@MainActor
final class NoteCoordinator {
    /// How many clips one batch takes off the refinement queue.
    static let batchSize = 4

    /// Hard bound on one drain, so a 200-screenshot backlog is worked through
    /// in bursts instead of holding the model for an hour.
    static let maxClipsPerDrain = 24

    /// Breather between batches.
    static let batchPause: Duration = .milliseconds(200)

    /// How long a bounded-out drain waits before picking the backlog up.
    ///
    /// Longer than the OCR coordinator's 20 s: refinement is further from
    /// anything the user is waiting on, and a model call costs more than a
    /// recognition pass.
    static let resumeDelay: Duration = .seconds(45)

    /// Below this many characters there is nothing for a model to clean up —
    /// a screenshot of a button label, say. Those clips are marked attempted
    /// with their raw text so the queue drains instead of retrying them.
    static let minimumRefinableCharacters = 24

    nonisolated static var isRefinementEnabled: Bool {
        UserDefaults.standard.bool(forKey: NoteSettingsKeys.refineEnabled)
    }

    nonisolated static var isAutoNoteEnabled: Bool {
        UserDefaults.standard.bool(forKey: NoteSettingsKeys.autoNoteEnabled)
    }

    /// How much text a screenshot needs before it writes itself a note.
    nonisolated static var autoNoteMinimumCharacters: Int {
        UserDefaults.standard.integer(forKey: NoteSettingsKeys.autoNoteMinimumCharacters)
    }

    private let store: ClipStore
    private let refiner: any NoteRefiner
    private var task: Task<Void, Never>?
    private var runID = 0
    /// See `OCRCoordinator.settingsObserver` — same lifetime, same reason for
    /// the `nonisolated(unsafe)`: `deinit` is nonisolated and has to
    /// unregister it.
    private nonisolated(unsafe) var settingsObserver: (any NSObjectProtocol)?
    private var lastKnownEnabled: Bool

    /// The last note failure, for the UI to surface. Cleared by a success.
    ///
    /// Automatic export has nowhere to report to — there is no window open
    /// when a screenshot is taken — so a failure that would otherwise repeat
    /// silently for every screenshot is held here and shown the next time the
    /// user looks.
    private(set) var lastError: NoteError?

    /// - Parameter refiner: injectable so tests can drive the pipeline with a
    ///   deterministic stand-in instead of a model whose availability depends
    ///   on the machine, the OS settings and whether an asset has downloaded.
    init(store: ClipStore, refiner: (any NoteRefiner)? = nil) {
        self.store = store
        self.refiner = refiner ?? FoundationModelsRefiner()
        self.lastKnownEnabled = Self.isRefinementEnabled
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

    // MARK: - Refinement drain

    /// Refine everything recognition has produced but the model has not seen.
    /// Calls while a run is in flight are ignored; the in-flight run picks up
    /// whatever arrives while it loops.
    func processPending() {
        guard task == nil else { return }
        runID &+= 1
        let token = runID
        task = Task { @MainActor [weak self] in
            let backlogRemains = await self?.drain() ?? false
            guard let self, self.runID == token else { return }
            self.task = nil
            if backlogRemains { self.scheduleResume(token: token) }
        }
    }

    /// Cancel any in-flight refinement (app teardown).
    func stop() {
        task?.cancel()
        task = nil
        runID &+= 1
    }

    private func settingDidChange() {
        let enabled = Self.isRefinementEnabled
        guard enabled != lastKnownEnabled else { return }
        lastKnownEnabled = enabled
        if enabled { processPending() }
    }

    private func scheduleResume(token: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.resumeDelay)
            guard let self, self.runID == token else { return }
            self.processPending()
        }
    }

    /// Work through the refinement queue in bounded batches.
    ///
    /// Returns true when it stopped because `maxClipsPerDrain` was reached
    /// and clips are still waiting.
    private func drain() async -> Bool {
        var processed = 0
        while !Task.isCancelled {
            guard Self.isRefinementEnabled else { return false }
            guard processed < Self.maxClipsPerDrain else {
                return !store.pendingRefinement(limit: 1).isEmpty
            }

            let batch: [RefinementJob] = store
                .pendingRefinement(limit: Self.batchSize)
                .compactMap(Self.job(for:))
            guard !batch.isEmpty else { return false }

            for job in batch {
                if Task.isCancelled || !Self.isRefinementEnabled { return false }
                await refine(job)
                processed += 1
            }

            try? await Task.sleep(for: Self.batchPause)
        }
        return false
    }

    /// One clip's worth of refinement work, flattened off the model.
    private struct RefinementJob: Sendable {
        let uuid: UUID
        let input: RefinementInput
        let isScreenshot: Bool
    }

    /// Flatten a queued clip into a job, or nil when it has nothing to refine
    /// (which cannot happen for a clip the query returned — `ocrText` is
    /// non-nil by construction — but keeps this total rather than forced).
    private static func job(for item: ClipItem) -> RefinementJob? {
        guard let raw = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return RefinementJob(
            uuid: item.uuid,
            input: RefinementInput(
                rawText: raw,
                sourceAppName: item.sourceAppName,
                capturedAt: item.createdAt,
                isScreenshot: item.isScreenshot
            ),
            isScreenshot: item.isScreenshot
        )
    }

    private func refine(_ job: RefinementJob) async {
        let raw = job.input.rawText
        // Too short to be worth a model call — but still marked attempted,
        // with the raw text as its own "refinement", so the clip leaves the
        // queue and can still become a note.
        let refined: RefinedNote
        if raw.count < Self.minimumRefinableCharacters {
            refined = await PassthroughRefiner().refine(job.input)
        } else {
            refined = await refiner.refine(job.input)
        }

        store.applyRefinement(
            title: refined.title,
            summary: refined.summary,
            text: refined.cleanedText,
            tags: refined.tags,
            toClipWith: job.uuid
        )

        await autoExportIfWanted(uuid: job.uuid, isScreenshot: job.isScreenshot, textLength: raw.count)
    }

    // MARK: - Notes

    /// Write a note for a freshly refined clip, when the user asked for that
    /// to happen automatically.
    ///
    /// Screenshots only, and only above the configured length: automatic
    /// export exists to capture the screenshots worth keeping, and every
    /// pasteboard image becoming a note is how a vault gets buried.
    private func autoExportIfWanted(uuid: UUID, isScreenshot: Bool, textLength: Int) async {
        guard Self.isAutoNoteEnabled, isScreenshot else { return }
        guard textLength >= Self.autoNoteMinimumCharacters else { return }
        guard let item = store.item(withUUID: uuid), item.notePath == nil else { return }
        _ = await exportNote(for: item)
    }

    /// Write (or rewrite) the note for one clip.
    ///
    /// The entry point for the panel's "Save as Note" action as well as the
    /// automatic path, so a manual export of a clip that has not been refined
    /// yet refines it first rather than writing the raw recognition.
    @discardableResult
    func exportNote(for item: ClipItem) async -> Result<NoteReceipt, NoteError> {
        let uuid = item.uuid
        if !item.refineAttempted, Self.isRefinementEnabled, let job = Self.job(for: item) {
            let refined = await refiner.refine(job.input)
            store.applyRefinement(
                title: refined.title,
                summary: refined.summary,
                text: refined.cleanedText,
                tags: refined.tags,
                toClipWith: uuid
            )
        }

        guard let current = store.item(withUUID: uuid), let draft = Self.draft(for: current) else {
            return finish(.failure(.nothingToWrite))
        }
        let existing = current.notePath

        do {
            let sink = try NoteSinkFactory.make()
            let receipt = try await sink.write(draft, replacing: existing)
            store.applyNote(path: receipt.location, toClipWith: uuid)
            log.notice("Wrote a note for a clip (\(receipt.location, privacy: .private))")
            return finish(.success(receipt))
        } catch let error as NoteError {
            return finish(.failure(error))
        } catch {
            return finish(.failure(.writeFailed(error.localizedDescription)))
        }
    }

    private func finish(_ result: Result<NoteReceipt, NoteError>) -> Result<NoteReceipt, NoteError> {
        switch result {
        case .success:
            lastError = nil
        case .failure(let error):
            lastError = error
            // Split the way the success path above splits: the kind of
            // failure is public because triage needs it, the description is
            // private because several cases interpolate the vault path into
            // it. Both halves are here, so a developer reading the log on
            // their own machine still sees the whole thing.
            log.error("""
                Note export failed: \(error.logReason, privacy: .public) \
                (\(error.localizedDescription, privacy: .private))
                """)
        }
        return result
    }

    /// Flatten a clip into the value the note module works on.
    ///
    /// Returns nil when there is nothing to write down — which is what makes
    /// "Save as Note" fail with one clear sentence instead of producing an
    /// empty note.
    ///
    /// The body prefers the model's cleaned text and falls back to the raw
    /// recognition, then to the clip's own text (a plain text clip can be
    /// noted too). `rawText` is carried only when it differs from the body,
    /// so an unrefined note does not print the same paragraph twice.
    static func draft(for item: ClipItem) -> NoteDraft? {
        let ocr = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refined = item.refinedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let own = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let body = [refined, ocr, own].first { !$0.isEmpty } ?? ""
        guard !body.isEmpty else { return nil }

        let wasRefined = !refined.isEmpty && refined == body
        let rawText: String? = (wasRefined && !ocr.isEmpty && ocr != body) ? ocr : nil

        let title = item.refinedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = RefinementGuard.clampedTitle(
            PassthroughRefiner.heuristicTitle(
                for: RefinementInput(
                    rawText: body,
                    sourceAppName: item.sourceAppName,
                    capturedAt: item.createdAt,
                    isScreenshot: item.isScreenshot
                )
            )
        )

        return NoteDraft(
            clipUUID: item.uuid,
            title: (title?.isEmpty == false ? title! : fallbackTitle),
            summary: item.refinedSummary ?? "",
            tags: item.refinedTags,
            body: body,
            rawText: rawText,
            wasRefined: wasRefined,
            createdAt: item.createdAt,
            sourceAppName: item.sourceAppName,
            sourceFileURL: item.screenshotURL,
            attachmentFileName: nil
        )
    }
}
