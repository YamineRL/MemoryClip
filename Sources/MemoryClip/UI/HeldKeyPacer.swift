import Foundation

/// What the panel should do about one movement keystroke.
enum HeldKeyStep: Equatable {
    /// The keystroke arrived too soon after the last accepted one and is
    /// dropped: the selection does not move and nothing else happens.
    case drop
    /// Move the selection and bring the preview pane with it right away.
    case move
    /// Move the selection now, but let the preview pane settle: more steps
    /// are expected, and only the clip the user stops on is worth loading.
    case moveSettlingPreview
}

/// Paces the movement keys while one is held down.
///
/// macOS turns a held arrow into a stream of auto-repeat events at whatever
/// rate the user chose in Keyboard settings, and at the fast end of that
/// slider the panel would fly through a few hundred clips before a finger can
/// come off the key. This is the governor: a pure decision function over the
/// time of each keystroke, so the panel can honour repeats without handing
/// the pace over to a system preference.
///
/// It also decides when the preview pane may follow. The preview loads a
/// full-resolution image and starts an on-device translation for the clip it
/// is showing, which is work worth doing once for the clip the user lands on
/// and worth doing never for the forty they skim past on the way.
struct HeldKeyPacer {
    /// The floor on how often an auto-repeat may move the selection.
    ///
    /// 0.12 s is about eight steps a second. The fastest system key-repeat
    /// setting is roughly four times that, which reads as a blur and
    /// overshoots by a dozen clips before the key comes up; a quarter of a
    /// second, on the other hand, feels like the panel is refusing to move.
    /// Eight a second is fast enough to cross a screenful of cards in a
    /// beat, slow enough that each card is on screen long enough to be
    /// recognised, and close enough to human reaction time (~0.2 s) that
    /// stopping costs one or two cards rather than a page.
    static let minimumRepeatInterval: TimeInterval = 0.12

    /// How long the movement keys must be quiet before the preview pane is
    /// allowed to load the selected clip.
    ///
    /// Deliberately longer than `minimumRepeatInterval`, so that a held key
    /// can never open a window between two of its own repeats: the preview
    /// stays on the clip the run started from and jumps once, to the clip it
    /// ended on. Short enough that a deliberate single press still feels
    /// like the pane is keeping up.
    static let previewSettleDelay: TimeInterval = 0.25

    /// When the last accepted step happened, on the caller's clock. Dropped
    /// repeats deliberately do not update it: the interval is measured
    /// between steps the user actually saw, so a fast repeat rate cannot
    /// starve movement by resetting the window on every event.
    private var lastStep: TimeInterval?

    init(lastStep: TimeInterval? = nil) {
        self.lastStep = lastStep
    }

    /// Decide what a movement keystroke should do.
    ///
    /// - Parameters:
    ///   - isRepeat: Whether this is a macOS auto-repeat rather than the
    ///     user's own press. Real presses are never throttled — the first
    ///     step of a hold has to feel instant, and a user tapping the key
    ///     quickly is asking for exactly the pace they are typing.
    ///   - now: The current time, in seconds, on any monotonic clock. Passed
    ///     in rather than read here so tests can drive it.
    mutating func step(isRepeat: Bool, now: TimeInterval) -> HeldKeyStep {
        let sinceLast = lastStep.map { now - $0 }
        if isRepeat, let sinceLast, sinceLast < Self.minimumRepeatInterval {
            return .drop
        }
        lastStep = now
        // A step that follows hard on the heels of another is part of a run,
        // whether the run is auto-repeat or a fast hand. Either way the clip
        // under the selection right now is one being passed over.
        guard let sinceLast, sinceLast < Self.previewSettleDelay else { return .move }
        return .moveSettlingPreview
    }

    /// Forget the last step, so the next one counts as a fresh press.
    mutating func reset() {
        lastStep = nil
    }
}
