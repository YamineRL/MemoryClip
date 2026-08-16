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
}
