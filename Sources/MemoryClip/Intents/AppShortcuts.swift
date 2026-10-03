// @preconcurrency: the AppIntents types this file declares on
// (AppShortcut, the provider's statics) predate Sendable marking — the
// framework's own requirement is a shared immutable array, which a `let`
// already is.
@preconcurrency import AppIntents
import Foundation

/// The phrases Spotlight and Siri answer to, and the Shortcuts gallery
/// tiles. Phrase literals are gathered by the const extractor like the
/// titles; their French spellings resolve through Localizable.strings at
/// match time.
struct MemoryClipShortcuts: AppShortcutsProvider {
    static let appShortcuts: [AppShortcut] = [
        AppShortcut(
            intent: SearchClipsIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Rechercher dans \(.applicationName)",
            ],
            shortTitle: "Search Clips",
            systemImageName: "magnifyingglass"
        ),
        AppShortcut(
            intent: GetLatestClipIntent(),
            phrases: [
                "Latest clip in \(.applicationName)",
                "Dernier clip dans \(.applicationName)",
            ],
            shortTitle: "Get Latest Clip",
            systemImageName: "doc.on.clipboard"
        ),
        AppShortcut(
            intent: CopyClipIntent(),
            phrases: [
                "Copy a clip in \(.applicationName)",
                "Copier un clip dans \(.applicationName)",
            ],
            shortTitle: "Copy Clip",
            systemImageName: "doc.on.doc"
        ),
        AppShortcut(
            intent: OpenMemoryClipIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Ouvrir \(.applicationName)",
            ],
            shortTitle: "Open MemoryClip",
            systemImageName: "rectangle.stack"
        ),
    ]

    static let shortcutTileColor = ShortcutTileColor.navy
}
