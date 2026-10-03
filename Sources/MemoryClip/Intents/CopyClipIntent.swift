import AppIntents
import Foundation

/// "Copy Clip": puts a clip from the history back on the pasteboard —
/// what a Shortcut does to chain MemoryClip into an automation without
/// opening the panel.
///
/// Literal titles for the same reason as the other intents — see
/// GetLatestClipIntent's note.
struct CopyClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Clip"
    static let description = IntentDescription(
        "Puts the chosen clip back on the clipboard."
    )

    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Copy \(\.$clip) to the clipboard")
    }

    @Parameter(title: "Clip")
    var clip: ClipEntity

    func perform() async throws -> some IntentResult {
        guard let service = await ClipIntentService.live() else {
            throw ClipIntentService.IntentError.storeUnavailable
        }
        guard try await service.resolve(clip.id) != nil else {
            throw ClipIntentService.IntentError.clipMissing
        }
        guard try await service.copy(uuid: clip.id) else {
            throw ClipIntentService.IntentError.copyFailed
        }
        return .result()
    }
}
