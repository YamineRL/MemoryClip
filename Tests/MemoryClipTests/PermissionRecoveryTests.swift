import Foundation
import XCTest

@testable import MemoryClip

/// Which permissions an update cost the user, and which are none of this
/// feature's business.
///
/// The decision is pure — a ledger, a set of states and the running build's
/// identity — so all of it is checkable without a TCC database, an app bundle
/// or a window server, none of which the test machines have.
final class PermissionRecoveryTests: XCTestCase {
    private let old = "cdhash-of-the-previous-build"
    private let new = "cdhash-of-the-installed-build"

    // MARK: What is offered

    func testAGrantLostToAnUpdateIsOffered() {
        let lost = PermissionRecovery.lost(
            granted: [.calendar: old],
            asked: [:],
            states: [.calendar: .forgotten],
            identity: new
        )
        XCTAssertEqual(lost, [.calendar])
    }

    func testARefusalCarriedOverFromAnEarlierBuildIsOffered() {
        // Refused rather than forgotten still gets a row: the button opens the
        // pane holding the switch, which is the only place it can be undone.
        let lost = PermissionRecovery.lost(
            granted: [.notesAutomation: old],
            asked: [:],
            states: [.notesAutomation: .denied],
            identity: new
        )
        XCTAssertEqual(lost, [.notesAutomation])
    }

    func testEveryLostGrantIsOfferedInADeterminedOrder() {
        let lost = PermissionRecovery.lost(
            granted: [.accessibility: old, .calendar: old, .notesAutomation: old, .filesAndFolders: old],
            asked: [:],
            states: [
                .accessibility: .forgotten,
                .calendar: .forgotten,
                .notesAutomation: .forgotten,
                .filesAndFolders: .forgotten,
            ],
            identity: new
        )
        // Dictionaries do not keep an order; the window must not reshuffle its
        // rows between launches, so the enum's own order is what decides.
        XCTAssertEqual(lost, RecoverablePermission.allCases)
    }

    // MARK: What is not

    func testAPermissionThatStillWorksIsNotOffered() {
        let lost = PermissionRecovery.lost(
            granted: [.calendar: old],
            asked: [:],
            states: [.calendar: .granted],
            identity: new
        )
        XCTAssertTrue(lost.isEmpty)
    }

    func testAPermissionThatWasNeverGrantedIsNotOffered() {
        // A feature the user has never used is not a loss to repair, and
        // offering it would be MemoryClip asking for access it was not given.
        let lost = PermissionRecovery.lost(
            granted: [:],
            asked: [:],
            states: [
                .calendar: .forgotten,
                .notesAutomation: .forgotten,
                .filesAndFolders: .forgotten,
                .accessibility: .forgotten,
            ],
            identity: new
        )
        XCTAssertTrue(lost.isEmpty)
    }

    func testAPermissionTurnedOffUnderThisBuildIsNotOffered() {
        // Revoked by hand in System Settings, with no update in between: the
        // user made that decision minutes ago and does not need it questioned.
        let lost = PermissionRecovery.lost(
            granted: [.accessibility: new],
            asked: [:],
            states: [.accessibility: .forgotten],
            identity: new
        )
        XCTAssertTrue(lost.isEmpty)
    }

    func testAPermissionAlreadyOfferedUnderThisBuildIsNotOfferedAgain() {
        let lost = PermissionRecovery.lost(
            granted: [.calendar: old],
            asked: [.calendar: new],
            states: [.calendar: .forgotten],
            identity: new
        )
        XCTAssertTrue(lost.isEmpty, "one offer per update, not one per launch")
    }

    func testAnOfferMadeBeforeTheUpdateDoesNotSuppressTheNewOne() {
        let lost = PermissionRecovery.lost(
            granted: [.calendar: "two-builds-ago"],
            asked: [.calendar: old],
            states: [.calendar: .forgotten],
            identity: new
        )
        XCTAssertEqual(lost, [.calendar], "a further update is a fresh loss")
    }

    func testAnUncheckablePermissionIsNotOffered() {
        // Notes not installed, or the service turned off by a profile: there
        // is no grant here for the user to restore.
        let lost = PermissionRecovery.lost(
            granted: [.notesAutomation: old],
            asked: [:],
            states: [.notesAutomation: .unavailable],
            identity: new
        )
        XCTAssertTrue(lost.isEmpty)
    }

    func testAPermissionWithNoReadingIsNotOffered() {
        let lost = PermissionRecovery.lost(
            granted: [.calendar: old],
            asked: [:],
            states: [:],
            identity: new
        )
        XCTAssertTrue(lost.isEmpty, "a state that could not be read is not a loss")
    }

    // MARK: A switched-on feature that cannot run

    func testAnAutomaticEventSwitchWithNoCalendarAccessIsOffered() {
        let blocked = PermissionRecovery.blocked(
            states: [.calendar: .forgotten],
            createsEventsAutomatically: true,
            writesToNotesApp: false,
            usesAFolder: false
        )
        XCTAssertEqual(blocked, [.calendar])
    }

    func testNotesAsTheDestinationWithNoAutomationIsOffered() {
        let blocked = PermissionRecovery.blocked(
            states: [.notesAutomation: .denied],
            createsEventsAutomatically: false,
            writesToNotesApp: true,
            usesAFolder: false
        )
        XCTAssertEqual(blocked, [.notesAutomation])
    }

    func testAFeatureThatIsOffIsNotOffered() {
        let blocked = PermissionRecovery.blocked(
            states: [.calendar: .forgotten, .notesAutomation: .forgotten],
            createsEventsAutomatically: false,
            writesToNotesApp: false,
            usesAFolder: false
        )
        XCTAssertTrue(blocked.isEmpty, "a permission is only worth asking for once something needs it")
    }

    func testAFeatureThatWorksIsNotOffered() {
        let blocked = PermissionRecovery.blocked(
            states: [.calendar: .granted],
            createsEventsAutomatically: true,
            writesToNotesApp: false,
            usesAFolder: false
        )
        XCTAssertTrue(blocked.isEmpty)
    }

    func testAnUncheckableFeatureIsNotOffered() {
        let blocked = PermissionRecovery.blocked(
            states: [.notesAutomation: .unavailable],
            createsEventsAutomatically: false,
            writesToNotesApp: true,
            usesAFolder: false
        )
        XCTAssertTrue(blocked.isEmpty, "Notes not being installed is not a permission problem")
    }

    func testAccessibilityIsNeverOfferedThisWay() {
        // `autoPaste` defaults to on, so an Accessibility row here would open
        // this window for nearly every user on first launch.
        let blocked = PermissionRecovery.blocked(
            states: [.accessibility: .forgotten, .calendar: .forgotten],
            createsEventsAutomatically: true,
            writesToNotesApp: true,
            usesAFolder: true
        )
        XCTAssertFalse(blocked.contains(.accessibility))
    }

    // MARK: The folder the notes go to

    func testAWatchedScreenshotFolderMacOSWillNotOpenIsOffered() {
        // The folder the watcher falls back to when nothing was picked is
        // usually ~/Desktop, which macOS guards; the row has to cover it, or
        // the only thing that tells the user is a cold prompt at launch.
        let blocked = PermissionRecovery.blocked(
            states: [.filesAndFolders: .forgotten],
            createsEventsAutomatically: false,
            writesToNotesApp: false,
            usesAFolder: true
        )
        XCTAssertEqual(blocked, [.filesAndFolders])
    }

    func testAVaultMacOSWillNotOpenIsOffered() {
        // The case 0.4.0 shipped without: notes go to a Markdown folder, the
        // folder is under ~/Documents, and the update that installed the app
        // dropped the grant that let it write there.
        let blocked = PermissionRecovery.blocked(
            states: [.filesAndFolders: .forgotten],
            createsEventsAutomatically: false,
            writesToNotesApp: false,
            usesAFolder: true
        )
        XCTAssertEqual(blocked, [.filesAndFolders])
    }

    func testAVaultThatOpensIsNotOffered() {
        let blocked = PermissionRecovery.blocked(
            states: [.filesAndFolders: .granted],
            createsEventsAutomatically: false,
            writesToNotesApp: false,
            usesAFolder: true
        )
        XCTAssertTrue(blocked.isEmpty)
    }

    func testNoFolderPickedIsNotAPermissionProblem() {
        // Nothing chosen, so nothing to be refused: `.unavailable` is what the
        // probe reports, and there is no grant for the user to give.
        let blocked = PermissionRecovery.blocked(
            states: [.filesAndFolders: .unavailable],
            createsEventsAutomatically: false,
            writesToNotesApp: false,
            usesAFolder: true
        )
        XCTAssertTrue(blocked.isEmpty)
    }

    func testNotesGoingSomewhereElseDoNotAskForTheFolder() {
        let blocked = PermissionRecovery.blocked(
            states: [.filesAndFolders: .forgotten],
            createsEventsAutomatically: false,
            writesToNotesApp: true,
            usesAFolder: false
        )
        XCTAssertEqual(blocked, [], "a Markdown folder nobody writes to needs no permission")
    }

    func testAFolderGrantLostToAnUpdateIsOffered() {
        let lost = PermissionRecovery.lost(
            granted: [.filesAndFolders: old],
            asked: [:],
            states: [.filesAndFolders: .forgotten],
            identity: new
        )
        XCTAssertEqual(lost, [.filesAndFolders])
    }

    // MARK: The ledger

    func testTheLedgerRemembersWhatWorkedAndUnderWhichBuild() throws {
        let suite = "PermissionRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let ledger = PermissionLedger(defaults: defaults)

        XCTAssertTrue(ledger.granted.isEmpty)
        ledger.noteGranted(.calendar, identity: old)
        XCTAssertEqual(ledger.granted[.calendar], old)

        ledger.noteGranted(.calendar, identity: new)
        XCTAssertEqual(ledger.granted[.calendar], new, "the newest build that worked is the one recorded")

        ledger.forget(.calendar)
        XCTAssertNil(ledger.granted[.calendar])
    }

    func testTheLedgerAnswersWhetherThisBuildIsKnownToWork() throws {
        // The only Files and Folders question that can be answered without
        // putting a dialog on screen, which is why the launch path asks it.
        let suite = "PermissionRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let ledger = PermissionLedger(defaults: defaults)

        XCTAssertFalse(
            ledger.worksUnderThisBuild(.filesAndFolders, identity: new),
            "unknown counts as lost: the alternative is finding out by prompting"
        )
        ledger.noteGranted(.filesAndFolders, identity: old)
        XCTAssertFalse(ledger.worksUnderThisBuild(.filesAndFolders, identity: new))
        ledger.noteGranted(.filesAndFolders, identity: new)
        XCTAssertTrue(ledger.worksUnderThisBuild(.filesAndFolders, identity: new))
    }

    func testTheLedgerKeepsOffersApartFromGrants() throws {
        let suite = "PermissionRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let ledger = PermissionLedger(defaults: defaults)

        ledger.noteOffered(.accessibility, identity: new)
        XCTAssertEqual(ledger.asked[.accessibility], new)
        XCTAssertTrue(ledger.granted.isEmpty, "offering a permission is not being given it")
    }

    func testTheLedgerIgnoresEntriesItDoesNotUnderstand() throws {
        // A key written by a later version, read back by an earlier one.
        let suite = "PermissionRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(["screenRecording": new, "calendar": new], forKey: PermissionLedger.grantedKey)

        XCTAssertEqual(PermissionLedger(defaults: defaults).granted, [.calendar: new])
    }

    // MARK: What has already been offered

    func testAnOfferIsRememberedPerPermission() throws {
        let suite = "PermissionRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        XCTAssertTrue(PermissionRecoveryController.blockedOffers(defaults: defaults).isEmpty)
        PermissionRecoveryController.noteBlockedOffers([.calendar], defaults: defaults)
        XCTAssertEqual(PermissionRecoveryController.blockedOffers(defaults: defaults), [.calendar])
    }

    func testAnOfferMadeByTheOldFlagCoversOnlyWhatItCouldOffer() throws {
        // 0.4.0 wrote one boolean for the whole window, and could only ever
        // have shown these two. Reading it as "everything has been offered"
        // would silence the folder permission for exactly the users who lost
        // it — the ones who already ran 0.4.0.
        let suite = "PermissionRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PermissionRecoveryController.legacyBlockedOfferKey)

        let offered = PermissionRecoveryController.blockedOffers(defaults: defaults)
        XCTAssertEqual(offered, [.calendar, .notesAutomation])
        XCTAssertFalse(offered.contains(.filesAndFolders))
    }

    func testTheNewRecordWinsOverTheOldFlag() throws {
        let suite = "PermissionRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PermissionRecoveryController.legacyBlockedOfferKey)
        PermissionRecoveryController.noteBlockedOffers([.filesAndFolders], defaults: defaults)

        XCTAssertEqual(
            PermissionRecoveryController.blockedOffers(defaults: defaults),
            [.filesAndFolders],
            "the migration seeds the record once, it does not keep re-adding to it"
        )
    }

    // MARK: Identity

    func testTheRunningBuildHasAStableIdentity() {
        XCTAssertFalse(AppIdentity.current.isEmpty)
        XCTAssertEqual(AppIdentity.current, AppIdentity.resolve(), "identity must not change under the process")
    }

    // MARK: Rows

    func testEveryPermissionCanNameItselfAndThePaneThatHoldsIt() {
        for permission in RecoverablePermission.allCases {
            XCTAssertFalse(permission.title.isEmpty, "\(permission) has no title")
            XCTAssertFalse(permission.detail.isEmpty, "\(permission) does not say what it costs")
            XCTAssertFalse(permission.symbol.isEmpty, "\(permission) has no symbol")
            XCTAssertNotNil(permission.settingsURL, "\(permission) cannot open its System Settings pane")
        }
    }

    // MARK: The update offer

    func testTheUpdateCheckIsOfferedAfterAnUpdate() {
        // The one window whose readers all installed this version by hand
        // minutes ago, and the one place the offer follows from what is
        // already on screen.
        XCTAssertTrue(PermissionRecoveryView.offersUpdateCheck(for: .update))
    }

    func testTheUpdateCheckIsNotOfferedToAnyoneElse() {
        // Nothing on either of these windows is about updating, so the same
        // panel would be an upsell in a window opened to repair something.
        XCTAssertFalse(PermissionRecoveryView.offersUpdateCheck(for: .review))
        XCTAssertFalse(PermissionRecoveryView.offersUpdateCheck(for: .blocked))
    }

    func testOnlyAccessibilityRefusesToPromptInPlace() {
        // The one permission macOS gives no way to ask for, which is why the
        // window has a second kind of button at all.
        XCTAssertFalse(RecoverablePermission.accessibility.canPromptInPlace)
        XCTAssertTrue(RecoverablePermission.calendar.canPromptInPlace)
        XCTAssertTrue(RecoverablePermission.notesAutomation.canPromptInPlace)
        // The open panel is the ask, and it grants the folder outright.
        XCTAssertTrue(RecoverablePermission.filesAndFolders.canPromptInPlace)
    }
}
