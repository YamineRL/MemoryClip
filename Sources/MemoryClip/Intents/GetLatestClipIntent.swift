import AppIntents
import Foundation

/// "Get Latest Clip": the newest clip's text, returned as a Shortcuts result.
///
/// Spike S3 shape on purpose: a direct ClipStore read, not the
/// ClipIntentService seam the PRD's Tests section calls for. This type exists
/// to prove that a SwiftPM build can produce Metadata.appintents (see
/// Scripts/make_app.sh); the four real intents replace it in the build phase.
///
/// `title` and `description` stay literal because the metadata extractor
/// const-folds them at compile time: a loc() call would extract nothing and
/// the action would land in Shortcuts nameless. Their localization is part of
/// the build-phase work (a LocalizedStringResource key plus the strings
/// tables), not of this spike.
struct GetLatestClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Clip"
    static let description: IntentDescription = "Reads the newest clip in MemoryClip's history as text."

    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // ClipStore is @MainActor: it opens the on-disk store, so the read
        // hops onto the main actor and out again with plain String output.
        let text = await MainActor.run { () -> String in
            guard let store = try? ClipStore(),
                  let clip = store.recent(limit: 1).first else {
                return loc("Nothing copied yet")
            }
            return clip.text ?? loc("Latest clip has no text")
        }
        return .result(value: text)
    }
}
