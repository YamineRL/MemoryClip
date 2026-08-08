import XCTest

@testable import MemoryClip

final class SettingsTests: XCTestCase {
    // MARK: AppVersionInfo

    func testDisplayStringCombinesVersionAndBuild() {
        let info = AppVersionInfo(shortVersion: "0.1.0", build: "1")
        XCTAssertTrue(info.isKnown, "a real version string should count as known")
        XCTAssertEqual(info.displayString, "Version 0.1.0 (1)")
    }

    func testMissingBuildOmitsParentheses() {
        let info = AppVersionInfo(shortVersion: "2.3", build: nil)
        XCTAssertEqual(info.build, AppVersionInfo.unknownVersion)
        XCTAssertEqual(info.displayString, "Version 2.3")
    }

    func testMissingVersionFallsBackToPlaceholder() {
        let info = AppVersionInfo(shortVersion: nil, build: "17")
        XCTAssertFalse(info.isKnown, "a missing short version must not count as known")
        XCTAssertEqual(info.shortVersion, AppVersionInfo.unknownVersion)
        XCTAssertEqual(info.displayString, "Version \(AppVersionInfo.unknownVersion)")
    }

    func testBlankValuesAreTreatedAsMissing() {
        let info = AppVersionInfo(shortVersion: "   ", build: "\n")
        XCTAssertFalse(info.isKnown, "whitespace-only values must be treated as missing")
        XCTAssertEqual(info.displayString, "Version \(AppVersionInfo.unknownVersion)")
    }

    func testValuesAreTrimmed() {
        let info = AppVersionInfo(shortVersion: " 1.0 ", build: " 42 ")
        XCTAssertEqual(info.displayString, "Version 1.0 (42)")
    }

    func testInitFromBundleNeverCrashesOutsideAnAppBundle() {
        // Under `swift test` there is no Info.plist; the fallback must hold.
        let info = AppVersionInfo(bundle: Bundle(for: SettingsTests.self))
        XCTAssertFalse(info.displayString.isEmpty, "the About tab must never show an empty version")
        XCTAssertTrue(
            info.displayString.hasPrefix("Version "),
            "expected a \"Version …\" string, got \"\(info.displayString)\""
        )
    }

    // MARK: ShortcutReference

    /// Structural invariants of the key reference. The exact wording and
    /// ordering of the rows is deliberately *not* asserted — editing the copy
    /// is not a regression, but an empty group, a duplicated key row, or a
    /// group missing from the Shortcuts tab is.
    func testShortcutReferenceIsWellFormed() {
        XCTAssertFalse(ShortcutReference.groups.isEmpty, "the Shortcuts tab would render empty")
        XCTAssertTrue(
            ShortcutReference.groups.contains(ShortcutReference.panel),
            "the panel group is not reachable from ShortcutReference.groups"
        )
        XCTAssertTrue(
            ShortcutReference.groups.contains(ShortcutReference.vim),
            "the vim group is not reachable from ShortcutReference.groups"
        )

        let titles = ShortcutReference.groups.map(\.title)
        XCTAssertEqual(
            Set(titles).count, titles.count,
            "group titles are the SwiftUI identity — duplicates break the list: \(titles)"
        )

        for group in ShortcutReference.groups {
            XCTAssertFalse(group.title.isEmpty, "a shortcut group has no title")
            XCTAssertFalse(group.entries.isEmpty, "\(group.title) has no entries")
            for entry in group.entries {
                XCTAssertFalse(entry.keys.isEmpty, "\(group.title) has a row with no keys")
                XCTAssertFalse(
                    entry.detail.isEmpty,
                    "\(group.title) row \"\(entry.keys)\" has no description"
                )
            }
            let keys = group.entries.map(\.keys)
            XCTAssertEqual(
                Set(keys).count, keys.count,
                "duplicate key rows in \(group.title): \(keys)"
            )
        }
    }

    /// The panel keys are handled inline in `PanelView`, so there is no state
    /// machine to check them against — this is the one place the reference is
    /// pinned to a literal list. The keys documented here must all be keys the
    /// panel actually consumes.
    func testPanelGroupListsTheKeysPanelViewHandles() {
        let keys = ShortcutReference.panel.entries.map(\.keys)
        XCTAssertEqual(
            keys, ["↑ ↓", "Return", "⇧Return", "⌘1…⌘9", "Space", "Esc"],
            "the panel key reference drifted from PanelView's key handling"
        )
        XCTAssertNil(
            ShortcutReference.panel.note,
            "the panel keys are unconditional; a note here implies a caveat that is not true"
        )
    }

    func testVimGroupCarriesTheSearchFieldCaveat() throws {
        // `try XCTUnwrap`, not `try?`: swallowing the error here would turn a
        // missing note into a silent pass on the very assertion below.
        let note = try XCTUnwrap(
            ShortcutReference.vim.note,
            "the vim group must explain that these keys only work outside the search field"
        )
        XCTAssertTrue(
            note.contains("search field"),
            "the vim caveat no longer mentions the search field: \(note)"
        )
    }

    // MARK: Vim reference ↔ state machine

    /// A documented key token (`j`, `⇧O`, `⌃d`, `gg`) resolved into something
    /// that can be fed to `VimNavigator`.
    private enum DocumentedVimKey {
        case single(Character, VimModifiers)
        /// A two-key sequence such as `gg` or `dd`.
        case sequence(Character, Character)
    }

    /// Keys the panel or the mode switch — not the navigation state machine —
    /// handles, so no command is expected for them.
    private static let nonNavigatorKeys: Set<String> = ["Esc", "Return", "Tab", "Space", "↑ ↓"]

    /// Splits a `ShortcutEntry.keys` string ("j / k", "/ or i", "dd") into its
    /// individual key tokens.
    private static func vimKeyTokens(in keys: String) -> [String] {
        keys.replacingOccurrences(of: " or ", with: " / ")
            .components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parses one token out of a `ShortcutEntry.keys` string. Returns nil for
    /// tokens the navigator is not expected to answer for.
    private static func parseVimKey(_ token: String) -> DocumentedVimKey? {
        var rest = Substring(token)
        guard !rest.isEmpty, !nonNavigatorKeys.contains(String(rest)) else { return nil }

        var modifiers: VimModifiers = []
        while let symbol = rest.first, symbol == "⌃" || symbol == "⇧" {
            // Shift is not a `VimModifiers` case: a shifted letter already
            // arrives as its uppercase character (⇧O → "O").
            if symbol == "⌃" { modifiers.insert(.control) }
            rest = rest.dropFirst()
        }

        guard rest.allSatisfy({ !$0.isWhitespace }) else { return nil }

        switch rest.count {
        case 1:
            return .single(rest[rest.startIndex], modifiers)
        case 2 where rest.first == rest.last:
            return .sequence(rest[rest.startIndex], rest[rest.startIndex])
        default:
            return nil
        }
    }

    /// Anti-drift, in both directions: every key documented in the Shortcuts
    /// tab must produce a command in `VimNavigator`, and every command the
    /// navigator can produce must be documented by some key.
    ///
    /// Derived from `ShortcutReference.vim` rather than a hardcoded key list,
    /// so it keeps testing the real bindings when they change.
    func testDocumentedVimKeysAreRealBindings() throws {
        let tokens = ShortcutReference.vim.entries.flatMap { Self.vimKeyTokens(in: $0.keys) }

        var produced: [VimCommand] = []
        var checked = 0

        for token in tokens {
            guard let key = Self.parseVimKey(token) else { continue }
            checked += 1
            var navigator = VimNavigator()

            switch key {
            case let .single(character, modifiers):
                let command = try XCTUnwrap(
                    navigator.command(for: character, modifiers: modifiers),
                    "documented key \"\(token)\" produces no command in VimNavigator"
                )
                produced.append(command)

            case let .sequence(first, second):
                XCTAssertNil(
                    navigator.command(for: first),
                    "\"\(token)\": the first keystroke should arm the sequence, not fire a command"
                )
                XCTAssertTrue(
                    navigator.hasPending,
                    "\"\(token)\": the first keystroke left no pending sequence"
                )
                let command = try XCTUnwrap(
                    navigator.command(for: second),
                    "documented sequence \"\(token)\" produces no command in VimNavigator"
                )
                produced.append(command)
            }
        }

        XCTAssertGreaterThanOrEqual(
            checked, 6,
            """
            only \(checked) of \(tokens.count) documented vim tokens were understood by this \
            test's parser — extend parseVimKey for the new notation instead of letting the \
            reference drift uncovered
            """
        )

        let mustBeDocumented: [(VimCommand, String)] = [
            (.down, "move down"), (.up, "move up"),
            (.top, "jump to top"), (.bottom, "jump to bottom"),
            (.halfPageDown, "half-page down"), (.halfPageUp, "half-page up"),
            (.paste, "paste"), (.pastePlain, "paste as plain text"),
            (.pin, "pin"), (.delete, "delete"),
            (.queueToggle, "queue a clip"), (.queuePaste, "paste the queue"),
            (.enterSearch, "start a fresh search"), (.enterInsert, "edit the current query")
        ]
        for (command, description) in mustBeDocumented {
            XCTAssertTrue(
                produced.contains(command),
                "no documented key produces \(command) (\(description)) — the Shortcuts tab is missing a binding"
            )
        }
    }
}
