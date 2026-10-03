import AppIntents
import Foundation

/// "Open MemoryClip": brings the panel forward, optionally with the
/// search already filled in.
///
/// The one intent the app-lock gate does not precede — opening the panel
/// applies the lock itself, the way the hotkey does.
struct OpenMemoryClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Open MemoryClip"
    static let description = IntentDescription(
        "Shows the MemoryClip panel, optionally pre-filling its search."
    )

    static let openAppWhenRun = true

    static var parameterSummary: some ParameterSummary {
        Summary("Open MemoryClip") {
            \.$query
        }
    }

    @Parameter(title: "Query")
    var query: String?

    func perform() async throws -> some IntentResult {
        await AppDelegate.openPanelFromIntent(query: query)
        return .result()
    }
}
