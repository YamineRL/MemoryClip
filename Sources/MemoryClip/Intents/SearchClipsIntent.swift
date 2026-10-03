import AppIntents
import Foundation

/// "Search Clips": the panel's own matching, returned as ClipEntity rows
/// a Shortcut can pick from or loop over.
///
/// Literal titles for the same reason as the other intents — see
/// GetLatestClipIntent's note.
struct SearchClipsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Clips"
    static let description = IntentDescription(
        "Finds clips whose text, title, file name or source app match a query."
    )

    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Search clips for \(\.$query)") {
            \.$limit
        }
    }

    @Parameter(title: "Query")
    var query: String

    /// Clamped into 1...100 by the service; over-large values get the best
    /// page rather than an error.
    @Parameter(title: "Limit", default: 10)
    var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[ClipEntity]> {
        guard let service = await ClipIntentService.live() else {
            throw ClipIntentService.IntentError.storeUnavailable
        }
        let clips = try await service.search(query: query, limit: limit)
        return .result(value: clips)
    }
}
