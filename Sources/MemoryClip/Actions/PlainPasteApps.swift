import AppKit
import UniformTypeIdentifiers

/// The apps the user has named as never worth pasting rich text into.
///
/// Rich text dropped into a terminal, a code editor or a chat box arrives
/// carrying the fonts and colours of wherever it was copied from, which none of
/// them have any use for. ⇧Return already asks for the plain paste one paste at
/// a time; this is the same answer given once per app.
///
/// # Identity
///
/// Bundle identifier, matched the way `ExcludedApps` matches — anchored, so a
/// listed app covers its helper processes. The destination of a paste is known
/// only as an `NSRunningApplication`, and its identifier is the one thing about
/// it that survives the app being renamed or moved. An identifier whose app has
/// since been uninstalled matches nothing and is otherwise harmless.
///
/// # Direction
///
/// A rule can only ever add plainness. `forcesPlainText(requested:into:)` takes
/// what the paste itself asked for and never contradicts it, so an explicit
/// ⇧Return stays plain wherever it lands, and no entry here can turn a plain
/// paste rich again. A clip that is not rich text has no formatting to strip,
/// so the rule is a no-op on it — that is `PasteService.payload`'s doing, which
/// only branches on `plainOnly` for `.richText`.
///
/// # Storage
///
/// One `UserDefaults` array of identifiers, in the order they were added,
/// seeded with `defaultBundleIDs` through the registration domain. That is what
/// makes the shipped entries removable: the seed is only ever a fallback, and
/// the first edit writes the whole remaining list to the user domain, where it
/// shadows the seed for good. A built-in list unioned in at read time would put
/// every removed app straight back.
struct PlainPasteApps {
    /// `UserDefaults` key holding the plain-paste bundle identifiers.
    static let bundleIDsKey = "plainPasteAppBundleIDs"

    /// What the list holds until the user edits it: the terminals, and the
    /// editors that are terminals in this respect.
    static let defaultBundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode"
    ]

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests exercise the real storage
    ///   without writing to the user's own defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Seed the list. `register(defaults:)` only fills the registration domain,
    /// so a list the user has edited always wins over the shipped one.
    /// - Parameter defaults: injectable for the same reason as `init`.
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [bundleIDsKey: defaultBundleIDs])
    }

    /// The listed identifiers, oldest first.
    ///
    /// Anything stored under the key that is not an array of strings reads as
    /// an empty list rather than throwing: a corrupted preference must not take
    /// pasting down with it.
    var bundleIDs: [String] {
        defaults.stringArray(forKey: Self.bundleIDsKey) ?? []
    }

    /// Whether a paste into `bundleID` is covered by a rule.
    ///
    /// Anchored the way the exclusion list matches, so listing an app also
    /// covers its helper processes (`com.example.app.helper`). `nil` (no target
    /// app) is never covered — there is nothing to have a rule about.
    func contains(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleIDs.contains { SensitiveFilter.matchesBundleID(bundleID, entry: $0) }
    }

    /// Whether a paste into `bundleID` has to be stripped to plain text.
    ///
    /// - Parameter requested: what the paste asked for on its own (⇧Return).
    ///   Kept as a floor rather than overwritten, because a rule that could
    ///   answer "rich" would make ⇧Return conditional on where it was pressed.
    func forcesPlainText(requested: Bool, into bundleID: String?) -> Bool {
        requested || contains(bundleID)
    }

    /// Add `bundleID` to the list.
    ///
    /// Idempotent: picking the same app twice leaves one entry, and there is
    /// nothing for a second one to mean. Comparison is case-insensitive
    /// because bundle identifiers are.
    /// - Returns: true when the list changed.
    @discardableResult
    func add(_ bundleID: String) -> Bool {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !contains(exactly: trimmed) else { return false }
        defaults.set(bundleIDs + [trimmed], forKey: Self.bundleIDsKey)
        return true
    }

    /// Remove `bundleID` from the list. Removing one that is not there is not
    /// an error — the list is already in the asked-for state.
    func remove(_ bundleID: String) {
        defaults.set(
            bundleIDs.filter { $0.compare(bundleID, options: .caseInsensitive) != .orderedSame },
            forKey: Self.bundleIDsKey
        )
    }

    /// The list as rows to render, each carrying whatever macOS can still say
    /// about the app behind the identifier.
    ///
    /// `ExcludedApp` rather than a row type of its own: both lists name apps by
    /// identifier and both have to render one whose app is gone, which is the
    /// whole of what that type answers.
    var apps: [ExcludedApp] {
        bundleIDs.map(ExcludedApp.init(bundleID:))
    }

    /// Whether the list holds this exact identifier, as opposed to one that
    /// covers it. A child identifier is covered by its parent but is still a
    /// distinct entry, so adding it is an addition and not a duplicate.
    private func contains(exactly bundleID: String) -> Bool {
        bundleIDs.contains { $0.compare(bundleID, options: .caseInsensitive) == .orderedSame }
    }
}

extension PlainPasteApps {
    /// Ask the user for an app, and answer with its bundle identifier.
    ///
    /// Shares `ExcludedApps.Choice`: the three outcomes an open panel has are
    /// the same ones here, and a cancelled panel and a bundle with no
    /// identifier still need saying differently.
    @MainActor
    static func chooseApp() -> ExcludedApps.Choice {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = loc("Choose")
        panel.title = loc("Choose an App")
        panel.message = loc("Pick an app MemoryClip should always paste plain text into.")

        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return .unidentified }
        return .app(bundleID)
    }
}
