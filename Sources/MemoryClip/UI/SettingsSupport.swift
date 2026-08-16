import SwiftUI

// MARK: - Settings navigation

/// One pane of the Settings window.
///
/// The raw values are *storage*, not labels: they are what
/// `SettingsKeys.settingsPane` persists, so renaming a case would silently
/// drop returning users back onto General.
///
/// Kept here, beside `ShortcutReference`, because it is the same kind of
/// thing — pure data the settings UI renders — and because a plain enum is
/// testable without standing up a view.
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general
    case shortcuts
    case history
    case panel
    case privacy
    case screenshots
    case notes
    case translation
    case about

    /// What opens when nothing has been chosen yet, and the fallback for a
    /// stored raw value this build no longer has a case for.
    static let `default`: SettingsPane = .general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .history: return "History"
        case .panel: return "Panel"
        case .privacy: return "Privacy"
        case .screenshots: return "Screenshots"
        case .notes: return "Notes"
        case .translation: return "Translation"
        case .about: return "About"
        }
    }

    /// The glyph a sidebar row and the pane's own header wear.
    ///
    /// Where a pane has a signature control the symbol is lifted straight off
    /// it — History's retention clock, Screenshots' camera — so the sidebar
    /// reads as an index of what is below rather than a second, unrelated
    /// icon set. The panes whose forms have no single defining row (General,
    /// Shortcuts, Panel, About) keep the symbol their old tab item used, which
    /// is the one users already associate with them.
    ///
    /// Translation is the Screenshots case again: its pane opens on the
    /// "Translate other languages into English" switch, and that switch's own
    /// glyph is what the sidebar row wears, so the row and the first thing
    /// under it are visibly the same control.
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "keyboard.fill"
        case .history: return "clock.arrow.circlepath"
        case .panel: return "rectangle.on.rectangle"
        case .privacy: return "lock.shield.fill"
        case .screenshots: return "camera.viewfinder"
        case .notes: return "note.text"
        case .translation: return "character.bubble.fill"
        case .about: return "info.circle.fill"
        }
    }

    /// The tile colour behind that glyph.
    ///
    /// Every pane gets a tint no other pane claims, because in a sidebar the
    /// colour is what you recognise before you have read the word. Where the
    /// pane already had a dominant tint inside its form the sidebar reuses it
    /// (History orange, Panel purple, Privacy pink, Screenshots green, Notes
    /// teal); the rest take what was left.
    ///
    /// Translation is the one pane that could not have the tint of its own
    /// signature control: that switch is pink and Privacy already owns pink,
    /// and two pink tiles in one sidebar undo the whole reason for tinting
    /// them. What was actually left is red, yellow, brown, mint and cyan, and
    /// only brown survives the two tests that matter at 20 points. Mint and
    /// cyan sit inside the green–teal–blue run that Screenshots, Notes and
    /// Shortcuts already occupy, and Translation lands next to Screenshots and
    /// Notes in the sidebar, which is the worst possible place to put a fourth
    /// shade of the same family. Red is the colour `SettingsCallout` uses for
    /// "something went wrong", and this pane shows two of those. Yellow is
    /// distinct enough but it is the one system colour a white glyph does not
    /// hold up against, and every tile here is a white glyph.
    ///
    /// System colours rather than literals, so macOS retunes them for Dark
    /// Mode and Increase Contrast — the same rule the rest of `Design` follows.
    var tint: Color {
        switch self {
        case .general: return Color(nsColor: .systemGray)
        case .shortcuts: return Color(nsColor: .systemBlue)
        case .history: return Color(nsColor: .systemOrange)
        case .panel: return Color(nsColor: .systemPurple)
        case .privacy: return Color(nsColor: .systemPink)
        case .screenshots: return Color(nsColor: .systemGreen)
        case .notes: return Color(nsColor: .systemTeal)
        case .translation: return Color(nsColor: .systemBrown)
        case .about: return Color(nsColor: .systemIndigo)
        }
    }
}

/// A titled run of sidebar rows.
struct SettingsPaneGroup: Identifiable, Sendable {
    /// `nil` renders as a plain separated run with no header — used for the
    /// two single trailing rows, where a one-word category name would be
    /// noise.
    let title: String?
    let panes: [SettingsPane]

    /// The title where there is one, and the rows themselves where there is
    /// not.
    ///
    /// This used to be a fixed `"untitled"` string, which was correct only
    /// while exactly one group had no header — as, today, is again the case.
    /// It is derived anyway, because two headerless groups sharing an id is
    /// not a cosmetic problem: the id is the `ForEach` identity the sidebar is
    /// built from, so SwiftUI would treat the second run as the first one
    /// moving and the rows would land in the wrong section. Deriving it means
    /// adding a second headerless group is a layout decision rather than a
    /// bug. The unit separator prefixes the derived form so that a headerless
    /// group can never collide with a group actually titled after its own
    /// pane.
    var id: String { title ?? ("\u{1F}" + panes.map(\.rawValue).joined(separator: "\u{1F}")) }
}

extension SettingsPane {
    /// The sidebar, grouped.
    ///
    /// Nine flat rows is a list you read top to bottom every time; grouped,
    /// you only read the group you are in. The split is by *what the user came
    /// to change*, not by which subsystem implements it:
    ///
    /// - **General** — the app as an app: whether it starts with the Mac, how
    ///   it looks, and the keys that summon it. Nothing here is about a
    ///   particular clip.
    /// - **Clipboard** — the core loop: what gets captured and for how long
    ///   (History), how the panel behaves while you browse it (Panel), and
    ///   what MemoryClip refuses to capture or requires Touch ID for
    ///   (Privacy). Privacy sits here rather than beside About because both
    ///   its switches are capture policy — they change what lands in history.
    /// - **Screenshots** — the screenshot → text → note pipeline, which is one
    ///   feature with an input (the watched folder) and an output (where notes
    ///   are written). Split across the sidebar it reads as two unrelated
    ///   panes; together, the order is the order the data flows.
    ///   Translation sits here too. It began as a section of the Notes pane,
    ///   back when it did one thing: render a foreign screenshot's recognised
    ///   text into English for the note being written. It has since grown a
    ///   second job — translating what you copy, shown in the panel's preview
    ///   — so it now spans the clipboard and the screenshot pipeline alike.
    ///   Filing it under either one would state a loyalty it does not have,
    ///   and a headerless row of its own says "uncategorised" when the truth
    ///   is "applies to all of it" — which is what General already means for
    ///   the rows beside it. It goes last in the group because the two above
    ///   it are about the app itself, and this one is about the clips.
    /// - About stands alone at the bottom, headerless. It is the one row that
    ///   changes nothing, and inventing a category for a single identity pane
    ///   would add a word to read without adding a distinction.
    static let groups: [SettingsPaneGroup] = [
        SettingsPaneGroup(title: "General", panes: [.general, .shortcuts, .translation]),
        SettingsPaneGroup(title: "Clipboard", panes: [.history, .panel, .privacy]),
        SettingsPaneGroup(title: "Screenshots", panes: [.screenshots, .notes]),
        SettingsPaneGroup(title: nil, panes: [.about])
    ]
}

/// App name/version strings for the About pane.
///
/// Pure value type so the assembly logic is testable without a bundle:
/// under `swift test` (and `swift run`) there is no `Info.plist`, so both
/// keys are missing and we fall back to a readable placeholder.
struct AppVersionInfo: Equatable {
    static let appName = "MemoryClip"
    /// Shown when the process has no Info.plist (tests, `swift run`).
    static let unknownVersion = "—"

    /// `CFBundleShortVersionString`, e.g. `0.1.0`.
    let shortVersion: String
    /// `CFBundleVersion`, e.g. `1`.
    let build: String

    /// Normalises the two raw Info.plist values, treating missing or
    /// blank entries as unknown.
    init(shortVersion: String?, build: String?) {
        self.shortVersion = Self.clean(shortVersion) ?? Self.unknownVersion
        self.build = Self.clean(build) ?? Self.unknownVersion
    }

    /// Reads the values from a bundle (defaults to the running app).
    init(bundle: Bundle = .main) {
        self.init(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    /// Whether the bundle supplied a usable version string.
    var isKnown: Bool { shortVersion != Self.unknownVersion }

    /// `Version 0.1.0`, or `Version —` when nothing is available.
    ///
    /// `build` is deliberately not shown. CFBundleVersion has read `2` since
    /// early on and never moved, while the marketing version climbed past
    /// forty releases — so the parenthesised number told a reader nothing
    /// except that two versions existed. The key stays in Info.plist because
    /// macOS uses it; the About pane just does not repeat it.
    var displayString: String {
        guard isKnown else { return "Version \(Self.unknownVersion)" }
        return "Version \(shortVersion)"
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// One row of the Shortcuts pane's key reference.
struct ShortcutEntry: Equatable, Identifiable {
    /// The keys as rendered, e.g. `⌘1…⌘9` or `gg`.
    let keys: String
    /// What the keystroke does.
    let detail: String

    var id: String { keys + "\u{1F}" + detail }
}

/// A titled group of shortcut rows.
struct ShortcutGroup: Equatable, Identifiable {
    let title: String
    /// Optional caveat shown under the group's rows.
    let note: String?
    let entries: [ShortcutEntry]

    var id: String { title }

    init(title: String, note: String? = nil, entries: [ShortcutEntry]) {
        self.title = title
        self.note = note
        self.entries = entries
    }
}

/// The panel's built-in key reference.
///
/// Static data mirroring `PanelView` (search-field key handling) and
/// `VimNavigator` (the vim state machine). Kept pure so a test can assert
/// it stays in step with those files.
enum ShortcutReference {
    static let groups: [ShortcutGroup] = [panel, vim]

    /// The keys `PanelView` handles itself, in the order a hand finds them:
    /// move, paste, keep, look, leave.
    ///
    /// Two rows describe a key that does more than one thing, and both are
    /// written as the ladder the code climbs rather than as a list of cases.
    /// Space escalates: with the pane shut it opens the pane, and a second
    /// press either hands a screenshot, image or file to Quick Look or — when
    /// the clip is one Quick Look has nothing to show for — shuts the pane
    /// again. Saying "toggle" would now be wrong on exactly the clips people
    /// press it on most. Esc is the same ladder descended, one rung per press.
    ///
    /// The conditions live on the rows that have them rather than in a
    /// group-wide note, because they are not the same condition: the movement
    /// arrows and Space stand down while there is a query in the search field
    /// to edit, and everything else here works regardless.
    ///
    /// Keys the panel merely refuses to swallow are not keys it handles, so
    /// Tab and Delete are absent: they appear in `PanelView.reservedCharacters`
    /// only to keep vim mode's catch-all from stealing them from the search
    /// field and the focus ring.
    static let panel = ShortcutGroup(
        title: "Panel",
        entries: [
            ShortcutEntry(keys: "↑ ↓", detail: "Move the selection; hold to keep moving"),
            ShortcutEntry(keys: "← →", detail: "Move along the strip; hold to keep moving (search field empty)"),
            ShortcutEntry(keys: "Return", detail: "Paste the selected clip"),
            ShortcutEntry(keys: "⇧Return", detail: "Paste as plain text"),
            ShortcutEntry(keys: "⌘1…⌘9", detail: "Paste the first nine results"),
            ShortcutEntry(keys: "⌘S", detail: "Save the selected clip as a note"),
            ShortcutEntry(
                keys: "Space",
                detail: "Open the preview; press again to Quick Look a screenshot, image or file, or to close the preview (search field empty)"
            ),
            ShortcutEntry(keys: "Esc", detail: "Close Quick Look, then the preview, then the panel"),
            ShortcutEntry(keys: "⌘W", detail: "Close the panel")
        ]
    )

    /// The vim bindings, which are `VimNavigator`'s with one exception: `h`
    /// and `l` are answered by `PanelView` directly, because the strip runs
    /// left to right and the horizontal pair had to move along it without the
    /// shared, separately tested navigator growing a second name for a step it
    /// already has. A reader of this pane cannot tell the difference, and
    /// should not have to.
    static let vim = ShortcutGroup(
        title: "Vim navigation",
        note: "Only when vim mode is on. The panel opens in NORMAL mode (shown in the search bar) where these keys navigate; / or i switches to INSERT mode to type in the search field, and Esc switches back.",
        entries: [
            ShortcutEntry(keys: "j / k", detail: "Move down / up; hold to keep moving"),
            ShortcutEntry(keys: "h / l", detail: "Move back / forward along the strip; hold to keep moving"),
            ShortcutEntry(keys: "gg / G", detail: "Jump to the top / bottom"),
            ShortcutEntry(keys: "⌃d / ⌃u", detail: "Half-page down / up"),
            ShortcutEntry(keys: "o / ⇧O", detail: "Paste / paste as plain text"),
            ShortcutEntry(keys: "p", detail: "Pin or unpin the selected clip"),
            ShortcutEntry(keys: "n", detail: "Save the selected clip as a note"),
            ShortcutEntry(keys: "dd", detail: "Delete the selected clip (asks first)"),
            ShortcutEntry(keys: "q / ⇧Q", detail: "Add to the queue / paste the queue"),
            ShortcutEntry(keys: "/ or i", detail: "Search: / starts a fresh query, i edits the current one"),
            ShortcutEntry(keys: "Esc", detail: "Abandon a half-typed sequence, or leave the search field")
        ]
    )
}
