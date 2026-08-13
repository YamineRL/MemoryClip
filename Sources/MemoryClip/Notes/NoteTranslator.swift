import Foundation
import NaturalLanguage

/// Reading a screenshot that is not in English (Phase 5).
///
/// # What this layer is for
///
/// Recognition is language-blind once `OCRService` turns automatic language
/// detection on: an Arabic screenshot comes back as Arabic, a Japanese one
/// as Japanese. Everything downstream of it is not. Apple's on-device model
/// reads 23 locales and Arabic, Hindi, Russian, Thai and Ukrainian are not
/// among them (`SystemLanguageModel.supportedLanguages`), so refinement of a
/// language it cannot read is at best a no-op and at worst a rewrite that
/// `RefinementGuard` has no way to judge. And a note the user cannot read
/// back is not a note.
///
/// So a clip whose text is not in `NoteTranslation.target` is translated
/// first, on-device, and the note carries BOTH: the original text as
/// recognised, and the English rendering underneath it. The original is the
/// record — the same contract the raw OCR has against refinement — and the
/// translation is the part that makes it findable and readable.
///
/// # Why the seam is here and not in the provider
///
/// The same reasoning as `NoteRefiner`: this file imports NaturalLanguage
/// (which is present everywhere) but not Translation, so the pipeline
/// compiles and runs where the framework or its language assets are missing,
/// the detection rules are unit-testable without a translation session, and
/// a second provider is a conformance rather than a rewrite.
///
/// # The failure contract
///
/// Identical to refinement's, and for the same reason — the original text is
/// already persisted on the clip before anything here runs and stays there
/// afterwards. `translate` does not throw and does not block anything the
/// user is waiting on; every failure (unsupported pair, assets not
/// downloaded, cancellation) returns nil, which downstream means "write the
/// note in its own language", not "try again".

// MARK: - Types

/// A completed translation.
struct TranslatedText: Sendable, Equatable {
    /// The translated text, in `NoteTranslation.target`.
    var text: String
    /// What it was translated FROM, as a BCP-47 identifier ("ar", "ja").
    /// Stored on the clip and written into note front matter, so a vault can
    /// be queried for everything that arrived in a given language.
    var sourceLanguage: String
}

/// Anything that can turn foreign-language text into English.
protocol NoteTranslator: Sendable {
    /// Every language this Mac can translate into English, downloaded or not.
    ///
    /// Read live rather than hard-coded: the list is Apple's, it grows with
    /// macOS releases, and a list of our own would be wrong the moment one
    /// does. Settings turns it into the menu the user picks from.
    func supportedLanguages() async -> [Locale.Language]

    /// Whether `language` could be translated right now, without a download.
    ///
    /// Three-valued rather than a Bool because the middle case is the one the
    /// user can do something about — see `TranslationReadiness`.
    func readiness(for language: Locale.Language) async -> TranslationReadiness

    /// Never throws: anything that goes wrong returns nil and the note is
    /// written in its original language.
    func translate(_ text: String, from language: Locale.Language) async -> TranslatedText?
}

/// Whether a language pair can be used, could be after a download, or never.
enum TranslationReadiness: Sendable, Equatable {
    /// The assets are on the Mac; translation works now.
    case ready
    /// macOS can translate this language, but the assets have not been
    /// downloaded. Nothing MemoryClip does in the background can fetch them —
    /// see `AppleTranslator.translate` — so this is surfaced in Settings with
    /// a button rather than swallowed.
    case needsDownload
    /// macOS cannot translate this language at all.
    case unsupported
}

// MARK: - Settings and target

/// The fixed points of translation: what we translate into, and how much of
/// a clip is worth translating.
enum NoteTranslation {
    /// The language notes are translated into.
    ///
    /// English rather than the user's preferred locale, deliberately: it is
    /// the language the rest of the pipeline is best at — the on-device model
    /// reads it, `RefinementGuard`'s tokenizer was tuned on it — and it is
    /// the one pairing macOS ships assets for most widely. The original text
    /// is always kept, so this is a second reading of the note, never a
    /// replacement of it.
    static let target = Locale.Language(identifier: "en-US")

    /// The identifier written into note front matter for `target`.
    static let targetIdentifier = "en"

    /// How much text is translated, in characters.
    ///
    /// Translation is by far the slowest stage of the pipeline. Measured on
    /// an M1 Pro (macOS 26.5) against an installed es→en pair: ~180
    /// characters took 2.5 s including session warm-up, and a 10,080
    /// character block took **80 seconds** — the cost is close to linear, so
    /// an unbounded screenshot of a long article would hold the note queue
    /// for well over a minute. 4000 characters is ~30 s worst case and
    /// covers a dense full-screen page of text; past that the remainder is
    /// carried through untranslated behind `truncationMarker` rather than
    /// silently dropped.
    static let characterBudget = 4000

    /// How far back from the budget a line boundary is worth looking for,
    /// as a fraction of it. Same rule and same reasoning as
    /// `FoundationModelsRefiner.lineBoundarySearchFloor`: cutting mid-sentence
    /// hands the translator a fragment.
    static let lineBoundarySearchFloor = 0.8

    /// Marks where the translation stops and untranslated text begins.
    static let truncationMarker = "— translation ends here; the rest is untranslated —"

    /// Whether the user has translation switched on. Registered `true`;
    /// treated as on when the key was never registered (tests, wiped
    /// defaults), matching `FoundationModelsRefiner.isEnabled`.
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: NoteSettingsKeys.translateEnabled) != nil else { return true }
        return defaults.bool(forKey: NoteSettingsKeys.translateEnabled)
    }

    /// Split `text` into the part sent to the translator and the untouched
    /// remainder, cutting on a line boundary where one is close enough.
    static func bounded(_ text: String) -> (sent: String, remainder: String) {
        guard text.count > characterBudget else { return (text, "") }

        let hardCut = text.index(text.startIndex, offsetBy: characterBudget)
        let searchFloor = text.index(
            text.startIndex,
            offsetBy: Int(Double(characterBudget) * lineBoundarySearchFloor)
        )
        let cut = text[searchFloor..<hardCut].lastIndex(of: "\n") ?? hardCut

        return (
            String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines),
            String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Languages MemoryClip has met and could not translate for want of a
    /// download, as BCP-47 identifiers.
    ///
    /// Written by the pipeline, read by Settings, which is the only place
    /// that CAN fix it: a translation session created outside SwiftUI reports
    /// `canRequestDownloads == false` and can never fetch an asset, so the
    /// background path's only honest move is to leave a note of what was
    /// missing. Capped and deduplicated, because this is a to-do list for the
    /// user, not a log.
    static var pendingDownloads: [String] {
        get { UserDefaults.standard.stringArray(forKey: NoteSettingsKeys.translationPending) ?? [] }
        set {
            let trimmed = Array(newValue.reduce(into: [String]()) { seen, code in
                if !seen.contains(code) { seen.append(code) }
            }.suffix(pendingDownloadLimit))
            UserDefaults.standard.set(trimmed, forKey: NoteSettingsKeys.translationPending)
        }
    }

    /// Most languages remembered as needing a download. Five is more than a
    /// Settings callout can list without becoming a wall.
    static let pendingDownloadLimit = 5

    static func notePendingDownload(_ identifier: String) {
        guard !identifier.isEmpty else { return }
        pendingDownloads = pendingDownloads + [identifier]
    }

    static func clearPendingDownload(_ identifier: String) {
        pendingDownloads = pendingDownloads.filter { $0 != identifier }
    }
}

// MARK: - Detection

/// Which language a piece of recognised text is in.
///
/// Split out from the translator so the rule that decides whether to
/// translate at all is testable without any translation assets on the
/// machine — the same reason `RefinementGuard` is separate from the model.
enum LanguageDetector {
    /// Below this many characters, identification is guesswork.
    ///
    /// `NLLanguageRecognizer` will happily name a language for "OK" or for a
    /// row of menu titles, and a wrong answer here costs a pointless
    /// translation of text that was already English. Screenshots are full of
    /// short fragments, so the floor is deliberately above the length of a
    /// button label.
    static let minimumCharacters = 20

    /// How sure the recognizer has to be before we act on it.
    ///
    /// Applied to the top hypothesis. Latin-script languages compete with
    /// each other (a Spanish sentence with three English nouns in it splits
    /// its probability), and the cost of a false positive — translating text
    /// the user can already read — is worse than the cost of a false
    /// negative, which is simply the note we would have written anyway.
    static let minimumConfidence = 0.65

    /// The dominant language of `text`, or nil when there is not enough
    /// evidence to say.
    ///
    /// Nil is not an error: it means "write this note as it is", which is
    /// also the right answer for a screenshot of a table of numbers.
    static func dominantLanguage(of text: String) -> Locale.Language? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
        guard confidence >= minimumConfidence else { return nil }

        return Locale.Language(identifier: dominant.rawValue)
    }

    /// Whether text in `language` needs translating for the note to be
    /// readable.
    ///
    /// Compares language codes only, never regions: en-GB text does not need
    /// translating into en-US, and `Locale.Language.isEquivalent(to:)` — which
    /// would say the same — is not available for every identifier shape the
    /// recognizer emits (it returns bare codes like "ar" and "zh-Hans").
    static func needsTranslation(_ language: Locale.Language?) -> Bool {
        guard let code = language?.languageCode?.identifier else { return false }
        return code != NoteTranslation.target.languageCode?.identifier
    }

    /// A BCP-47 identifier for storage and front matter ("ar", "zh-Hans").
    static func identifier(for language: Locale.Language) -> String {
        language.minimalIdentifier
    }

    /// The language's name in the user's own language ("Arabic"), for the
    /// heading over a translation and for Settings. Falls back to the
    /// identifier, so an unnamed language still reads as something.
    static func displayName(forIdentifier identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier)
            ?? Locale.current.localizedString(forLanguageCode: identifier)
            ?? identifier
    }
}

// MARK: - Catalog

/// One row of the language menu in Settings.
struct TranslationLanguage: Identifiable, Sendable, Equatable {
    /// A stable identifier for the row — the language code plus its script
    /// where the script matters ("ar", "zh-Hans").
    let id: String
    /// What the user reads: the language's name in their own language.
    let name: String
    /// The language object to hand back to the framework, taken from its own
    /// list rather than rebuilt from `id`, so we never ask it about an
    /// identifier it did not offer.
    let language: Locale.Language

    static func == (lhs: TranslationLanguage, rhs: TranslationLanguage) -> Bool { lhs.id == rhs.id }
}

/// Turning the framework's list of supported languages into a menu.
///
/// Pure, and separate from the provider, so the grouping and naming rules are
/// testable on a machine with no translation assets at all — the same split
/// as `LanguageDetector` against `AppleTranslator`.
enum TranslationCatalog {
    /// The menu, sorted by name in the user's locale.
    ///
    /// Three rules, each earning its place against the raw list (38 entries
    /// on macOS 26.5):
    ///
    /// 1. **English is dropped.** It is the target; "translate English into
    ///    English" is not an option, it is a no-op.
    /// 2. **Regions are collapsed, scripts are not.** Apple lists es-ES,
    ///    es-MX and es-US separately, and offering three Spanishes to someone
    ///    who wants to read a screenshot is a choice with no right answer.
    ///    Script is different: Simplified and Traditional Chinese are not the
    ///    same text, so zh-Hans and zh-Hant stay apart.
    /// 3. **Names carry the script only when it disambiguates.** Naming the
    ///    grouped identifier directly gives "Danish (Latin)" and "Thai
    ///    (Thai)"; naming the bare language code gives "Chinese" twice. So
    ///    the script is spelled out exactly where a language has more than
    ///    one of them, and left off everywhere else.
    static func menu(from languages: [Locale.Language], excluding target: Locale.Language) -> [TranslationLanguage] {
        let targetCode = target.languageCode?.identifier

        // First pass: group by language + script, keeping the framework's own
        // first entry for each, and count the scripts per language.
        var order: [String] = []
        var byKey: [String: Locale.Language] = [:]
        var scriptsByCode: [String: Set<String>] = [:]
        for language in languages {
            guard let code = language.languageCode?.identifier, code != targetCode else { continue }
            let script = language.script?.identifier
            let key = [code, script].compactMap { $0 }.joined(separator: "-")
            scriptsByCode[code, default: []].insert(script ?? "")
            guard byKey[key] == nil else { continue }
            byKey[key] = language
            order.append(key)
        }

        return order.compactMap { key -> TranslationLanguage? in
            guard let language = byKey[key], let code = language.languageCode?.identifier else { return nil }
            let needsScript = (scriptsByCode[code]?.count ?? 0) > 1
            let name = needsScript
                ? (Locale.current.localizedString(forIdentifier: key) ?? key)
                : (Locale.current.localizedString(forLanguageCode: code) ?? key)
            return TranslationLanguage(id: key, name: name, language: language)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The row a detected-language identifier belongs to, if any.
    ///
    /// Matched on language code rather than on the whole identifier: the
    /// pipeline records what `NLLanguageRecognizer` saw ("ar", "zh-Hans"),
    /// and the menu is keyed on what the Translation framework offers, which
    /// need not be spelled the same way.
    static func row(matching identifier: String, in menu: [TranslationLanguage]) -> TranslationLanguage? {
        let code = Locale.Language(identifier: identifier).languageCode?.identifier
        return menu.first { $0.id == identifier }
            ?? menu.first { $0.language.languageCode?.identifier == code }
    }
}
