import SwiftUI
import XCTest

@testable import MemoryClip

final class SettingsTests: XCTestCase {
    // MARK: AppVersionInfo

    func testDisplayStringCombinesVersionAndBuild() {
        let info = AppVersionInfo(shortVersion: "0.1.0", build: "1")
        XCTAssertTrue(info.isKnown, "a real version string should count as known")
        XCTAssertEqual(info.displayString, "Version 0.1.0")
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
        XCTAssertEqual(info.displayString, "Version 1.0", "the build number is deliberately not shown")
    }

    func testInitFromBundleNeverCrashesOutsideAnAppBundle() {
        // Under `swift test` there is no Info.plist; the fallback must hold.
        let info = AppVersionInfo(bundle: Bundle(for: SettingsTests.self))
        XCTAssertFalse(info.displayString.isEmpty, "the About pane must never show an empty version")
        XCTAssertTrue(
            info.displayString.hasPrefix("Version "),
            "expected a \"Version …\" string, got \"\(info.displayString)\""
        )
    }

    // MARK: SettingsPane

    /// The sidebar is generated from `SettingsPane.groups`, so a pane that is
    /// in the enum but in no group is a pane with no way to reach it — the
    /// exact failure the tabbed version could not have, and the one this
    /// rebuild has to be held to.
    func testEveryPaneAppearsInExactlyOneSidebarGroup() {
        let listed = SettingsPane.groups.flatMap(\.panes)
        XCTAssertEqual(
            Set(listed).count, listed.count,
            "a pane is listed in two sidebar groups: \(listed.map(\.rawValue))"
        )
        XCTAssertEqual(
            Set(listed), Set(SettingsPane.allCases),
            "the sidebar and the pane list disagree — an unreachable or phantom pane"
        )
    }

    func testSidebarGroupsAreWellFormed() {
        XCTAssertFalse(SettingsPane.groups.isEmpty, "the sidebar would render empty")
        for group in SettingsPane.groups {
            XCTAssertFalse(group.panes.isEmpty, "sidebar group \(group.id) has no rows")
            if let title = group.title {
                XCTAssertFalse(title.isEmpty, "a sidebar group has an empty title")
            }
        }
        let ids = SettingsPane.groups.map(\.id)
        XCTAssertEqual(
            Set(ids).count, ids.count,
            "group ids are the SwiftUI identity — duplicates break the sidebar: \(ids)"
        )
    }

    /// Notes, Calendar and Translation each act on any clip whatever captured
    /// it, and each send it somewhere outside MemoryClip. Filing any of them
    /// under Clipboard (where clips arrive) or beside the screenshot capture
    /// settings claims a loyalty they do not have.
    func testTheThreeClipActionsShareOneGroup() throws {
        let group = try XCTUnwrap(
            SettingsPane.groups.first { $0.title == "Clip actions" },
            "the Clip actions group is not in the sidebar at all"
        )
        XCTAssertEqual(
            group.panes, [.notes, .calendar, .translation],
            "the two keystroke-invoked actions lead, and the automatic one follows"
        )
    }

    /// The panes a clip passes through on its way in, in that order. Nothing
    /// that writes a clip out belongs here.
    func testClipboardGroupHoldsCaptureAndBrowsing() throws {
        let group = try XCTUnwrap(
            SettingsPane.groups.first { $0.title == "Clipboard" },
            "the Clipboard group is not in the sidebar at all"
        )
        XCTAssertEqual(group.panes, [.history, .screenshots, .panel, .privacy])
    }

    /// General is the app as an app: neither row is about a particular clip.
    func testGeneralGroupHoldsOnlyTheAppItself() throws {
        let group = try XCTUnwrap(
            SettingsPane.groups.first { $0.title == "General" },
            "the General group is not in the sidebar at all"
        )
        XCTAssertEqual(group.panes, [.general, .shortcuts])
    }

    /// Titles and symbols are what a row *is*: a blank one renders an
    /// unlabelled row, and a shared one makes two panes look like each other
    /// in a sidebar whose whole job is telling them apart.
    func testPaneTitlesAndSymbolsAreDistinctAndPresent() {
        for pane in SettingsPane.allCases {
            XCTAssertFalse(pane.title.isEmpty, "\(pane.rawValue) has no title")
            XCTAssertFalse(pane.symbol.isEmpty, "\(pane.rawValue) has no symbol")
        }
        let titles = SettingsPane.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two panes share a title: \(titles)")
        let symbols = SettingsPane.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "two panes share a glyph: \(symbols)")
    }

    /// `SettingsPane.default` is what `@AppStorage` falls back to, and the
    /// window should open on the row the sidebar shows first — not on some
    /// pane further down that happens to be case zero of the enum.
    func testDefaultPaneIsTheFirstSidebarRow() {
        let first = SettingsPane.groups.first?.panes.first
        XCTAssertEqual(
            first, SettingsPane.default,
            "the default pane is not the top row of the sidebar"
        )
    }

    /// The raw values are the persisted form. Changing one silently resets
    /// every user who had that pane open, so they are pinned here.
    func testPaneRawValuesAreStable() {
        XCTAssertEqual(
            SettingsPane.allCases.map(\.rawValue),
            [
                "general", "shortcuts", "history", "panel", "privacy",
                "screenshots", "notes", "translation", "calendar", "about"
            ],
            "a persisted pane identifier changed — see SettingsKeys.settingsPane"
        )
    }

    /// Adding `translation` is only safe if every raw value that could already
    /// be on disk still resolves to the pane it named. Translation used to be
    /// a section of the Notes pane, so the users most likely to have
    /// `"notes"` stored are exactly the ones this move affects, and landing
    /// them anywhere else would look like the setting had been lost rather
    /// than relocated.
    func testStoredRawValuesStillResolveToTheirPane() {
        XCTAssertEqual(SettingsPane(rawValue: "notes"), .notes, "a stored Notes selection must still open Notes")
        XCTAssertEqual(SettingsPane(rawValue: "translation"), .translation)
        for pane in SettingsPane.allCases {
            XCTAssertEqual(
                SettingsPane(rawValue: pane.rawValue), pane,
                "\(pane.rawValue) does not round-trip through its persisted form"
            )
        }
    }

    /// `@AppStorage` decodes an unrecognised raw value as `nil` and takes the
    /// declared default, which is what makes a build that drops a pane — or
    /// one read by an older build that has never heard of `translation` —
    /// open on General instead of on nothing.
    func testUnknownStoredPaneFallsBackToTheDefault() {
        XCTAssertNil(SettingsPane(rawValue: "somePaneThisBuildNeverHad"))
        XCTAssertEqual(SettingsPane.default, .general, "the fallback pane moved; check SettingsView's @AppStorage default")
    }

    /// The tint is the sidebar's fastest cue — you know the row by its colour
    /// before you have read it — so two panes wearing one colour costs the
    /// sidebar the distinction it is tinted for. Compared as rendered colours
    /// rather than by case, since that is what the eye gets.
    func testPaneTintsAreDistinct() {
        let tints = SettingsPane.allCases.map(\.tint)
        XCTAssertEqual(
            Set(tints).count, tints.count,
            "two panes share a sidebar tint: \(SettingsPane.allCases.map(\.rawValue))"
        )
    }

    // MARK: ShortcutReference

    /// Structural invariants of the key reference. The exact wording and
    /// ordering of the rows is deliberately *not* asserted — editing the copy
    /// is not a regression, but an empty group, a duplicated key row, or a
    /// group missing from the Shortcuts pane is.
    func testShortcutReferenceIsWellFormed() {
        XCTAssertFalse(ShortcutReference.groups.isEmpty, "the Shortcuts pane would render empty")
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
    /// machine to check them against.
    ///
    /// The assertion is *coverage*, not an exact transcript. Pinning the row
    /// list verbatim is what let this pane go stale in the first place: every
    /// key the panel grew — the arrows along the strip, ⌘S, ⌘W, Quick Look —
    /// was added to `PanelView` without the frozen list here noticing, because
    /// a list only fails when someone edits the rows, and nobody was. Asking
    /// instead that each key `PanelView` consumes appears *somewhere* in the
    /// group fails on the omission itself, and leaves rewording, reordering
    /// and merging rows free.
    func testPanelGroupDocumentsTheKeysPanelViewHandles() throws {
        let entries = ShortcutReference.panel.entries
        let documented = entries.map(\.keys).joined(separator: "\u{1F}")
        for key in ["↑", "↓", "←", "→", "Return", "⇧Return", "⌘1…⌘9", "⌘C", "⌘S", "⌘E", "Space", "Esc", "⌘W"] {
            XCTAssertTrue(
                documented.contains(key),
                "\(key) is handled by PanelView but has no row in the panel key reference"
            )
        }

        // Space is the one key whose row has to carry a branch: since Quick
        // Look landed it escalates rather than toggling, and a row that still
        // says "toggle" is wrong on exactly the screenshots and files people
        // press it on. Esc is the same ladder coming back down.
        let space = try XCTUnwrap(
            entries.first { $0.keys == "Space" },
            "no Space row to check for the Quick Look rung"
        )
        XCTAssertTrue(
            space.detail.contains("Quick Look"),
            "Space escalates into Quick Look, and its row does not say so: \(space.detail)"
        )
        XCTAssertFalse(
            space.detail.lowercased().contains("toggle"),
            "Space stopped toggling the preview when Quick Look landed: \(space.detail)"
        )
        let escape = try XCTUnwrap(
            entries.first { $0.keys == "Esc" },
            "no Esc row to check for the Quick Look rung"
        )
        XCTAssertTrue(
            escape.detail.contains("Quick Look"),
            "Esc now closes Quick Look first, and its row does not say so: \(escape.detail)"
        )

        XCTAssertNil(
            ShortcutReference.panel.note,
            """
            the panel's caveats are per-key — the movement arrows and Space stand down while \
            there is a query to edit, the rest never do — so they belong on their rows, not in \
            a note the whole group would appear to inherit
            """
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
    ///
    /// `h` and `l` are here for the same reason the arrows are: `PanelView`
    /// answers them itself, so `VimNavigator` has no binding to unwrap.
    private static let nonNavigatorKeys: Set<String> = [
        "Esc", "Return", "Tab", "Space", "↑ ↓", "← →", "h", "l"
    ]

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
                "no documented key produces \(command) (\(description)) — the Shortcuts pane is missing a binding"
            )
        }
    }
}
