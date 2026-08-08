import Foundation

/// App name/version strings for the About tab.
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

    /// `Version 0.1.0 (1)`, or `Version —` when nothing is available.
    var displayString: String {
        guard isKnown else { return "Version \(Self.unknownVersion)" }
        guard build != Self.unknownVersion else { return "Version \(shortVersion)" }
        return "Version \(shortVersion) (\(build))"
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// One row of the Shortcuts tab's key reference.
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

    static let panel = ShortcutGroup(
        title: "Panel",
        entries: [
            ShortcutEntry(keys: "↑ ↓", detail: "Move the selection"),
            ShortcutEntry(keys: "Return", detail: "Paste the selected clip"),
            ShortcutEntry(keys: "⇧Return", detail: "Paste as plain text"),
            ShortcutEntry(keys: "⌘1…⌘9", detail: "Paste the first nine results"),
            ShortcutEntry(keys: "Space", detail: "Toggle the preview pane (search field empty)"),
            ShortcutEntry(keys: "Esc", detail: "Close the preview, then the panel")
        ]
    )

    static let vim = ShortcutGroup(
        title: "Vim navigation",
        note: "Only when vim mode is on. The panel opens in NORMAL mode (shown in the search bar) where these keys navigate; / or i switches to INSERT mode to type in the search field, and Esc switches back.",
        entries: [
            ShortcutEntry(keys: "j / k", detail: "Move down / up"),
            ShortcutEntry(keys: "gg / G", detail: "Jump to the top / bottom"),
            ShortcutEntry(keys: "⌃d / ⌃u", detail: "Half-page down / up"),
            ShortcutEntry(keys: "o / ⇧O", detail: "Paste / paste as plain text"),
            ShortcutEntry(keys: "p", detail: "Pin or unpin the selected clip"),
            ShortcutEntry(keys: "dd", detail: "Delete the selected clip (asks first)"),
            ShortcutEntry(keys: "q / ⇧Q", detail: "Add to the queue / paste the queue"),
            ShortcutEntry(keys: "/ or i", detail: "Search: / starts a fresh query, i edits the current one"),
            ShortcutEntry(keys: "Esc", detail: "Abandon a half-typed sequence, or leave the search field")
        ]
    )
}
