import Foundation
import SwiftData

/// The translations that are actually running, held outside any view.
///
/// # Why the work cannot belong to the pane
///
/// It used to: `PreviewView` ran it straight from `.task(id:)`, and a SwiftUI
/// task is cancelled when the view it is attached to goes away. That made an
/// on-device translation as short-lived as a glance, and this panel is built
/// to disappear — `PanelController.appDidResignActive` orders it out and bumps
/// the focus token, which clears the preview, the moment MemoryClip stops
/// being the frontmost app. Clicking back to the window the text was copied
/// from is therefore enough to kill the translation of it, which is exactly
/// what people do while waiting for one.
///
/// Measured on this Mac (macOS 26.5, an installed zh→en pair): 55 characters
/// took 3.2 seconds with the panel left alone, and every run that lost the
/// user's attention inside that window ended in `CancellationError` and an
/// empty pane instead.
///
/// So a translation belongs to the CLIP. The runs here are unstructured tasks
/// — cancellation does not reach them from whoever happens to be waiting —
/// and each writes its result onto the clip before it finishes, so a pane
/// that comes back finds it cached and shows it at once whether or not
/// anyone was watching when it landed.
///
/// # One run per clip
///
/// Keyed by clip, so two panes (or the same pane re-opened) join the run that
/// is already going rather than starting a second copy of it. A request that
/// no longer matches the one in flight supersedes it: that means the clip's
/// text changed underneath — recognition finished, or the model cleaned it up
/// — and what the old run is translating is no longer what the pane would
/// show.
@MainActor
final class ClipTranslationRuns {
    static let shared = ClipTranslationRuns()

    private struct Run {
        let request: ClipTranslationRequest
        let task: Task<ClipTranslationResult?, Never>
        /// Everyone waiting to be shown the run's partial translations. A pane
        /// that joins a run already going is added here and starts seeing them
        /// from the next chunk on.
        var observers: [(ClipTranslationResult) -> Void] = []
    }

    private var runs: [UUID: Run] = [:]
    private let service: ClipTranslationService

    /// - Parameter service: injectable so tests never reach the real engine.
    init(service: ClipTranslationService = ClipTranslationService()) {
        self.service = service
    }

    /// The translation of `request`, running it if nobody else already is.
    ///
    /// Waiting on this is safe from anywhere: a caller that is cancelled
    /// while waiting simply stops caring about the answer, and the answer is
    /// still made and still cached.
    /// - Parameter onProgress: given each partial translation as it lands. The
    ///   finished one is returned rather than passed here.
    func translation(
        for request: ClipTranslationRequest,
        of item: ClipItem,
        in context: ModelContext?,
        onProgress: @escaping (ClipTranslationResult) -> Void = { _ in }
    ) async -> ClipTranslationResult? {
        let uuid = item.uuid

        if let existing = runs[uuid] {
            if existing.request == request {
                runs[uuid]?.observers.append(onProgress)
                return await existing.task.value
            }
            existing.task.cancel()
        }

        let task = Task { @MainActor [service] in
            let result = await service.translation(for: request) { partial in
                self.publish(partial, for: uuid, of: request)
            }
            // Cached here rather than by the caller, because by the time this
            // lands the caller is often gone — which is the whole point.
            if let result { Self.cache(result, on: item, in: context) }
            runs[uuid] = nil
            return result
        }
        runs[uuid] = Run(request: request, task: task, observers: [onProgress])

        return await task.value
    }

    /// Hand a partial translation to whoever is watching this clip.
    ///
    /// Dropped when the run it came from is no longer the clip's: a superseded
    /// run is translating text the pane would not show.
    private func publish(
        _ partial: ClipTranslationResult,
        for uuid: UUID,
        of request: ClipTranslationRequest
    ) {
        guard let run = runs[uuid], run.request == request else { return }
        for observer in run.observers { observer(partial) }
    }

    /// Keep the translation on the clip, so the next look at it is free.
    ///
    /// The deleted check is the same one the panel makes before handing a
    /// clip to the pane, and it is best-effort for the same reason: SwiftData
    /// reports a deletion that has not been saved yet inconsistently, so this
    /// catches the clear cases and a translation that lands on a row about to
    /// go away goes away with it.
    private static func cache(
        _ result: ClipTranslationResult,
        on item: ClipItem,
        in context: ModelContext?
    ) {
        guard !item.isDeleted else { return }
        item.cachedClipTranslation = result
        do {
            try context?.save()
        } catch {
            // The translation is made either way; all that is lost is the
            // saving of it, which costs one re-translation next time.
            log.error("Caching a clip translation failed: \(error.localizedDescription)")
        }
    }
}
