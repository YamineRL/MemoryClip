import AppKit
import XCTest

@testable import MemoryClip

/// The user's own per-app exclusion list: what it stores, what it matches, and
/// what it does to an identifier whose app is no longer on the Mac.
///
/// Every test here runs against a `UserDefaults` suite of its own, so nothing
/// can read — or leave behind — an exclusion in the developer's real defaults.
final class ExcludedAppsTests: XCTestCase {
    /// An immutable `let` plus a computed accessor, matching the fixture the
    /// other defaults-backed suites use: XCTest's overrides are nonisolated,
    /// which keeps them free of mutable state.
    private let suiteName = "ExcludedAppsTests-\(UUID().uuidString)"

    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }
    private var list: ExcludedApps { ExcludedApps(defaults: defaults) }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Storage

    func testAFreshListIsEmpty() {
        XCTAssertEqual(list.bundleIDs, [])
        XCTAssertFalse(list.contains("com.apple.Safari"))
    }

    func testAddedAppIsExcluded() {
        XCTAssertTrue(list.add("com.example.tool"))
        XCTAssertEqual(list.bundleIDs, ["com.example.tool"])
        XCTAssertTrue(list.contains("com.example.tool"))
    }

    func testAddKeepsTheOrderAppsWereAddedIn() {
        list.add("com.example.first")
        list.add("com.example.second")
        XCTAssertEqual(list.bundleIDs, ["com.example.first", "com.example.second"])
    }

    func testDuplicateAddIsIdempotent() {
        XCTAssertTrue(list.add("com.example.tool"))
        XCTAssertFalse(list.add("com.example.tool"), "a second add must not report a change")
        XCTAssertEqual(list.bundleIDs, ["com.example.tool"])
    }

    func testDuplicateAddIgnoresCase() {
        list.add("com.example.Tool")
        XCTAssertFalse(list.add("COM.EXAMPLE.TOOL"))
        XCTAssertEqual(list.bundleIDs, ["com.example.Tool"])
    }

    func testBlankIdentifierIsNotStored() {
        XCTAssertFalse(list.add("   "))
        XCTAssertEqual(list.bundleIDs, [])
    }

    func testSurroundingWhitespaceIsTrimmed() {
        list.add("  com.example.tool\n")
        XCTAssertEqual(list.bundleIDs, ["com.example.tool"])
    }

    func testRemoveTakesTheAppOffTheList() {
        list.add("com.example.tool")
        list.remove("com.example.tool")
        XCTAssertEqual(list.bundleIDs, [])
        XCTAssertFalse(list.contains("com.example.tool"))
    }

    func testRemovingAnAppThatIsNotThereChangesNothing() {
        list.add("com.example.tool")
        list.remove("com.example.other")
        XCTAssertEqual(list.bundleIDs, ["com.example.tool"])
    }

    func testRemoveIgnoresCase() {
        list.add("com.example.Tool")
        list.remove("com.example.TOOL")
        XCTAssertEqual(list.bundleIDs, [])
    }

    func testAValueOfTheWrongTypeReadsAsAnEmptyList() {
        // A corrupted preference must not take capture down with it.
        defaults.set("com.example.tool", forKey: ExcludedApps.bundleIDsKey)
        XCTAssertEqual(list.bundleIDs, [])
        XCTAssertFalse(list.contains("com.example.tool"))
    }

    // MARK: - Matching

    func testHelperProcessOfAnExcludedAppIsExcluded() {
        list.add("com.example.tool")
        XCTAssertTrue(list.contains("com.example.tool.helper"))
    }

    func testSiblingIdentifierSharingAPrefixIsNotExcluded() {
        list.add("com.example.tool")
        XCTAssertFalse(list.contains("com.example.toolbox"))
    }

    func testMatchingIgnoresCase() {
        list.add("com.example.tool")
        XCTAssertTrue(list.contains("COM.EXAMPLE.TOOL"))
    }

    func testAnUnknownSourceIsNeverExcluded() {
        list.add("com.example.tool")
        XCTAssertFalse(list.contains(nil))
        XCTAssertFalse(list.contains(""))
    }

    // MARK: - Rows

    func testAnAppThatIsNoLongerInstalledStillRendersAsARow() throws {
        let stale = "com.example.uninstalled-\(UUID().uuidString)"
        list.add(stale)
        let row = try XCTUnwrap(list.apps.first)
        XCTAssertEqual(row.bundleID, stale)
        XCTAssertNil(row.url)
        XCTAssertFalse(row.isInstalled)
        XCTAssertEqual(row.displayName, stale, "a stale row has only its identifier to be named by")
    }

    func testAnInstalledAppResolvesToItsFinderName() throws {
        let finder = ExcludedApp(bundleID: "com.apple.finder")
        XCTAssertTrue(finder.isInstalled)
        XCTAssertNotEqual(finder.displayName, finder.bundleID, "an installed app is named, not identified")
        XCTAssertFalse(finder.displayName.isEmpty)
    }

    func testRowsFollowTheStoredOrder() {
        list.add("com.example.first")
        list.add("com.example.second")
        XCTAssertEqual(list.apps.map(\.id), ["com.example.first", "com.example.second"])
    }

    // MARK: - Composition with the built-in credential list

    /// `isFilteringEnabled` reads the standard defaults, so the switch is set
    /// explicitly and put back as found.
    private func withFiltering(_ enabled: Bool, _ body: () -> Void) {
        let key = SensitiveFilter.filteringEnabledKey
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    func testBuiltInCredentialListStillAppliesWithAnEmptyUserList() {
        withFiltering(true) {
            XCTAssertEqual(list.bundleIDs, [], "precondition: nothing excluded by the user")
            XCTAssertTrue(
                SensitiveFilter.isExcludedSource(
                    bundleID: "com.1password.1password",
                    name: "1Password",
                    userExclusions: list
                )
            )
        }
    }

    func testOrdinaryAppIsNotExcludedByEither() {
        withFiltering(true) {
            XCTAssertFalse(
                SensitiveFilter.isExcludedSource(
                    bundleID: "com.apple.Safari",
                    name: "Safari",
                    userExclusions: list
                )
            )
        }
    }

    func testUserExclusionAppliesToAnAppTheBuiltInListNeverHeardOf() {
        list.add("com.apple.Safari")
        withFiltering(true) {
            XCTAssertTrue(
                SensitiveFilter.isExcludedSource(
                    bundleID: "com.apple.Safari",
                    name: "Safari",
                    userExclusions: list
                )
            )
        }
    }

    func testUserExclusionSurvivesTheSensitiveFilterBeingTurnedOff() {
        list.add("com.apple.Safari")
        withFiltering(false) {
            XCTAssertTrue(
                SensitiveFilter.isExcludedSource(
                    bundleID: "com.apple.Safari",
                    name: "Safari",
                    userExclusions: list
                ),
                "an app the user named is not a guess the filter switch takes back"
            )
            XCTAssertFalse(
                SensitiveFilter.isExcludedSource(
                    bundleID: "com.1password.1password",
                    name: "1Password",
                    userExclusions: list
                ),
                "the built-in list is a guess, and the switch is how it is declined"
            )
        }
    }
}

/// The exclusion list through the real capture path, which is where it has to
/// hold: an excluded app's copy must never reach the store at all.
@MainActor
final class ExcludedAppCaptureTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []
    /// The developer's own exclusions, put back exactly as found — the watcher
    /// reads `UserDefaults.standard` and there is no seam to inject past it.
    private var savedExclusions: Any?
    private var savedFiltering: Any?

    override func setUp() {
        super.setUp()
        savedExclusions = UserDefaults.standard.object(forKey: ExcludedApps.bundleIDsKey)
        savedFiltering = UserDefaults.standard.object(forKey: SensitiveFilter.filteringEnabledKey)
        UserDefaults.standard.set([String](), forKey: ExcludedApps.bundleIDsKey)
        UserDefaults.standard.set(true, forKey: SensitiveFilter.filteringEnabledKey)
        UserDefaults.standard.set(0, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
    }

    override func tearDown() {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        pasteboards = []
        restore(ExcludedApps.bundleIDsKey, savedExclusions)
        restore(SensitiveFilter.filteringEnabledKey, savedFiltering)
        super.tearDown()
    }

    private func restore(_ key: String, _ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func exclude(_ bundleID: String) {
        UserDefaults.standard.set([bundleID], forKey: ExcludedApps.bundleIDsKey)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("memoryclip-excluded-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func capture(
        _ pasteboard: NSPasteboard,
        into store: ClipStore,
        bundleID: String?,
        appName: String?
    ) -> Bool {
        let watcher = PasteboardWatcher(store: store, pasteboard: pasteboard)
        return watcher.capture(from: pasteboard, sourceBundleID: bundleID, sourceAppName: appName)
    }

    func testCopyFromAnExcludedAppNeverReachesTheStore() throws {
        exclude("com.example.internal-tool")
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        pasteboard.setString("an ordinary sentence", forType: .string)

        XCTAssertFalse(
            capture(pasteboard, into: store, bundleID: "com.example.internal-tool", appName: "Internal Tool")
        )
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testCopyFromAHelperOfAnExcludedAppNeverReachesTheStore() throws {
        exclude("com.example.internal-tool")
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        pasteboard.setString("an ordinary sentence", forType: .string)

        XCTAssertFalse(
            capture(pasteboard, into: store, bundleID: "com.example.internal-tool.helper", appName: "Internal Tool Helper")
        )
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testCopyFromAnAppThatIsNotExcludedIsCaptured() throws {
        exclude("com.example.internal-tool")
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        pasteboard.setString("hello", forType: .string)

        XCTAssertTrue(capture(pasteboard, into: store, bundleID: "com.apple.Safari", appName: "Safari"))
        XCTAssertEqual(store.recent(limit: 10).first?.text, "hello")
    }

    func testAnExclusionHoldsWithTheSensitiveFilterOff() throws {
        UserDefaults.standard.set(false, forKey: SensitiveFilter.filteringEnabledKey)
        exclude("com.example.internal-tool")
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        pasteboard.setString("an ordinary sentence", forType: .string)

        XCTAssertFalse(
            capture(pasteboard, into: store, bundleID: "com.example.internal-tool", appName: "Internal Tool")
        )
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testCredentialAppIsStillBlockedWithAnEmptyExclusionList() throws {
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        pasteboard.setString("hunter2", forType: .string)

        XCTAssertFalse(
            capture(pasteboard, into: store, bundleID: "com.1password.1password", appName: "1Password")
        )
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testAnIdentifierWhoseAppIsGoneStillBlocksCapture() throws {
        // The app was uninstalled after being excluded: nothing resolves the
        // identifier any more, and the exclusion is unaffected.
        let stale = "com.example.uninstalled-\(UUID().uuidString)"
        exclude(stale)
        XCTAssertFalse(ExcludedApp(bundleID: stale).isInstalled, "precondition: nothing claims this identifier")

        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        pasteboard.setString("an ordinary sentence", forType: .string)

        XCTAssertFalse(capture(pasteboard, into: store, bundleID: stale, appName: nil))
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }
}
