import Foundation
#if canImport(Translation)
import Translation
#endif

/// Translation on Apple's on-device engine (macOS 15+, used here on 26).
///
/// The provider behind the `NoteTranslator` seam. Everything
/// Translation-framework-specific lives in this file so `NoteTranslator.swift`
/// stays plain Foundation and the pipeline still builds against an SDK
/// without the framework.
///
/// # The download problem, and why it is surfaced rather than solved
///
/// `TranslationSession` can only be built two ways. The SwiftUI
/// `.translationTask` modifier makes one that can ask macOS to download
/// language assets (it puts up a system prompt); the plain
/// `init(installedSource:target:)` makes one that cannot — it reports
/// `canRequestDownloads == false` and throws `TranslationError.notInstalled`
/// for a language whose assets are absent.
///
/// The note pipeline runs in the background, off any view, so it necessarily
/// gets the second kind. On this machine (macOS 26.5) es, fr, de, it, pt, nl,
/// sv, da, tr, vi, ja, ko and zh-Hans were installed out of the box while ar,
/// ru, hi, th, id, pl and uk were merely *supported* — so this is not an edge
/// case, it is exactly what happens the first time someone screenshots
/// Arabic.
///
/// Failing silently would leave the feature permanently broken with no
/// explanation, so `translate` records the language in
/// `NoteTranslation.pendingDownloads` and Settings offers the SwiftUI-hosted
/// download that only a view can perform.
struct AppleTranslator: NoteTranslator {
    init() {}

    func supportedLanguages() async -> [Locale.Language] {
        #if canImport(Translation)
        return await LanguageAvailability().supportedLanguages
        #else
        return []
        #endif
    }

    func readiness(for language: Locale.Language) async -> TranslationReadiness {
        #if canImport(Translation)
        switch await LanguageAvailability().status(from: language, to: NoteTranslation.target) {
        case .installed: return .ready
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
        #else
        return .unsupported
        #endif
    }

    /// Translate, or return nil and leave the note in its own language.
    func translate(_ text: String, from language: Locale.Language) async -> TranslatedText? {
        #if canImport(Translation)
        let identifier = LanguageDetector.identifier(for: language)
        let (sent, remainder) = NoteTranslation.bounded(text)
        guard !sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        switch await readiness(for: language) {
        case .ready:
            NoteTranslation.clearPendingDownload(identifier)
        case .needsDownload:
            // Not an error the user caused and not one we can fix here: leave
            // the language where Settings will find it and write the note
            // untranslated.
            NoteTranslation.notePendingDownload(identifier)
            log.notice("Translation skipped: \(identifier, privacy: .public) assets are not downloaded")
            return nil
        case .unsupported:
            log.notice("Translation skipped: \(identifier, privacy: .public) is not supported by this Mac")
            return nil
        }

        // A new session per clip, for the same reason `FoundationModelsRefiner`
        // builds a new `LanguageModelSession` each time: it is a one-shot
        // transform, the source language changes from clip to clip, and the
        // session is a reference type whose lifetime is easiest to reason
        // about when it does not outlive the call.
        let session = TranslationSession(installedSource: language, target: NoteTranslation.target)
        defer { session.cancel() }

        do {
            let response = try await session.translate(sent)
            var translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { return nil }
            if !remainder.isEmpty {
                translated += "\n\n\(NoteTranslation.truncationMarker)\n\n\(remainder)"
            }
            return TranslatedText(text: translated, sourceLanguage: identifier)
        } catch {
            // Everything lands here the same way: cancellation, an asset that
            // disappeared between the availability check and the call, an
            // internal engine failure. The note is written in its original
            // language, which is the text the user photographed anyway.
            log.error("Translation failed for \(identifier, privacy: .public): \(Self.reason(for: error), privacy: .public)")
            if Self.isNotInstalled(error) {
                NoteTranslation.notePendingDownload(identifier)
            }
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(Translation)
    /// Whether this is the "assets are not on the Mac" failure, which is the
    /// one the user can act on.
    ///
    /// Matched with `~=` because `TranslationError` is a struct of static
    /// members rather than an enum, so there is no case to switch on.
    static func isNotInstalled(_ error: any Error) -> Bool {
        TranslationError.notInstalled ~= error
    }

    /// A short, log-safe reason. Deliberately not `localizedDescription` for
    /// the cases we recognise: those descriptions are written for an alert
    /// and can name the text being translated, which is the user's screen.
    static func reason(for error: any Error) -> String {
        switch error {
        case let error where TranslationError.notInstalled ~= error:
            return "language assets not installed"
        case let error where TranslationError.unsupportedLanguagePairing ~= error:
            return "unsupported language pairing"
        case let error where TranslationError.unsupportedSourceLanguage ~= error:
            return "unsupported source language"
        case let error where TranslationError.unableToIdentifyLanguage ~= error:
            return "could not identify the language"
        case let error where TranslationError.nothingToTranslate ~= error:
            return "nothing to translate"
        case let error where TranslationError.alreadyCancelled ~= error:
            return "cancelled"
        case is CancellationError:
            return "cancelled"
        default:
            return "internal translation error"
        }
    }
    #endif
}

/// The no-translation translator: the floor the pipeline falls back to, and
/// what tests inject so they never depend on which language assets happen to
/// be on the machine running them.
struct DisabledTranslator: NoteTranslator {
    init() {}
    func supportedLanguages() async -> [Locale.Language] { [] }
    func readiness(for language: Locale.Language) async -> TranslationReadiness { .unsupported }
    func translate(_ text: String, from language: Locale.Language) async -> TranslatedText? { nil }
}
