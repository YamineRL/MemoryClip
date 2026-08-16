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
            defer { isTranslating = false }

            let result = await runs.translation(for: request, of: item, in: context)
            // The answer belongs to the clip that was on screen when this
            // started; a cancelled refresh is no longer looking at it.
            guard !Task.isCancelled, let result else { return }
            translation = result
        }
    }
}
