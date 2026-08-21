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
        await readiness(from: language, to: NoteTranslation.target)
    }

    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness {
        #if canImport(Translation)
        switch await LanguageAvailability().status(from: source, to: target) {
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
        await translate(text, from: language, to: NoteTranslation.target)
    }

    /// The same, into a language the caller picked, waiting for the whole
    /// thing — what the note pipeline asks for.
    func translate(_ text: String, from language: Locale.Language, to target: Locale.Language) async -> TranslatedText? {
        await translate(text, from: language, to: target) { _ in }
    }

    /// The same again, reporting the translation so far as each chunk of it
    /// lands — what the preview pane asks for.
    ///
    /// Every step below is target-independent except the availability check
    /// and the session, which is why the note pipeline and the preview pane
    /// are two callers of one function.
    func translate(
        _ text: String,
        from language: Locale.Language,
        to target: Locale.Language,
        onProgress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> TranslatedText? {
        #if canImport(Translation)
        let identifier = LanguageDetector.identifier(for: language)
        let (sent, remainder) = NoteTranslation.bounded(text)
        guard !sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        switch await readiness(from: language, to: target) {
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

        do {
            var translated = try await TranslationSessions.shared.translate(
                NoteTranslation.chunks(sent),
                from: language,
                to: target,
                onProgress: onProgress
            )
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

// MARK: - Keeping a session

/// The language pair a kept session is filed under.
///
/// Maximal identifiers, so the pairs the engine does not distinguish share one
/// session: the note pipeline's "en-US" target and a preview pane set to "en"
/// are one key.
struct TranslationSessionKey: Hashable, Sendable {
    let source: String
    let target: String

    init(from source: Locale.Language, to target: Locale.Language) {
        self.source = source.maximalIdentifier
        self.target = target.maximalIdentifier
    }
}

/// Which sessions are being kept and when an unused one is let go.
///
/// Generic over the session, so the keying and the expiry are testable without
/// the Translation framework.
struct TranslationSessionRegistry<Session> {
    /// How long a session is kept after its last chunk.
    let idleTimeout: TimeInterval

    private struct Entry {
        var session: Session
        var lastUsed: Date
    }

    private var entries: [TranslationSessionKey: Entry] = [:]

    init(idleTimeout: TimeInterval = 90) {
        self.idleTimeout = idleTimeout
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    /// The session for `key`, marked as used at `now`.
    mutating func session(for key: TranslationSessionKey, now: Date = .now) -> Session? {
        guard let session = entries[key]?.session else { return nil }
        entries[key]?.lastUsed = now
        return session
    }

    mutating func insert(_ session: Session, for key: TranslationSessionKey, now: Date = .now) {
        entries[key] = Entry(session: session, lastUsed: now)
    }

    mutating func touch(_ key: TranslationSessionKey, now: Date = .now) {
        entries[key]?.lastUsed = now
    }

    mutating func remove(_ key: TranslationSessionKey) -> Session? {
        entries.removeValue(forKey: key)?.session
    }

    /// Drop and hand back every session unused for `idleTimeout`.
    mutating func removeExpired(now: Date = .now) -> [Session] {
        let cutoff = now.addingTimeInterval(-idleTimeout)
        let stale = entries.filter { $0.value.lastUsed <= cutoff }
        for key in stale.keys { entries.removeValue(forKey: key) }
        return stale.values.map(\.session)
    }
}

#if canImport(Translation)
/// The sessions themselves, kept between clips so the second clip of a page
/// does not pay to build one again.
///
/// Keeping them changes nothing about which languages work: these are still
/// `init(installedSource:target:)` sessions, still `canRequestDownloads ==
/// false`, and `readiness(from:to:)` still runs before every call.
actor TranslationSessions {
    static let shared = TranslationSessions()

    private var registry = TranslationSessionRegistry<TranslationSession>()
    private var sweep: Task<Void, Never>?

    /// Translate `chunks`, handing the text so far to `onProgress` as each one
    /// arrives, and return the whole of it.
    ///
    /// Responses are placed by `clientIdentifier` and published as an unbroken
    /// prefix, so what the pane shows only ever grows.
    func translate(
        _ chunks: [TranslationChunk],
        from source: Locale.Language,
        to target: Locale.Language,
        onProgress: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let key = TranslationSessionKey(from: source, to: target)
        let session = registry.session(for: key) ?? make(for: key, from: source, to: target)
        let batch = chunks.enumerated().map { index, chunk in
            TranslationSession.Request(sourceText: chunk.text, clientIdentifier: String(index))
        }

        var arrived = [String?](repeating: nil, count: chunks.count)
        var published = 0
        var text = ""

        do {
            for try await response in session.translate(batch: batch) {
                guard let index = response.clientIdentifier.flatMap(Int.init),
                      arrived.indices.contains(index)
                else { continue }
                arrived[index] = response.targetText
                while published < arrived.count, let part = arrived[published] {
                    text += part + chunks[published].separator
                    published += 1
                }
                registry.touch(key)

                let sofar = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sofar.isEmpty { await onProgress(sofar) }
            }
        } catch {
            // The session that threw is dropped and cancelled rather than
            // handed to the next clip.
            registry.remove(key)?.cancel()
            throw error
        }

        scheduleSweep()
        // Short of the last chunk is not a finished translation, and only a
        // finished one is returned to be cached on the clip.
        guard published == chunks.count else {
            log.error("Translation returned \(published, privacy: .public) of \(chunks.count, privacy: .public) chunks")
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func make(
        for key: TranslationSessionKey,
        from source: Locale.Language,
        to target: Locale.Language
    ) -> TranslationSession {
        let session = TranslationSession(installedSource: source, target: target)
        registry.insert(session, for: key)
        return session
    }

    /// Watch for idle sessions until there are none left.
    private func scheduleSweep() {
        guard sweep == nil else { return }
        sweep = Task {
            repeat {
                try? await Task.sleep(for: .seconds(registry.idleTimeout))
            } while !expire()
            sweep = nil
        }
    }

    /// Cancel every session past the timeout; true once the registry is empty.
    private func expire() -> Bool {
        for session in registry.removeExpired() { session.cancel() }
        return registry.isEmpty
    }
}
#endif

/// The no-translation translator: the floor the pipeline falls back to, and
/// what tests inject so they never depend on which language assets happen to
/// be on the machine running them.
struct DisabledTranslator: NoteTranslator {
    init() {}
    func supportedLanguages() async -> [Locale.Language] { [] }
    func readiness(for language: Locale.Language) async -> TranslationReadiness { .unsupported }
    func translate(_ text: String, from language: Locale.Language) async -> TranslatedText? { nil }
}
