import AppKit
import XCTest

@testable import MemoryClip

/// The per-app paste rules: what they store, which destinations they cover,
/// and the one direction they are allowed to move a paste in.
///
/// Every test here runs against a `UserDefaults` suite of its own, so nothing
/// can read — or leave behind — a rule in the developer's real defaults.
final class PlainPasteAppsTests: XCTestCase {
    /// An immutable `let` plus a computed accessor, matching the fixture the
    /// other defaults-backed suites use: XCTest's overrides are nonisolated,
    /// which keeps them free of mutable state.
    private let suiteName = "PlainPasteAppsTests-\(UUID().uuidString)"

    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }
    private var list: PlainPasteApps { PlainPasteApps(defaults: defaults) }

    /// The suite is torn down, and so is the seed.
    ///
    /// `register(defaults:)` fills one registration domain shared by every
    /// `UserDefaults` in the process, which no suite name isolates, so a test
    /// that seeds the list would otherwise seed the ones that run after it.
    /// Registering the empty array puts the key back where an unregistered one
    /// reads from — `stringArray` answers `[]` either way.
    override func tearDown() {
        UserDefaults.standard.register(defaults: [PlainPasteApps.bundleIDsKey: [String]()])
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - The rule

    func testAnUnseededListForcesNothing() {
        XCTAssertEqual(list.bundleIDs, [])
        XCTAssertFalse(list.forcesPlainText(requested: false, into: "com.apple.Terminal"))
    }

    func testAListedAppForcesPlainText() {
        list.add("com.example.editor")
        XCTAssertTrue(list.forcesPlainText(requested: false, into: "com.example.editor"))
    }

    func testAnUnlistedAppIsLeftRich() {
        list.add("com.example.editor")
        XCTAssertFalse(list.forcesPlainText(requested: false, into: "com.example.mail"))
    }

    /// The rule adds plainness and never removes it: ⇧Return into an app no
    /// rule covers still pastes plain.
    func testAnExplicitPlainPasteStaysPlainAnywhere() {
        XCTAssertTrue(list.forcesPlainText(requested: true, into: "com.example.mail"))
        XCTAssertTrue(list.forcesPlainText(requested: true, into: nil))
        list.add("com.example.editor")
        XCTAssertTrue(list.forcesPlainText(requested: true, into: "com.example.editor"))
    }

    /// A paste with no target app has no destination to have a rule about.
    func testNoTargetAppForcesNothing() {
        list.add("com.example.editor")
        XCTAssertFalse(list.forcesPlainText(requested: false, into: nil))
        XCTAssertFalse(list.forcesPlainText(requested: false, into: ""))
    }

    // MARK: - Matching

    /// Where the copy — and the paste — actually comes from in an Electron app
    /// is a helper process, so a listed app has to cover its children.
    func testHelperProcessesOfAListedAppAreCovered() {
        list.add("com.example.editor")
        XCTAssertTrue(list.forcesPlainText(requested: false, into: "com.example.editor.helper"))
        XCTAssertTrue(list.forcesPlainText(requested: false, into: "com.example.editor.helper.renderer"))
    }

    /// The anchoring that makes helpers work must not reach a sibling that
    /// merely starts with the same letters.
    func testASiblingIdentifierIsNotCovered() {
        list.add("com.example.editor")
        XCTAssertFalse(list.forcesPlainText(requested: false, into: "com.example.editorial"))
    }

    func testMatchingIgnoresCase() {
        list.add("com.example.Editor")
        XCTAssertTrue(list.forcesPlainText(requested: false, into: "COM.EXAMPLE.EDITOR"))
    }

    /// An app uninstalled after being listed leaves an identifier nothing on
    /// this Mac claims. The rule is still stored, still renders, and simply
    /// never matches a paste.
    func testAnIdentifierWithNoInstalledAppStillReadsBack() {
        list.add("com.example.gone")
        XCTAssertEqual(list.bundleIDs, ["com.example.gone"])
        let row = try? XCTUnwrap(list.apps.first)
        XCTAssertEqual(row?.bundleID, "com.example.gone")
        XCTAssertEqual(row?.isInstalled, false)
        XCTAssertEqual(row?.displayName, "com.example.gone")
    }

    // MARK: - Storage

    func testAddKeepsTheOrderAppsWereAddedIn() {
        list.add("com.example.first")
        list.add("com.example.second")
        XCTAssertEqual(list.bundleIDs, ["com.example.first", "com.example.second"])
    }

    func testDuplicateAddIsIdempotent() {
        XCTAssertTrue(list.add("com.example.editor"))
        XCTAssertFalse(list.add("com.example.editor"), "a second add must not report a change")
        XCTAssertEqual(list.bundleIDs, ["com.example.editor"])
    }

    func testDuplicateAddIgnoresCase() {
        list.add("com.example.Editor")
        XCTAssertFalse(list.add("COM.EXAMPLE.EDITOR"))
        XCTAssertEqual(list.bundleIDs, ["com.example.Editor"])
    }

    /// A child identifier is covered by its parent but is still a rule of its
    /// own, so adding it is an addition rather than a duplicate.
    func testAddingAChildOfAListedAppIsNotADuplicate() {
        list.add("com.example.editor")
        XCTAssertTrue(list.add("com.example.editor.helper"))
        XCTAssertEqual(list.bundleIDs, ["com.example.editor", "com.example.editor.helper"])
    }

    func testBlankIdentifierIsNotStored() {
        XCTAssertFalse(list.add("   "))
        XCTAssertEqual(list.bundleIDs, [])
    }

    func testRemoveTakesTheRuleOff() {
        list.add("com.example.editor")
        list.remove("com.example.editor")
        XCTAssertEqual(list.bundleIDs, [])
        XCTAssertFalse(list.forcesPlainText(requested: false, into: "com.example.editor"))
    }

    func testRemovingAnAppThatIsNotThereChangesNothing() {
        list.add("com.example.editor")
        list.remove("com.example.other")
        XCTAssertEqual(list.bundleIDs, ["com.example.editor"])
    }

    // MARK: - The shipped list

    func testRegisteredDefaultsSeedTheTerminalsAndEditors() {
        PlainPasteApps.registerDefaults(in: defaults)
        XCTAssertEqual(list.bundleIDs, PlainPasteApps.defaultBundleIDs)
        XCTAssertTrue(list.forcesPlainText(requested: false, into: "com.apple.Terminal"))
        XCTAssertTrue(list.forcesPlainText(requested: false, into: "com.microsoft.VSCode"))
    }

    /// The seed is a starting point, not a floor: removing a shipped entry has
    /// to stick, which it only does because the seed lives in the registration
    /// domain and the edit is written over it.
    func testAShippedAppCanBeRemoved() {
        PlainPasteApps.registerDefaults(in: defaults)
        list.remove("com.apple.Terminal")
        XCTAssertFalse(list.bundleIDs.contains("com.apple.Terminal"))
        XCTAssertFalse(list.forcesPlainText(requested: false, into: "com.apple.Terminal"))
        XCTAssertTrue(list.forcesPlainText(requested: false, into: "com.apple.dt.Xcode"))
    }

    func testEveryShippedIdentifierIsDistinct() {
        XCTAssertEqual(
            Set(PlainPasteApps.defaultBundleIDs.map { $0.lowercased() }).count,
            PlainPasteApps.defaultBundleIDs.count
        )
    }

    // MARK: - Clips the rule cannot change

    /// A clip carrying no formatting has nothing to strip, so a rule over its
    /// destination changes what reaches the pasteboard not at all.
    @MainActor
    func testANonRichClipPastesTheSameEitherWay() throws {
        for kind in [ClipKind.text, .link] {
            let item = ClipItem(kind: kind, text: "cd /tmp", contentHash: UUID().uuidString)
            XCTAssertEqual(
                PasteService.payload(for: item, plainOnly: true),
                PasteService.payload(for: item, plainOnly: false),
                "\(kind) must not depend on the plain-text rule"
            )
        }
    }
}
