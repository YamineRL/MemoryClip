import Foundation

/// The History pane's reach into the live store.
///
/// The Settings window is built from plain SwiftUI structs handed no
/// services; the export buttons face the same wall, which is why
/// `HistoryExportController` is a singleton `AppDelegate` wires at launch.
/// This is the second door through it, for the three things the pane cannot
/// do from `UserDefaults` alone: counting what a lower limit would delete
/// before the confirmation sheet commits to a number, enforcing the limit
/// once Delete is pressed, and counting the clips behind the Storage
/// readout.
@MainActor
final class HistoryLimitsController {
    static let shared = HistoryLimitsController()

    /// The live store, wired by `AppDelegate` once it exists. Weak for the
    /// reason `HistoryExportController.store` is: the app delegate owns it
    /// for the life of the process, and a strong reference here would be a
    /// second owner.
    weak var store: ClipStore?

    private init() {}

    /// How many unpinned clips `limit` would delete if applied now: the
    /// number the confirmation sheet shows before applying one. It is
    /// `ClipStore.deletionCount(under:)`, the same function `enforceCap` /
    /// `enforceRetention` count with, so the number shown is the number
    /// that goes.
    func deletionCount(under limit: ClipStore.HistoryLimit) -> Int {
        store?.deletionCount(under: limit) ?? 0
    }

    /// Enforce the limit the pane just wrote, rather than leaving it to the
    /// next maintenance pass: the user confirmed a delete, so the clips
    /// should be gone now, not in fifteen minutes.
    func enforce(_ limit: ClipStore.HistoryLimit) {
        switch limit {
        case .cap:
            store?.enforceCap()
        case .retentionDays:
            store?.enforceRetention()
        }
    }

    /// The clip count half of the Storage readout ("1,203 clips · 84 MB").
    func clipCount() -> Int {
        store?.clipCount() ?? 0
    }
}
