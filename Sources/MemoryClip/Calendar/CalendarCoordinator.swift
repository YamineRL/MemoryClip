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
    /// Whether an appointment-shaped clip creates its event without being
    /// asked. Read here rather than cached, so a change in Settings takes
    /// effect on the next clip and not on the next launch.
    nonisolated static var isAutoCreateEnabled: Bool {
        UserDefaults.standard.bool(forKey: CalendarSettingsKeys.autoCreate)
    }

    /// Whether an automatically created event announces itself.
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

    /// The clip the last successful `addEvent` was for, so undo knows whose
    /// identifier to clear. Held rather than looked up because the sink's own
    /// undo is "the last one I made" — see `EventSink.removeLastSaved` — and
    /// these two have to mean the same event.
    private var lastEventClipUUID: UUID?

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
    func event(for item: ClipItem) -> DetectedEvent? {
        let refined = item.refinedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ocr = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let own = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let text = [refined, ocr, own].first { !$0.isEmpty } ?? ""
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
    /// The entry point for the panel's "Add to Calendar" action. Failure is
    /// always a `CalendarError`, so the caller has one sentence to show and
    /// nothing to interpret.
    @discardableResult
    func addEvent(for item: ClipItem) async -> Result<EventReceipt, CalendarError> {
        let uuid = item.uuid
        guard let detected = event(for: item) else {
            return finish(.failure(.nothingToSchedule))
        }

        do {
            let receipt = try await sink.save(detected)
            store.applyCalendarEvent(receipt.eventIdentifier, toClipWith: uuid)
            lastEventClipUUID = uuid
            log.notice("Added a clip to the calendar (\(receipt.calendarTitle, privacy: .private))")
            return finish(.success(receipt))
        } catch let error as CalendarError {
            return finish(.failure(error))
        } catch {
            return finish(.failure(.saveFailed(error.localizedDescription)))
        }
    }

    /// Remove the event created last and forget it on the clip.
    ///
    /// Succeeds with nothing done when no event has been created in this run:
    /// the sink can only reach an event it still holds, so past that point
    /// there is nothing to undo rather than something that went wrong.
    @discardableResult
    func undoLastEvent() async -> Result<Void, CalendarError> {
        do {
            try await sink.removeLastSaved()
        } catch let error as CalendarError {
            return finish(.failure(error))
        } catch {
            return finish(.failure(.removeFailed(error.localizedDescription)))
        }

        if let uuid = lastEventClipUUID {
            store.applyCalendarEvent(nil, toClipWith: uuid)
            lastEventClipUUID = nil
        }
        return finish(.success(()))
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
