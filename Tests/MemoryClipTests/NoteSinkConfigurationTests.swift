import Foundation
import XCTest

@testable import MemoryClip

/// Choosing a destination out of stored settings, and the two failures the
/// user actually meets: a destination that was never finished being configured,
/// and Notes refusing the Apple event.
///
/// Nothing here writes a note — `NoteSinkFactory` is the layer that reads
/// configuration, and every error it can throw is a sentence the user is shown
/// verbatim in an alert.
final class NoteSinkConfigurationTests: XCTestCase {
    /// An immutable `let` plus computed accessors, rather than vars assigned in
    /// `setUp`: XCTest's overrides are nonisolated, and this keeps them free of
    /// mutable state entirely.
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NoteSinkConfigurationTests-\(UUID().uuidString)", isDirectory: true)
    private let suiteName = "NoteSinkConfigurationTests-\(UUID().uuidString)"

    private var vault: URL { root.appendingPathComponent("Vault", isDirectory: true) }
    /// A suite of its own, so nothing here can read — or leave behind — a
    /// value in the user's real defaults.
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    /// The vault bookmark is the one setting the factory does NOT read from the
    /// injected defaults: `FolderBookmark` is backed by `UserDefaults.standard`.
    /// It is put back exactly as found, so running these tests cannot cost a
    /// developer the folder they picked.
    private var savedVaultBookmark: Data?

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        savedVaultBookmark = UserDefaults.standard.data(forKey: NoteSettingsKeys.vaultBookmark)
        FolderBookmark.clear(key: NoteSettingsKeys.vaultBookmark)
    }

    override func tearDownWithError() throws {
        if let savedVaultBookmark {
            UserDefaults.standard.set(savedVaultBookmark, forKey: NoteSettingsKeys.vaultBookmark)
        } else {
            FolderBookmark.clear(key: NoteSettingsKeys.vaultBookmark)
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSink(for destination: NoteDestination) throws -> any NoteSink {
        try NoteSinkFactory.make(for: destination, defaults: defaults)
    }

    private func assertNoteError(
        _ expected: NoteError,
        making destination: NoteDestination,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try makeSink(for: destination), file: file, line: line) { error in
            XCTAssertEqual(error as? NoteError, expected, file: file, line: line)
        }
    }

    // MARK: - Unconfigured destinations

    func testAMarkdownVaultWithNoFolderChosenIsUnconfigured() {
        // No bookmark and an unresolvable bookmark are the same story for the
        // user, and the factory cannot tell them apart anyway.
        assertNoteError(.noDestinationConfigured(.markdownVault), making: .markdownVault)
    }

    func testAShortcutWithNoNameIsUnconfigured() {
        // Registered as "" on purpose: there is no sensible default Shortcut,
        // so this destination is unusable until the user names one.
        assertNoteError(.noDestinationConfigured(.shortcut), making: .shortcut)

        defaults.set("   \n ", forKey: NoteSettingsKeys.shortcutName)
        assertNoteError(.noDestinationConfigured(.shortcut), making: .shortcut)
    }

    func testANotesFolderThatIsBlankIsUnconfigured() {
        defaults.set("  ", forKey: NoteSettingsKeys.notesAppFolder)
        assertNoteError(.noDestinationConfigured(.notesApp), making: .notesApp)
    }

    func testEveryConfigurationErrorNamesTheFix() {
        // These strings are shown verbatim in an alert, and an error that does
        // not say where to go leaves the user with a note that never appears
        // and no idea why.
        for error: NoteError in [
            .noDestinationConfigured(.markdownVault),
            .noDestinationConfigured(.notesApp),
            .noDestinationConfigured(.shortcut),
            .folderUnavailable("/Volumes/Gone/Vault"),
        ] {
            let description = error.errorDescription ?? ""
            XCTAssertTrue(description.contains("Settings"), "\(error) does not name Settings: \(description)")
        }
        XCTAssertTrue(
            NoteError.automationDenied.errorDescription?.contains("System Settings") == true,
            "a denied Automation grant can only be fixed in System Settings"
        )
    }

    // MARK: - Configured destinations

    func testAConfiguredShortcutReturnsASinkThatKnowsItsName() throws {
        defaults.set("  Save to Bear  ", forKey: NoteSettingsKeys.shortcutName)
        let sink = try makeSink(for: .shortcut)
        // Trimmed here rather than at the `shortcuts run` call site, so the
        // name a user pasted with a stray space still matches a real Shortcut.
        XCTAssertEqual((sink as? ShortcutSink)?.shortcutName, "Save to Bear")
    }

    func testAConfiguredNotesFolderReturnsASink() throws {
        defaults.set("MemoryClip", forKey: NoteSettingsKeys.notesAppFolder)
        let sink = try makeSink(for: .notesApp)
        XCTAssertEqual((sink as? NotesAppSink)?.folderName, "MemoryClip")
    }

    func testAConfiguredVaultReturnsASinkCarryingItsAttachmentSettings() throws {
        XCTAssertTrue(FolderBookmark.store(vault, key: NoteSettingsKeys.vaultBookmark))
        defaults.set("images", forKey: NoteSettingsKeys.vaultAttachmentFolder)
        defaults.set(true, forKey: NoteSettingsKeys.copyAttachments)
        defaults.set(true, forKey: NoteSettingsKeys.vaultDateFolders)

        let sink = try XCTUnwrap(try makeSink(for: .markdownVault) as? MarkdownVaultSink)
        XCTAssertEqual(sink.vaultURL.standardizedFileURL.path, vault.standardizedFileURL.path)
        XCTAssertEqual(sink.attachmentFolderName, "images")
        XCTAssertTrue(sink.copyAttachments)
        XCTAssertTrue(sink.useDateFolders)
    }

    func testTurningDatedFoldersOffReachesTheSink() throws {
        // The one setting whose off state has to be honoured exactly: it is
        // what a user picks when their tool cannot walk subfolders.
        XCTAssertTrue(FolderBookmark.store(vault, key: NoteSettingsKeys.vaultBookmark))
        defaults.set(false, forKey: NoteSettingsKeys.vaultDateFolders)

        let sink = try XCTUnwrap(try makeSink(for: .markdownVault) as? MarkdownVaultSink)
        XCTAssertFalse(sink.useDateFolders)
    }

    func testAVaultWithNoAttachmentFolderStoredFallsBackToTheDefaultName() throws {
        // An unregistered key must not become an attachment folder named "",
        // which would scatter screenshots into the vault root.
        XCTAssertTrue(FolderBookmark.store(vault, key: NoteSettingsKeys.vaultBookmark))
        let sink = try XCTUnwrap(try makeSink(for: .markdownVault) as? MarkdownVaultSink)
        XCTAssertEqual(sink.attachmentFolderName, MarkdownVaultSink.defaultAttachmentFolderName)
    }

    // MARK: - Apple event errors

    private func scriptError(number: Int?, message: String?) -> NSDictionary {
        let info = NSMutableDictionary()
        if let number { info[NSAppleScript.errorNumber] = NSNumber(value: number) }
        if let message { info[NSAppleScript.errorMessage] = message }
        return info
    }

    func testADeniedAutomationPromptIsItsOwnError() {
        // -1743 is errAEEventNotPermitted: macOS remembers the refusal and
        // never asks again, so this is the only code with a remedy of its own
        // — retrying is pointless, the user has to open System Settings.
        let error = NotesAppSink.noteError(
            fromScriptError: scriptError(
                number: -1743,
                message: "Not authorized to send Apple events to Notes."
            )
        )
        XCTAssertEqual(error, .automationDenied)
    }

    func testNotesBeingUnreachableCarriesItsCode() {
        // The number is the only thing that makes a support conversation
        // possible, so it survives into the message.
        for code in [-600, -1728] {
            let error = NotesAppSink.noteError(
                fromScriptError: scriptError(number: code, message: "Notes got an error.")
            )
            guard case .writeFailed(let reason) = error else {
                return XCTFail("\(code) should be a write failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("\(code)"), reason)
            XCTAssertTrue(reason.contains("Notes got an error."), reason)
        }
    }

    func testAnyOtherCodeCarriesTheScriptsOwnMessage() {
        // -2741 is a syntax error in the generated script; the mapping must not
        // swallow the one sentence that says what AppleScript objected to.
        let error = NotesAppSink.noteError(
            fromScriptError: scriptError(number: -2741, message: "  Expected end of line but found identifier.  ")
        )
        XCTAssertEqual(error, .writeFailed("Expected end of line but found identifier."))
    }

    func testAScriptErrorWithNoMessageStillNamesItsCode() {
        XCTAssertEqual(
            NotesAppSink.noteError(fromScriptError: scriptError(number: -1701, message: nil)),
            .writeFailed("AppleScript error -1701.")
        )
        // An error dictionary with neither field is possible, and "unknown" is
        // still better than an empty sentence after "could not be written:".
        XCTAssertEqual(
            NotesAppSink.noteError(fromScriptError: scriptError(number: nil, message: "   ")),
            .writeFailed("AppleScript error unknown.")
        )
    }
}
