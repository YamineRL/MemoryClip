import XCTest

@testable import MemoryClip

/// The once-per-cause rule and the wording of each failure banner. Nothing
/// here posts: the builders are pure and the ledger is a value.
final class FailureNoticeTests: XCTestCase {
    // MARK: Ledger

    func testACauseIsPostedOnlyTheFirstTime() {
        var ledger = NoticeLedger()
        XCTAssertTrue(ledger.shouldPost("translation.zh-TW"))
        XCTAssertFalse(ledger.shouldPost("translation.zh-TW"))
        XCTAssertFalse(ledger.shouldPost("translation.zh-TW"))
    }

    func testDifferentCausesAreEachPostedOnce() {
        var ledger = NoticeLedger()
        XCTAssertTrue(ledger.shouldPost("translation.zh-TW"))
        XCTAssertTrue(ledger.shouldPost("translation.ar"))
        XCTAssertTrue(ledger.shouldPost("capture.imageTooLarge"))
        XCTAssertEqual(ledger.posted, ["translation.zh-TW", "translation.ar", "capture.imageTooLarge"])
    }

    func testTranslationNoticesAreDeduplicatedPerLanguage() {
        var ledger = NoticeLedger()
        let chinese = FailureNotice.translationNeedsDownload(identifier: "zh-TW")
        let arabic = FailureNotice.translationNeedsDownload(identifier: "ar")
        XCTAssertTrue(ledger.shouldPost(chinese.key))
        XCTAssertTrue(ledger.shouldPost(arabic.key))
        XCTAssertFalse(ledger.shouldPost(FailureNotice.translationNeedsDownload(identifier: "zh-TW").key))
    }

    // MARK: Translation

    func testTranslationNoticeNamesTheLanguageInTheReadersLanguage() {
        let english = FailureNotice.translationNeedsDownload(identifier: "zh-TW", locale: Locale(identifier: "en"))
        XCTAssertTrue(english.body.contains("Chinese (Taiwan)"), english.body)
        XCTAssertFalse(english.body.contains("zh-TW"), english.body)

        let french = FailureNotice.translationNeedsDownload(identifier: "zh-TW", locale: Locale(identifier: "fr"))
        XCTAssertTrue(french.body.contains("chinois (Taïwan)"), french.body)
    }

    func testTranslationNoticeOpensTheTranslationPane() {
        let notice = FailureNotice.translationNeedsDownload(identifier: "ar")
        XCTAssertEqual(notice.destination, .settings(.translation))
        XCTAssertEqual(notice.title, loc("Clip not translated"))
    }

    // MARK: Notes

    func testANoteWithNothingToWriteIsNotAFailure() {
        XCTAssertNil(FailureNotice.noteExportFailed(.nothingToWrite))
    }

    func testANoteFailureSaysWhatToDoAndWhere() throws {
        let notice = try XCTUnwrap(FailureNotice.noteExportFailed(.noDestinationConfigured(.markdownVault)))
        XCTAssertEqual(notice.title, loc("Note not saved"))
        XCTAssertEqual(notice.body, NoteError.noDestinationConfigured(.markdownVault).localizedDescription)
        XCTAssertEqual(notice.destination, .settings(.notes))
    }

    func testRefusedAutomationOpensSystemSettings() throws {
        let notice = try XCTUnwrap(FailureNotice.noteExportFailed(.automationDenied))
        XCTAssertEqual(notice.destination, RecoverablePermission.notesAutomation.settingsURL.map { .systemSettings($0) })
    }

    /// The key is the kind of failure, never the path or message it carries.
    func testNoteFailuresOfOneKindShareAKey() {
        let first = FailureNotice.noteExportFailed(.folderUnavailable("/Users/a/Vault"))
        let second = FailureNotice.noteExportFailed(.folderUnavailable("/Users/b/Other"))
        XCTAssertEqual(first?.key, second?.key)
        XCTAssertFalse(first?.key.contains("/Users") ?? true)
    }

    // MARK: Calendar

    func testACreationAlreadyUnderwayIsNotAFailure() {
        XCTAssertNil(FailureNotice.calendarActionFailed(.alreadyInFlight, undo: false))
    }

    func testCalendarNoticesTellAddFromUndo() throws {
        let add = try XCTUnwrap(FailureNotice.calendarActionFailed(.noWritableCalendar, undo: false))
        let undo = try XCTUnwrap(FailureNotice.calendarActionFailed(.undoUnavailable, undo: true))
        XCTAssertEqual(add.title, loc("Couldn’t add the event"))
        XCTAssertEqual(undo.title, loc("Couldn’t undo the event"))
        XCTAssertEqual(add.body, CalendarError.noWritableCalendar.localizedDescription)
        XCTAssertNotEqual(add.key, undo.key)
    }

    func testDeniedCalendarAccessOpensSystemSettings() throws {
        let notice = try XCTUnwrap(FailureNotice.calendarActionFailed(.accessDenied, undo: false))
        XCTAssertEqual(notice.destination, RecoverablePermission.calendar.settingsURL.map { .systemSettings($0) })
    }

    // MARK: Capture and the rest

    func testImageNoticeStatesTheLimits() {
        let notice = FailureNotice.imageTooLarge(megabytes: 64, megapixels: 128)
        XCTAssertEqual(notice.body, loc("Images over %d MB or %d megapixels aren’t kept in history.", 64, 128))
        XCTAssertTrue(notice.body.contains("64"), notice.body)
        XCTAssertNil(notice.destination)
    }

    func testEveryFixedNoticeHasADistinctKeyAndShortTitle() {
        let notices: [FailureNotice] = [
            .appleIntelligenceOff,
            .secretNotKept,
            .screenshotFolderUnreachable,
            .screenshotAccessMissing,
            .appLockUnavailable,
            .historyNotPersisted,
            .updateDownloadFailed,
            .imageTooLarge(megabytes: 1, megapixels: 1),
            .translationNeedsDownload(identifier: "ar"),
        ]
        XCTAssertEqual(Set(notices.map(\.key)).count, notices.count)
        for notice in notices {
            XCTAssertLessThanOrEqual(notice.title.split(separator: " ").count, 5, notice.title)
            XCTAssertFalse(notice.body.isEmpty, notice.key)
        }
    }

    // MARK: Destination

    func testDestinationsSurviveTheTripThroughUserInfo() throws {
        let url = try XCTUnwrap(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"))
        let destinations: [FailureNotice.Destination] = SettingsPane.allCases.map { .settings($0) } + [.systemSettings(url)]
        for destination in destinations {
            XCTAssertEqual(FailureNotice.Destination(userInfoValue: destination.userInfoValue), destination)
        }
    }

    func testUnknownDestinationsAreIgnored() {
        XCTAssertNil(FailureNotice.Destination(userInfoValue: "settings:nowhere"))
        XCTAssertNil(FailureNotice.Destination(userInfoValue: "https://example.invalid"))
        XCTAssertNil(FailureNotice.Destination(userInfoValue: ""))
    }
}
