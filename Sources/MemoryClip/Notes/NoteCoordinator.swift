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

    nonisolated static var isTranslationEnabled: Bool {
        UserDefaults.standard.bool(forKey: NoteSettingsKeys.translateEnabled)
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
    private let translator: any NoteTranslator
    private var task: Task<Void, Never>?
    private var runID = 0

    /// A `processPending()` that arrived while a drain was already running.
    ///
    /// The drain re-queries as it loops, so a kick during one is *usually*
    /// picked up for free. The exception is the instant between its last
    /// query coming back empty and the handle being cleared: recognition
    /// finishing in that window would have its kick dropped, and the clip
    /// would sit unrefined until the next launch. Noting the request and
    /// re-arming at the end closes that window — the same shape
    /// `ScreenshotWatcher` uses for `rescanRequested`.
    private var rerunRequested = false
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

    /// - Parameters:
    ///   - refiner: injectable so tests can drive the pipeline with a
    ///     deterministic stand-in instead of a model whose availability
    ///     depends on the machine, the OS settings and whether an asset has
    ///     downloaded.
    ///   - translator: injectable for the same reason, and with more force —
    ///     which language pairs are installed varies from Mac to Mac, so a
    ///     test that used the real one would pass or fail on the contents of
    ///     the machine's asset cache.
    init(store: ClipStore, refiner: (any NoteRefiner)? = nil, translator: (any NoteTranslator)? = nil) {
        self.store = store
        self.refiner = refiner ?? FoundationModelsRefiner()
        self.translator = translator ?? AppleTranslator()
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
        guard task == nil else {
            rerunRequested = true
            return
        }
        rerunRequested = false
        runID &+= 1
        let token = runID
        task = Task { @MainActor [weak self] in
            let backlogRemains = await self?.drain() ?? false
            guard let self, self.runID == token else { return }
            self.task = nil
            if backlogRemains {
                self.scheduleResume(token: token)
            } else if self.rerunRequested {
                self.rerunRequested = false
                self.processPending()
            }
        }
    }

    /// Cancel any in-flight refinement (app teardown).
    func stop() {
        task?.cancel()
        task = nil
        rerunRequested = false
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

    /// What the two model stages produced for one clip: the note fields, and
    /// the English rendering when the text was not in English to begin with.
    private struct ProcessedClip: Sendable {
        let refined: RefinedNote
        let translation: TranslatedText?
        /// The refined text to STORE. nil for a translated clip: its note
        /// body stays the original language, and what the model cleaned up
        /// was the translation, which is carried in `translation` instead.
        /// Writing it to `refinedText` would replace the user's own text with
        /// English in the panel, in search, and in the note.
        let refinedTextToStore: String?
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
                isScreenshot: item.isScreenshot,
                language: LanguageDetector.dominantLanguage(of: raw)
            ),
            isScreenshot: item.isScreenshot
        )
    }

    private func refine(_ job: RefinementJob) async {
        let processed = await process(job)

        store.applyRefinement(
            title: processed.refined.title,
            summary: processed.refined.summary,
            text: processed.refinedTextToStore,
            tags: processed.refined.tags,
            language: Self.recordedLanguage(for: job.input),
            translation: processed.translation,
            toClipWith: job.uuid
        )

        await autoExportIfWanted(
            uuid: job.uuid,
            isScreenshot: job.isScreenshot,
            textLength: job.input.rawText.count
        )
    }

    /// Translate if the text is not in English, then refine — the pair of
    /// model stages, in the one order that works.
    ///
    /// Translation runs FIRST because refinement depends on its result. The
    /// on-device model reads 23 locales; Vision now recognises 30. For a
    /// clip in the gap — Arabic, Russian, Thai — the model cannot clean the
    /// original text, cannot title it and cannot tag it, so refining the
    /// original would produce a note whose every field was a fallback. Given
    /// the translation it can do all three, and the note ends up with an
    /// English title, an English summary and English tags over text that is
    /// still in the language it was captured in.
    ///
    /// The original is never overwritten. `refinedTextToStore` is nil
    /// whenever a translation was made, so `ClipItem.refinedText` stays empty
    /// and the note's body is the recognised text — the translation sits
    /// beneath it as its own section.
    private func process(_ job: RefinementJob) async -> ProcessedClip {
        let raw = job.input.rawText
        // Too short to be worth either model — but still marked attempted,
        // with the raw text as its own "refinement", so the clip leaves the
        // queue and can still become a note.
        guard raw.count >= Self.minimumRefinableCharacters else {
            return ProcessedClip(
                refined: await PassthroughRefiner().refine(job.input),
                translation: nil,
                refinedTextToStore: raw
            )
        }

        let translation = await translateIfWanted(job.input)

        guard let translation else {
            let refined = await refiner.refine(job.input)
            return ProcessedClip(refined: refined, translation: nil, refinedTextToStore: refined.cleanedText)
        }

        // Refine the TRANSLATION. Its language is English by construction, so
        // this is the one path where the model is guaranteed to be able to
        // read what it is given.
        var translated = job.input
        translated.rawText = translation.text
        translated.language = NoteTranslation.target
        let refined = await refiner.refine(translated)

        return ProcessedClip(
            refined: refined,
            // The model's cleanup of the translation is what the note shows,
            // so it replaces the raw translation — unlike the original text,
            // which the raw OCR on the clip still records.
            translation: TranslatedText(
                text: refined.cleanedText,
                sourceLanguage: translation.sourceLanguage
            ),
            refinedTextToStore: nil
        )
    }

    /// The language identifier to store on the clip: the detected one when
    /// the text was not English, nil otherwise.
    ///
    /// Stored even when translation did not happen — off, unsupported, or the
    /// assets are not downloaded — because "this note is in Arabic" is true
    /// and useful either way, and it is what tells the user which of their
    /// notes a later download would have helped.
    private static func recordedLanguage(for input: RefinementInput) -> String? {
        guard let language = input.language, LanguageDetector.needsTranslation(language) else { return nil }
        return LanguageDetector.identifier(for: language)
    }

    /// The English rendering of this clip, when it needs one and the Mac can
    /// make it.
    ///
    /// Returns nil for the ordinary case — English text — without touching
    /// the translator at all, so the common path costs one language
    /// identification and nothing else.
    private func translateIfWanted(_ input: RefinementInput) async -> TranslatedText? {
        guard Self.isTranslationEnabled else { return nil }
        guard let language = input.language, LanguageDetector.needsTranslation(language) else { return nil }
        return await translator.translate(input.rawText, from: language)
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
            let processed = await process(job)
            store.applyRefinement(
                title: processed.refined.title,
                summary: processed.refined.summary,
                text: processed.refinedTextToStore,
                tags: processed.refined.tags,
                language: Self.recordedLanguage(for: job.input),
                translation: processed.translation,
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
        // Built from the translation when there is one: a heuristic title is
        // the text's own first line, and a file named from a line of Arabic
        // is a file the user cannot find in an English-sorted vault. When the
        // model titled the clip this is unused anyway.
        let titleSource = item.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? item.translatedText!
            : body
        let fallbackTitle = RefinementGuard.clampedTitle(
            PassthroughRefiner.heuristicTitle(
                for: RefinementInput(
                    rawText: titleSource,
                    sourceAppName: item.sourceAppName,
                    capturedAt: item.createdAt,
                    isScreenshot: item.isScreenshot
                )
            )
        )

        let translation = item.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)

        return NoteDraft(
            clipUUID: item.uuid,
            title: (title?.isEmpty == false ? title! : fallbackTitle),
            summary: item.refinedSummary ?? "",
            tags: item.refinedTags,
            body: body,
            rawText: rawText,
            // Dropped when it is the body: nothing is gained by printing the
            // same paragraph twice under a heading that says it is a
            // translation of itself.
            translation: (translation?.isEmpty == false && translation != body) ? translation : nil,
            sourceLanguage: item.sourceLanguage,
            wasRefined: wasRefined,
            createdAt: item.createdAt,
            sourceAppName: item.sourceAppName,
            sourceFileURL: item.screenshotURL,
            attachmentFileName: nil
        )
    }
}
