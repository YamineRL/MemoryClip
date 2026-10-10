import Foundation

/// Turns a clip into a calendar event: reads the appointment out of its text,
/// hands it to a sink, and records on the clip that it now has one.
///
/// The shape is `NoteCoordinator`'s export path — one entry point returning a
/// `Result` whose failure is a sentence the UI can show, a `finish(_:)` that
/// keeps the last failure for a caller that had nowhere to report to, and
/// settings re-read at every use rather than cached.
///
/// Everything that touches the model context stays on `@MainActor`; the clip
/// crosses to the sink as a `DetectedEvent`, which is a value, because
/// `ClipItem` is not Sendable.
@MainActor
final class CalendarCoordinator {
    /// Whether an appointment-shaped clip offers its event to the user.
    /// Read here rather than cached, so a change in Settings takes effect
    /// on the next clip and not on the next launch.
    ///
    /// "Offer", not "create": the setting used to let an event be written
    /// unprompted, and that turned out to mean junk detections landing in a
    /// calendar the user never saw a proposal for. Nothing is created on
    /// this path any more — the banner's Add button is the only yes.
    nonisolated static var isOfferEnabled: Bool {
        UserDefaults.standard.bool(forKey: CalendarSettingsKeys.autoCreate)
    }

    /// Whether an event created through the offer's Add announces itself —
    /// the second banner, the one Undo lives on.
    nonisolated static var notifiesOnAutoCreate: Bool {
        UserDefaults.standard.bool(forKey: CalendarSettingsKeys.notifyOnAutoCreate)
    }

    /// How long an event runs when the text named no end.
    ///
    /// Falls back to the detector's own default for a missing or nonsensical
    /// setting: `integer(forKey:)` reads an unregistered key as 0, and a
    /// zero-length event is one the user cannot see in a week view.
    nonisolated static var defaultDuration: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: CalendarSettingsKeys.eventDurationMinutes)
        guard minutes > 0 else { return EventDetector.defaultDuration }
        return TimeInterval(minutes) * 60
    }

    private let store: ClipStore
    private let sink: any EventSink

    /// One successful creation, bound to the operation that made it. An
    /// operation identifier is minted per `addEvent`, carried into the sink
    /// and onto the notification, and is the ONLY handle undo has: write-only
    /// calendar access means the event can never be looked up again, so undo
    /// must say which creation it is retracting rather than "the last one".
    private struct EventOperation {
        let operationID: UUID
        let clipUUID: UUID
    }

    /// The operations this run completed, in creation order — "undo the
    /// last" pops the tail. Entries live for the process only, like the
    /// events they name.
    private var operations: [EventOperation] = []

    /// Clip uuids with an `addEvent` currently in flight. Actor isolation
    /// does NOT serialise this: `sink.save` awaits, and anything calling in
    /// during that suspension would pass the `calendarEventID == nil` check
    /// on the same clip — a manual click racing the automatic path is how a
    /// duplicate event lands. The set closes that window.
    private var inFlight: Set<UUID> = []

    /// The last calendar failure, for the UI to surface. Cleared by a success.
    ///
    /// Automatic creation has nowhere to report to — nothing is on screen when
    /// a clip is captured — so a failure that would otherwise repeat silently
    /// is held here and shown the next time the user looks.
    private(set) var lastError: CalendarError?

    /// - Parameter sink: injectable so tests can drive the coordinator without
    ///   EventKit, which on a build machine has no calendar, no default
    ///   calendar for new events, and no way to answer a permission prompt.
    init(store: ClipStore, sink: (any EventSink)? = nil) {
        self.store = store
        self.sink = sink ?? EventKitSink()
    }

    // MARK: - Detection

    /// The appointment this clip holds, if it holds one.
    ///
    /// The text is chosen the way `NoteCoordinator.draft(for:)` chooses a
    /// note's body — the model's cleaned-up text, then the raw recognition,
    /// then the clip's own text — so what the user reads in the preview is
    /// what gets scanned. The clip's model-written title is handed to the
    /// detector as the fallback, since a screenshot of an invitation is often
    /// titled better by the model than by its own first surviving line.
    ///
    /// `automatic` reverses that preference: an event written WITHOUT the
    /// user looking must stand on evidence the clip actually carries — its
    /// own text or the raw OCR — never on the model's rewrite of it. Refined
    /// text is a convenience layer for presentation; a hallucinated or
    /// "helpfully" reordered date must not reach the calendar on its own.
    func event(for item: ClipItem, automatic: Bool = false) -> DetectedEvent? {
        let refined = item.refinedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ocr = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let own = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let candidates = automatic ? [own, ocr, refined] : [refined, ocr, own]
        let text = candidates.first { !$0.isEmpty } ?? ""
        guard !text.isEmpty else { return nil }

        let title = item.refinedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return EventDetector.detect(
            text,
            fallbackTitle: title.isEmpty ? loc("Event") : title,
            defaultDuration: Self.defaultDuration
        )
    }

    // MARK: - Creating

    /// Create the calendar event for one clip.
    ///
    /// The entry point for the panel's "Add to Calendar" action AND the
    /// automatic path — the deduplication and revision guards below are what
    /// make a shared entry point safe. Failure is always a `CalendarError`,
    /// so the caller has one sentence to show and nothing to interpret.
    ///
    /// - Parameters:
    ///   - automatic: detect from the clip's own evidence rather than the
    ///     model's rewrite — see `event(for:automatic:)`.
    ///   - allowRepeat: create even though `calendarEventID` is already set.
    ///     Off by default: a second event for one appointment is a duplicate
    ///     in the user's calendar, and the only way to want it is to mean it.
    @discardableResult
    func addEvent(
        for item: ClipItem,
        automatic: Bool = false,
        allowRepeat: Bool = false
    ) async -> Result<EventReceipt, CalendarError> {
        let uuid = item.uuid

        guard allowRepeat || item.calendarEventID == nil else {
            return finish(.failure(.alreadyScheduled))
        }
        // Two creations for one clip cannot overlap: the check-then-await in
        // `sink.save` is exactly where a second caller slips in. A concurrent
        // request is declined, not queued — the first one's event covers it.
        guard inFlight.insert(uuid).inserted else {
            return finish(.failure(.alreadyInFlight))
        }
        defer { inFlight.remove(uuid) }

        let revision = item.contentRevision
        guard let detected = event(for: item, automatic: automatic) else {
            return finish(.failure(.nothingToSchedule))
        }
        let operation = UUID()

        do {
            let receipt = try await sink.save(detected, operation: operation)
            // The event exists. Recording it is the step that can still
            // fail: the clip may have been edited, sealed or deleted while
            // the save awaited — in which case the event describes content
            // that is gone, and the honest move is to un-create it rather
            // than leave an orphaned appointment.
            guard store.applyCalendarEvent(
                receipt.eventIdentifier,
                toClipWith: uuid,
                revision: revision
            ) else {
                _ = try? await sink.removeSaved(operation)
                return finish(.failure(.clipChangedDuringSave))
            }
            operations.append(EventOperation(operationID: operation, clipUUID: uuid))
            log.notice("Added a clip to the calendar (\(receipt.calendarTitle, privacy: .private))")
            // A manual add is the user's own gesture and always announces
            // itself: the banner is where Open-in-Calendar and Undo live,
            // and "added" must never be a claim the user cannot check.
            if !automatic {
                await EventNotifier.post(
                    eventTitle: detected.title,
                    start: receipt.start,
                    isAllDay: detected.isAllDay,
                    calendarTitle: receipt.calendarTitle,
                    location: detected.location,
                    operation: operation
                )
            }
            return finish(.success(receipt))
        } catch let error as CalendarError {
            return finish(.failure(error))
        } catch {
            return finish(.failure(.saveFailed(error.localizedDescription)))
        }
    }

    // MARK: - Offering an event instead of writing one

    /// Offer this clip's appointment to the user, when the feature is on and
    /// the clip is corroborated enough to be worth asking about.
    ///
    /// Returns the detected event when an offer was posted, nil for every
    /// clip it declines — nearly all of them. Nothing is created here:
    /// detection is cheap and innocent, writing is what needed consent.
    /// The banner carries Add / Edit / Not Now, and only those buttons can
    /// turn the offer into an event.
    @discardableResult
    func offerIfWanted(for item: ClipItem) async -> DetectedEvent? {
        // Off unless asked for. Read first because it is the cheapest guard
        // here, and because it being off is the common case — it makes the
        // whole feature cost one `UserDefaults` read per captured clip.
        guard Self.isOfferEnabled else { return nil }

        // A clip that already has an event is a clip this has already seen,
        // or one the user added by hand. Either way a second event for the
        // same appointment is a duplicate in their calendar, which is exactly
        // the kind of mess that gets a feature switched off.
        guard item.calendarEventID == nil else { return nil }

        // Nothing that reads as an appointment: no date at all, or no text.
        // The offer scans the clip's own evidence — its text, or the raw
        // recognition — never the model's rewrite, which is a convenience
        // layer over the record, not the record.
        guard let detected = event(for: item, automatic: true) else { return nil }

        // The line between "there is a date in here" and "this is an
        // appointment". `isStrongSignal` wants a clock time and either a
        // meeting link or an address *near the date*; see
        // `DetectedEvent.isStrongSignal` for why a bare date must never
        // become an event on its own, and `EventDetector` for why the
        // corroboration must live next to it. The manual button has no such
        // requirement, and should not.
        guard detected.isStrongSignal else { return nil }

        // An offer whose only save-answer leads to a certain failure is a
        // dead button: a refused grant means nothing can be added, so there
        // is nothing worth asking. A never-asked state still gets the offer —
        // the Add button is a user press, and the first TCC prompt is
        // allowed to belong to it.
        guard sink.canReachCalendar else { return nil }

        await EventNotifier.postOffer(
            eventTitle: detected.title,
            start: detected.start,
            isAllDay: detected.isAllDay,
            location: detected.location,
            clipUUID: item.uuid
        )
        return detected
    }

    /// Offer a batch of clips. Returns the uuids an offer was posted for —
    /// the observable half of a method whose output is a notification.
    ///
    /// The screenshot half of the wiring: a screenshot has no text when it is
    /// captured, so its appointment only exists once recognition has run, and
    /// `OCRCoordinator` reports the clips a batch produced text for. Bounded
    /// by that batch — this never queries history and never revisits a clip it
    /// has already answered for.
    @discardableResult
    func offerIfWanted(forClipsWith uuids: [UUID]) async -> [UUID] {
        guard Self.isOfferEnabled, !uuids.isEmpty else { return [] }
        var offered: [UUID] = []
        for item in store.items(withUUIDs: uuids) {
            if await offerIfWanted(for: item) != nil {
                offered.append(item.uuid)
            }
        }
        return offered
    }

    // MARK: - Answering an offer

    /// The appointment detection would find for `uuid`'s clip, or nil when
    /// the clip is gone or holds none.
    ///
    /// Used by the offer's Edit button, which needs the `DetectedEvent` —
    /// to hand to a calendar app as an .ics — rather than a save.
    func detectedEvent(forClipWith uuid: UUID) -> DetectedEvent? {
        guard let item = store.item(withUUID: uuid) else { return nil }
        return event(for: item, automatic: true)
    }

    /// Create the event an offer's Add button was pressed for.
    ///
    /// The clip is re-fetched by uuid — the banner may outlive the clip, and
    /// this is a save, so it goes through `addEvent`'s dedupe, in-flight and
    /// revision machinery like every other creation. A clip that vanished
    /// behind its banner answers `.nothingToSchedule`.
    ///
    /// A success announces itself through the created-event banner when the
    /// setting wants it: that banner is where Undo lives.
    @discardableResult
    func acceptOfferedEvent(forClipWith uuid: UUID) async -> Result<EventReceipt, CalendarError> {
        log.notice("Offer accepted for clip \(uuid.uuidString, privacy: .private)")
        guard let item = store.item(withUUID: uuid) else {
            return finish(.failure(.nothingToSchedule))
        }
        let detected = event(for: item, automatic: true)
        // `addEvent` already records a failure through `finish` — its result
        // is passed through untouched rather than double-logged.
        let result = await addEvent(for: item, automatic: true)
        guard case .success(let receipt) = result else { return result }
        EventNotifier.dismissOffer(forClipWith: uuid)
        if Self.notifiesOnAutoCreate, let operation = operationID(forClipWith: uuid) {
            await EventNotifier.post(
                eventTitle: detected?.title ?? loc("Event"),
                start: receipt.start,
                isAllDay: detected?.isAllDay ?? false,
                calendarTitle: receipt.calendarTitle,
                location: detected?.location,
                operation: operation
            )
        }
        return finish(.success(receipt))
    }

    /// The operation a successful `addEvent` recorded for `uuid` — the
    /// identifier a notification's `userInfo` carries back to `undoEvent`.
    /// The notification delegate and tests are its readers.
    func operationID(forClipWith uuid: UUID) -> UUID? {
        operations.last(where: { $0.clipUUID == uuid })?.operationID
    }

    /// Remove the event a specific creation made and forget it on the clip.
    ///
    /// The honest failure modes are reported, not smoothed over: an
    /// operation this run does not know — the notification outlived the app,
    /// or the event was already undone — is `.undoUnavailable`, never a
    /// claimed success.
    @discardableResult
    func undoEvent(_ operationID: UUID) async -> Result<Void, CalendarError> {
        guard let index = operations.firstIndex(where: { $0.operationID == operationID }) else {
            return finish(.failure(.undoUnavailable))
        }
        let operation = operations[index]

        do {
            guard try await sink.removeSaved(operationID) else {
                return finish(.failure(.undoUnavailable))
            }
        } catch let error as CalendarError {
            return finish(.failure(error))
        } catch {
            return finish(.failure(.removeFailed(error.localizedDescription)))
        }

        operations.remove(at: index)
        store.applyCalendarEvent(nil, toClipWith: operation.clipUUID)
        return finish(.success(()))
    }

    /// Remove the event created last and forget it on the clip.
    ///
    /// Fails `.undoUnavailable` when this run created nothing that is still
    /// standing — the sink can only reach events it still holds, so past
    /// that point there is nothing to undo, and saying so beats silence.
    @discardableResult
    func undoLastEvent() async -> Result<Void, CalendarError> {
        guard let last = operations.last else {
            return finish(.failure(.undoUnavailable))
        }
        return await undoEvent(last.operationID)
    }

    /// Record the outcome: a success clears the held failure, a failure keeps
    /// it for whoever looks next.
    ///
    /// Logged with the same split `NoteCoordinator` uses — the kind of failure
    /// public because triage needs it, the description private because two
    /// cases interpolate an EventKit message that can name a calendar. Both
    /// halves are here, so a developer reading the log on their own machine
    /// still sees the whole thing.
    private func finish<Value>(_ result: Result<Value, CalendarError>) -> Result<Value, CalendarError> {
        switch result {
        case .success:
            lastError = nil
        case .failure(let error):
            lastError = error
            log.error("""
                Calendar event failed: \(error.logReason, privacy: .public) \
                (\(error.localizedDescription, privacy: .private))
                """)
        }
        return result
    }
}
