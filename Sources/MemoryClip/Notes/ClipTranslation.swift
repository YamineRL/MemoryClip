import Foundation

/// Reading a clip that is not in your language.
///
/// # What this is, and what it is not
///
/// `NoteTranslation` translates a *screenshot* into English on its way into a
/// note, because the rest of the note pipeline — the on-device model, the
/// refinement guard, a vault the user searches in English — is built on
/// English. This is the other direction of the same idea and shares none of
/// those constraints: it translates a clip the user just copied into the
/// language the user reads, which is whatever their Mac is set to, and shows
/// it in the preview pane. Nothing downstream consumes it, so the target is
/// theirs to pick.
///
/// The two features share the translator, the language detector and the
/// catalog, and nothing else. In particular `NoteTranslation.target` stays
/// English: changing the language a preview is shown in must not change what
/// a note says.
///
/// Every clip with text in it is in scope, a picture included: what is read
/// from a screenshot is what was recognised in it, cleaned up by the model
/// where that has happened. The English rendering a screenshot may already
/// carry in `translatedText` is deliberately NOT reused, even when English is
/// what the user asked for. That one is a translation of the raw recognition
/// rather than of the cleaned text, so the two are not the same string, and
/// reusing it would leave the pane taking its translation from one place for
/// the screenshots the note pipeline had reached and another for everything
/// else.
///
/// # Why it runs at preview time
///
/// A clipboard fills up with things nobody looks at twice — a password, a
/// path, the same URL three times. Translating at capture would run the
/// on-device engine on every one of them, and translation is the slowest
/// stage MemoryClip has (`NoteTranslation.characterBudget` documents the
/// measurements). Opening a preview is the one moment a clip is known to be
/// worth reading, so the work happens there, once, and the result is cached
/// on the clip.
enum ClipTranslation {
    /// Whether a previewed clip is translated. Off unless the user said so —
    /// unlike `NoteTranslation.isEnabled`, which treats an unregistered key
    /// as on.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: NoteSettingsKeys.clipTranslateEnabled)
    }

    /// The language clips are translated into, as a BCP-47 identifier.
    static var targetIdentifier: String {
        get {
            let stored = UserDefaults.standard.string(forKey: NoteSettingsKeys.clipTranslationTarget) ?? ""
            return stored.isEmpty ? defaultTargetIdentifier : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: NoteSettingsKeys.clipTranslationTarget) }
    }

    /// The same, as the framework wants it.
    static var target: Locale.Language {
        Locale.Language(identifier: targetIdentifier)
    }

    /// What the target defaults to: the language this Mac is set to read.
    ///
    /// The language code alone, without region or script, because a target is
    /// a language and not a locale — someone whose Mac is en-GB wants English,
    /// not a translation into British English that the engine does not
    /// distinguish anyway. English is the fallback for the case where the
    /// preferred list is empty or names something without a language code,
    /// which is also the pairing macOS ships assets for most widely.
    static let defaultTargetIdentifier: String = {
        guard let preferred = Locale.preferredLanguages.first,
              let code = Locale.Language(identifier: preferred).languageCode?.identifier,
              !code.isEmpty
        else { return "en" }
        return code
    }()

    /// What a target is called on the clip, and what two targets are compared
    /// on: the language, plus its script only where the script says something.
    ///
    /// Regions are dropped, because the engine does not translate differently
    /// for Austria and a target of "de-AT" would otherwise make every German
    /// translation already on a clip look stale. A script that is merely the
    /// language's own goes too — `Locale.Language.script` fills one in whether
    /// or not the identifier named one, and "German (Latin)" is not how a
    /// language is written over a translation. What survives is the script
    /// that distinguishes: zh-Hant stays zh-Hant, the same rule
    /// `TranslationCatalog` names its rows by.
    ///
    /// Spelled out rather than left to `minimalIdentifier`, which minimizes
    /// by canonicalization and answers "zh-TW" for Traditional Chinese — a
    /// region where the whole point of keeping the subtag was the script.
    static func identity(of target: Locale.Language) -> String {
        guard let code = target.languageCode?.identifier else { return target.minimalIdentifier }
        guard let script = target.script?.identifier,
              script != Locale.Language(identifier: code).script?.identifier
        else { return code }
        return "\(code)-\(script)"
    }

    /// The text a previewed clip is read from, or nil when it has none.
    ///
    /// Text clips carry it directly. An image carries it in `ocrText`, and in
    /// `refinedText` once the on-device model has been over that — the
    /// cleaned version is preferred, because rejoined lines and corrected
    /// recognition slips are the difference between handing a translator a
    /// sentence and handing it three fragments of one.
    ///
    /// A screenshot is an image clip whose kind happens to be `.file`: it
    /// references the picture on disk instead of holding its pixels. That is
    /// a storage decision, invisible to whoever is reading the pane, so the
    /// flag is read here — the same gate `ClipDisplay.extractedText` uses —
    /// and nowhere else.
    static func sourceText(
        kind: ClipKind,
        isScreenshot: Bool,
        text: String?,
        ocrText: String?,
        refinedText: String?
    ) -> String? {
        let candidates: [String?]
        if kind == .image || isScreenshot {
            candidates = [refinedText, ocrText]
        } else if ClipDisplay.isTextBearing(kind) {
            candidates = [text]
        } else {
            // A colour swatch, or a file clip that is a list of paths.
            candidates = []
        }

        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// What the preview should do about a clip's text, decided before any of
    /// it is sent anywhere.
    ///
    /// Pure and free of SwiftData, so every reason not to translate is
    /// testable without a model container or a language asset on the machine
    /// running the suite. The same split as `LanguageDetector` against
    /// `AppleTranslator`.
    ///
    /// Which text a clip offers is `sourceText`'s question, not this one's:
    /// a screenshot with nothing recognised in it and a colour swatch both
    /// arrive here as nil and are skipped for the same reason.
    static func plan(
        text: String?,
        cached: ClipTranslationResult?,
        isEnabled: Bool,
        target: Locale.Language
    ) -> ClipTranslationPlan {
        guard isEnabled else { return .skip }

        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= LanguageDetector.minimumCharacters else { return .skip }

        // Checked before the recognizer runs: a clip already translated for
        // this target costs nothing to show again, which is the point of
        // caching it.
        if let cached, cached.targetLanguage == identity(of: target) { return .cached(cached) }

        // Bounded first, so the recognizer reads at most a budget's worth of
        // a very long clip as well.
        let (sent, remainder) = NoteTranslation.bounded(trimmed)
        guard let source = LanguageDetector.dominantLanguage(of: sent) else { return .skip }
        guard LanguageDetector.needsTranslation(source, into: target) else { return .skip }

        return .translate(ClipTranslationRequest(
            text: sent,
            isTruncated: !remainder.isEmpty,
            source: source,
            target: target
        ))
    }
}

/// What to show over a previewed clip.
enum ClipTranslationPlan: Equatable, Sendable {
    /// Nothing: the feature is off, the clip has no text to read, what it has
    /// is too short to identify, its language could not be told, or it is
    /// already in the target language.
    case skip
    /// The translation already on the clip, made for the target in force now.
    case cached(ClipTranslationResult)
    /// Work to do.
    case translate(ClipTranslationRequest)
}

/// A translation to make.
struct ClipTranslationRequest: Equatable, Sendable {
    /// The text to send, already inside `NoteTranslation.characterBudget`.
    var text: String
    /// Whether `text` is the head of a longer clip.
    var isTruncated: Bool
    var source: Locale.Language
    var target: Locale.Language
}

/// A translation to show, and everything the pane needs to label it.
struct ClipTranslationResult: Equatable, Sendable {
    var text: String
    /// BCP-47 identifiers, both of them, so the pair survives being cached on
    /// the clip and read back after a relaunch.
    var sourceLanguage: String
    var targetLanguage: String

    /// "French → English", for the line over the translation.
    var languagePair: String {
        let source = LanguageDetector.displayName(forIdentifier: sourceLanguage)
        let target = LanguageDetector.displayName(forIdentifier: targetLanguage)
        return "\(source) → \(target)"
    }

    /// The same thing said in words, because an arrow is read aloud as
    /// nothing at all.
    var accessibilityDescription: String {
        let source = LanguageDetector.displayName(forIdentifier: sourceLanguage)
        let target = LanguageDetector.displayName(forIdentifier: targetLanguage)
        return loc("Translated from %@ into %@", source, target)
    }
}

/// Running a `ClipTranslationRequest` through a translator.
///
/// Thin on purpose: the decisions are in `ClipTranslation.plan`, the engine is
/// behind `NoteTranslator`, and what is left here is the one thing neither of
/// them can do — say that the translation stops short of the end of the clip.
struct ClipTranslationService: Sendable {
    private let translator: any NoteTranslator

    /// - Parameter translator: injectable so tests never depend on which
    ///   language assets happen to be on the machine running them.
    init(translator: any NoteTranslator = AppleTranslator()) {
        self.translator = translator
    }

    /// The translation, or nil for every failure there is — the pane then
    /// shows the clip as it was, which is what it was showing anyway.
    ///
    /// A clip past the budget is marked rather than continued. The note
    /// pipeline carries the untranslated remainder because a note is a file
    /// nobody reads next to its original; here the original is on screen
    /// directly underneath, so repeating it would fill the pane with the text
    /// the translation was supposed to save the reader from.
    func translation(for request: ClipTranslationRequest) async -> ClipTranslationResult? {
        guard let translated = await translator.translate(
            request.text,
            from: request.source,
            to: request.target
        ) else { return nil }

        var text = translated.text
        if request.isTruncated {
            text += "\n\n\(NoteTranslation.truncationMarker)"
        }
        return ClipTranslationResult(
            text: text,
            sourceLanguage: translated.sourceLanguage,
            targetLanguage: ClipTranslation.identity(of: request.target)
        )
    }
}

extension ClipItem {
    /// The text this clip is translated from: its own, or what was recognised
    /// in its picture.
    var clipTranslationSourceText: String? {
        ClipTranslation.sourceText(
            kind: kind,
            isScreenshot: isScreenshot,
            text: text,
            ocrText: ocrText,
            refinedText: refinedText
        )
    }

    /// The translation cached on this clip, as one value.
    ///
    /// Three columns rather than one, because the target has to be readable
    /// on its own for `ClipTranslation.plan` to tell a usable cache from a
    /// stale one; this is where they are put back together.
    var cachedClipTranslation: ClipTranslationResult? {
        get {
            guard let text = clipTranslationText,
                  let source = clipTranslationSource,
                  let target = clipTranslationTarget
            else { return nil }
            return ClipTranslationResult(text: text, sourceLanguage: source, targetLanguage: target)
        }
        set {
            clipTranslationText = newValue?.text
            clipTranslationSource = newValue?.sourceLanguage
            clipTranslationTarget = newValue?.targetLanguage
        }
    }
}
