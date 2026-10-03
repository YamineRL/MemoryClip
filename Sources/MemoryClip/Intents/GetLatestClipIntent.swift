import AppIntents
import Foundation

/// "Get Latest Clip": the newest clip, returned as a Shortcuts file —
/// the real file for a file clip, the image bytes for an image, and a
/// text file everywhere else (Shortcuts reads it back as Text).
///
/// Titles, descriptions and summaries stay literals rather than lookups:
/// the metadata extractor const-folds them at compile time, so a runtime
/// catalogue call would land the action in Shortcuts nameless. Their
/// translations resolve at display through Localizable.strings — see the
/// "App Intents" block in both catalogues.
struct GetLatestClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Clip"
    static let description = IntentDescription(
        "Reads the newest clip in MemoryClip's history, optionally only of one kind."
    )

    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Get the latest \(\.$kind) clip")
    }

    /// Optional; "any" is the panel's unfiltered list.
    @Parameter(title: "Kind", default: .any)
    var kind: ClipKindOption

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let service = await ClipIntentService.live() else {
            throw ClipIntentService.IntentError.storeUnavailable
        }
        guard let file = try await service.latestFile(kind: kind) else {
            throw ClipIntentService.IntentError.clipMissing
        }
        return .result(value: file)
    }
}
