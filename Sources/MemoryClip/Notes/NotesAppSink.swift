import Foundation

/// Creates the note in Apple Notes, over AppleScript.
///
/// # This is the only permission-hungry path in MemoryClip
///
/// Everything else the app does — watching the pasteboard, reading a screenshot
/// folder the user picked in an open panel, running Vision, running the local
/// model, writing a Markdown file — needs no TCC grant beyond the folder the
/// user handed over themselves. Driving Notes needs the **Automation** grant,
/// which means:
///
/// - The app bundle must carry `NSAppleEventsUsageDescription` in Info.plist.
///   Without it macOS has no sentence to put in the prompt, and on a hardened
///   runtime it kills the process outright when the first Apple event goes out
///   rather than prompting at all.
/// - The first `write` here triggers the "MemoryClip wants to control Notes"
///   dialog, and `executeAndReturnError` BLOCKS on the main thread while it is
///   up. That is survivable only because writing to Notes is always a
///   user-initiated action; it must never be called from a background sweep.
/// - A denial is permanent from the app's point of view. macOS remembers it and
///   never asks again, so `NoteError.automationDenied` has to name System
///   Settings — there is nothing MemoryClip can do to re-prompt.
///
/// # Why the main actor
///
/// `NSAppleScript` is documented as not thread-safe, and Apple events are
/// delivered through the run loop of the thread that sent them. Executing one
/// on the cooperative pool means dispatching from a thread with no run loop
/// spinning: the classic symptom is not a crash but a call that returns a
/// `-1712` timeout after 120 seconds while the reply sits undelivered. Hence
/// `@MainActor` on the execution path, which the `async` protocol requirement
/// lets the caller hop to for free.
struct NotesAppSink: NoteSink {
    /// Notes folder to create the note in, creating the folder if needed.
    let folderName: String

    init(folderName: String) {
        self.folderName = folderName
    }

    // MARK: - NoteSink

    @MainActor
    func write(_ draft: NoteDraft) async throws -> NoteReceipt {
        guard draft.hasContent else { throw NoteError.nothingToWrite }
        let folder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { throw NoteError.noDestinationConfigured(.notesApp) }

        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = Self.script(
            folder: folder,
            title: title.isEmpty ? NoteComposer.fallbackFileNameComponent : title,
            body: NoteComposer.html(for: draft)
        )
        try Self.run(source)
        // A script that ran is the Automation grant, observed: there is no
        // status to read for Apple Events while Notes is not running, so this
        // is the moment the ledger can record. See `PermissionRecovery`.
        PermissionLedger().noteGranted(.notesAutomation)

        log.notice("Wrote note to Notes folder \(folder, privacy: .private)")
        // No `openURL`. Notes' AppleScript `id` is a `x-coredata://…` URL that
        // only Notes' own `show` command understands — it is not a URL scheme
        // anything else can open, and it does not survive a restore from
        // backup. Handing the UI a URL that fails to open is worse than
        // admitting there is not one.
        return NoteReceipt(location: "Notes › \(folder)", openURL: nil)
    }

    // MARK: - Script

    /// The AppleScript that creates (or reuses) the folder and adds the note.
    ///
    /// `exists folder` before `make new folder` rather than making it every
    /// time: Notes happily creates a SECOND folder with the same name, and the
    /// user would end up with a stack of identically named "MemoryClip"
    /// folders, each holding one note.
    ///
    /// The folder is looked up unqualified, so it resolves in Notes' default
    /// account. Naming an account explicitly would break for anyone whose only
    /// account is iCloud versus anyone whose only account is "On My Mac", and
    /// there is no reliable way to ask which the user meant.
    ///
    /// `name` is set as well as `body` even though Notes derives the title from
    /// the body's first line — which is why `NoteComposer.html` leads with an
    /// `<h1>`. Setting both means the title is right whichever rule the current
    /// version of Notes applies.
    static func script(folder: String, title: String, body: String) -> String {
        """
        tell application "Notes"
            if not (exists folder "\(appleScriptEscaped(folder))") then
                make new folder with properties {name:"\(appleScriptEscaped(folder))"}
            end if
            tell folder "\(appleScriptEscaped(folder))"
                make new note with properties {name:"\(appleScriptEscaped(title))", body:"\(appleScriptEscaped(body))"}
            end tell
        end tell
        """
    }

    /// Escape a string for an AppleScript double-quoted literal.
    ///
    /// Pure and separate from the script template so the cases can be tested
    /// without Notes installed — and there are more of them than they look:
    ///
    /// - `\` first, always. Escaping quotes before backslashes turns `\` into
    ///   `\\` after the quote pass has already doubled it, and the literal ends
    ///   in the wrong place.
    /// - `"` — a title as ordinary as `The "new" build` otherwise closes the
    ///   literal early and the rest of the title is parsed as AppleScript. Best
    ///   case that is a syntax error; worse case is a fragment that happens to
    ///   compile.
    /// - Newlines. An AppleScript string literal cannot span lines at all, and
    ///   `body` is a multi-line HTML document, so `\n` / `\r` are not an edge
    ///   case here — they are every single call.
    ///
    /// AppleScript's literal syntax understands exactly `\\`, `\"`, `\n`, `\r`
    /// and `\t`; anything else after a backslash is not an escape.
    static func appleScriptEscaped(_ value: String) -> String {
        var out = value.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\r\n", with: "\\n")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        out = out.replacingOccurrences(of: "\t", with: "\\t")
        return out
    }

    // MARK: - Execution

    @MainActor
    private static func run(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw NoteError.writeFailed("The Notes script could not be prepared.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw noteError(fromScriptError: errorInfo)
        }
    }

    /// Map `NSAppleScript`'s error dictionary onto something the user can act
    /// on.
    ///
    /// Kept `internal` and free of `NSAppleScript` so the mapping — the part
    /// that decides whether the user is shown "grant permission" or "try again"
    /// — is testable from a literal dictionary.
    ///
    /// The codes are OSStatus values from the Apple Event Manager:
    /// - **-1743** `errAEEventNotPermitted` — the Automation grant was denied,
    ///   or never asked for because Info.plist has no usage description. This
    ///   is the one that needs its own message: retrying does nothing, the user
    ///   has to go to System Settings.
    /// - **-600** `procNotFound` — Notes is not running and could not be
    ///   launched.
    /// - **-1728** `errAENoSuchObject` — the `folder "…"` lookup found nothing,
    ///   which in practice means Notes has no writable account (a fresh Mac
    ///   with iCloud Notes off has literally nowhere to put a note).
    ///
    /// Both of those last two are the same story for the user — Notes could not
    /// be reached — so they share a message that names the code, because the
    /// number is the only thing that makes a support conversation possible.
    static func noteError(fromScriptError info: NSDictionary) -> NoteError {
        let code = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        let message = (info[NSAppleScript.errorMessage] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch code {
        case -1743:
            return .automationDenied
        case -600, -1728:
            return .writeFailed("Notes could not be reached (\(code ?? 0)). \(message)"
                .trimmingCharacters(in: .whitespaces))
        default:
            guard !message.isEmpty else {
                return .writeFailed("AppleScript error \(code.map(String.init) ?? "unknown").")
            }
            return .writeFailed(message)
        }
    }
}
