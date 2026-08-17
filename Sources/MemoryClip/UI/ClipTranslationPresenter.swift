import Foundation
import SwiftData

/// What the preview pane shows over a clip: the translation, or the fact that
/// one is being made.
///
/// Lifted out of `PreviewView` so the rules can be tested without a window
/// server — in particular the one this file exists to hold: whichever way the
/// work ends, the pane must not be left claiming it is still going.
@MainActor
@Observable
final class ClipTranslationPresenter {
    /// The translation to show, or nil when there is nothing to show.
    private(set) var translation: ClipTranslationResult?
    /// Whether a translation is being made for the clip on screen.
    private(set) var isTranslating = false

    private let runs: ClipTranslationRuns
    /// Which refresh is the current one. A run outlives the refresh that
    /// started it, so its partials and its answer both arrive at a pane that
    /// may have moved on; anything from an earlier generation is dropped
    /// rather than shown over what the pane holds now.
    private var generation = 0

    init(runs: ClipTranslationRuns = .shared) {
        self.runs = runs
    }

    /// Show `item`'s translation, making one first if it has none.
    ///
    /// Safe to be cancelled: the work outlives this call (see
    /// `ClipTranslationRuns`), so a cancelled refresh abandons the answer
    /// rather than the translation.
    func refresh(
        item: ClipItem,
        context: ModelContext?,
        isEnabled: Bool,
        target: Locale.Language
    ) async {
        generation += 1
        let generation = self.generation
        translation = nil
        isTranslating = false
        guard !item.isDeleted else { return }

        let plan = ClipTranslation.plan(
            text: item.clipTranslationSourceText,
            cached: item.cachedClipTranslation,
            isEnabled: isEnabled,
            target: target
        )

        switch plan {
        case .skip:
            return
        case .cached(let cached):
            translation = cached
        case .translate(let request):
            isTranslating = true
            // Whatever happens next — an answer, a failure, or this call
            // being cancelled out from under it — the spinner goes with it.
            // The cancelled path used to return with the flag still set, and
            // a pane that spins for ever reads as a broken app rather than as
            // one that gave up.
            defer { if self.generation == generation { isTranslating = false } }

            // Each chunk goes on screen as it lands, ahead of the answer.
            let result = await runs.translation(for: request, of: item, in: context) { [weak self] partial in
                guard let self, self.generation == generation else { return }
                self.translation = partial
            }
            // The answer belongs to the clip that was on screen when this
            // started; a cancelled refresh is no longer looking at it, and
            // takes whatever it had shown on the way with it.
            guard self.generation == generation else { return }
            guard !Task.isCancelled else {
                translation = nil
                return
            }
            guard let result else { return }
            translation = result
        }
    }
}
