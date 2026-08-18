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
            granted: [.accessibility: old, .calendar: old, .notesAutomation: old],
            asked: [:],
            states: [.accessibility: .forgotten, .calendar: .forgotten, .notesAutomation: .forgotten],
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
            states: [.calendar: .forgotten, .notesAutomation: .forgotten, .accessibility: .forgotten],
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

    func testOnlyAccessibilityRefusesToPromptInPlace() {
        // The one permission macOS gives no way to ask for, which is why the
        // window has a second kind of button at all.
        XCTAssertFalse(RecoverablePermission.accessibility.canPromptInPlace)
        XCTAssertTrue(RecoverablePermission.calendar.canPromptInPlace)
        XCTAssertTrue(RecoverablePermission.notesAutomation.canPromptInPlace)
    }
}
