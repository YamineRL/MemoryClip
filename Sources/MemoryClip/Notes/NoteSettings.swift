import Foundation

/// Every UserDefaults key for the screenshot → text → note pipeline, plus
/// the small enums two or more layers have to agree on.
///
/// Collected here rather than next to the code that reads them because the
/// pipeline spans capture, recognition, refinement and export: a key defined
/// beside its reader would be a key the Settings UI has to guess at.
enum NoteSettingsKeys {
    // Screenshots
    static let screenshotCaptureEnabled = "screenshotCaptureEnabled"
    static let screenshotFolderBookmark = "screenshotFolderBookmark"
    /// Timestamp of the newest screenshot already seen, so enabling the
    /// feature does not import a Desktop's worth of history and a relaunch
    /// does not replay it.
    static let screenshotLastSeen = "screenshotLastSeen"

    // Refinement
    static let refineEnabled = "noteRefineEnabled"

    // Translation
    static let translateEnabled = "noteTranslateEnabled"
    /// The languages the user picked to have detected and translated, as
    /// catalog identifiers ("ar-Arab", "zh-Hans"). Empty means "whatever this
    /// Mac can already translate" — see `NoteTranslation.allowsLanguage`.
    static let translationLanguages = "noteTranslationLanguages"
    /// Languages the pipeline met and could not translate because their
    /// assets are not downloaded. Written by `NoteTranslation`, read by
    /// Settings — which is the only place that can start the download.
    static let translationPending = "noteTranslationPending"

    // Clip translation
    /// Whether a previewed text clip is translated into the user's own
    /// language. A different feature from the three keys above, which belong
    /// to the screenshot → note pipeline and always translate into English —
    /// see `ClipTranslation`.
    static let clipTranslateEnabled = "clipTranslateEnabled"
    /// The language a previewed clip is translated INTO, as a BCP-47
    /// identifier. Defaulted to whatever this Mac is set to read.
    static let clipTranslationTarget = "clipTranslationTarget"

    // Notes
    static let autoNoteEnabled = "autoNoteEnabled"
    static let autoNoteMinimumCharacters = "autoNoteMinimumCharacters"
    static let destination = "noteDestination"
    static let vaultBookmark = "noteVaultBookmark"
    static let vaultAttachmentFolder = "noteVaultAttachmentFolder"
    static let copyAttachments = "noteCopyAttachments"
    static let notesAppFolder = "noteNotesAppFolder"
    static let shortcutName = "noteShortcutName"

    /// Registered at launch. Note what is OFF: screenshot watching (it needs
    /// a folder the user has to grant access to) and automatic note writing
    /// (a note per screenshot would bury a vault — the manual action is the
    /// default way in). Refinement is ON but inert until something asks for
    /// a note or a screenshot is captured, and so is translation, which in
    /// addition only ever fires for text that is not already English.
    ///
    /// Clip translation is OFF: it reads what the user copies, which is a
    /// thing to be asked for rather than switched on for someone who has not
    /// heard of it. Its target still gets a default, so the first thing the
    /// toggle does is translate into the language this Mac is set to.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            screenshotCaptureEnabled: false,
            refineEnabled: true,
            translateEnabled: true,
            clipTranslateEnabled: false,
            clipTranslationTarget: ClipTranslation.defaultTargetIdentifier,
            autoNoteEnabled: false,
            autoNoteMinimumCharacters: 80,
            destination: NoteDestination.markdownVault.rawValue,
            vaultAttachmentFolder: "attachments",
            copyAttachments: true,
            notesAppFolder: "MemoryClip",
            shortcutName: "",
        ])
    }
}

/// Where a note is written.
enum NoteDestination: String, CaseIterable, Identifiable, Sendable {
    /// A folder of Markdown files — an Obsidian vault, or any other tool
    /// that reads `.md` off disk. The default: no permission prompt, no
    /// integration, and the note is a file the user owns.
    case markdownVault
    /// Apple Notes, via AppleScript. Needs the Automation permission.
    case notesApp
    /// Hand the note to a Shortcut, which can put it anywhere.
    case shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdownVault: return "Markdown folder"
        case .notesApp: return "Notes"
        case .shortcut: return "Shortcut"
        }
    }

    /// The current choice, falling back to the Markdown folder for an
    /// unrecognised stored value.
    static var current: NoteDestination {
        let raw = UserDefaults.standard.string(forKey: NoteSettingsKeys.destination) ?? ""
        return NoteDestination(rawValue: raw) ?? .markdownVault
    }
}

/// Failures a note export can hit that the user has to be told about.
enum NoteError: LocalizedError, Equatable {
    case noDestinationConfigured(NoteDestination)
    case folderUnavailable(String)
    case writeFailed(String)
    case automationDenied
    case shortcutFailed(String)
    case nothingToWrite

    var errorDescription: String? {
        switch self {
        case .noDestinationConfigured(let destination):
            switch destination {
            case .markdownVault: return "Choose a folder for notes in Settings → Notes."
            case .notesApp: return "Choose a Notes folder in Settings → Notes."
            case .shortcut: return "Choose a Shortcut in Settings → Notes."
            }
        case .folderUnavailable(let path):
            return "MemoryClip can no longer reach \(path). Pick the folder again in Settings → Notes."
        case .writeFailed(let reason):
            return "The note could not be written: \(reason)"
        case .automationDenied:
            return "MemoryClip needs permission to control Notes. Allow it in System Settings → Privacy & Security → Automation."
        case .shortcutFailed(let reason):
            return "The Shortcut did not finish: \(reason)"
        case .nothingToWrite:
            return "There is no text in this clip to write to a note."
        }
    }

    /// What the log is allowed to say out loud about this failure.
    ///
    /// `errorDescription` is written for the alert and interpolates whatever
    /// makes the sentence actionable — the vault path, or a message from the
    /// filesystem or from Shortcuts that usually names one. The unified log
    /// is a durable record that survives the app's own "Clear All History",
    /// so putting that description in it publicly would leave behind a trace
    /// of where the user keeps their notes that the app cannot take back.
    /// This names the kind of failure instead, which is what someone reading
    /// the log is actually triaging on, and carries nothing of the user's.
    ///
    /// Exhaustive rather than a `default`, so a new case has to decide what
    /// it is called here instead of quietly inheriting "unknown".
    var logReason: String {
        switch self {
        case .noDestinationConfigured(let destination):
            // The destination is one of three fixed values, not user data.
            return "no destination configured (\(destination.rawValue))"
        case .folderUnavailable:
            return "note folder unavailable"
        case .writeFailed:
            return "write failed"
        case .automationDenied:
            return "automation permission denied"
        case .shortcutFailed:
            return "shortcut failed"
        case .nothingToWrite:
            return "nothing to write"
        }
    }
}
