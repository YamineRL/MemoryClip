import AppKit
import UniformTypeIdentifiers

/// The apps the user has named as never worth capturing from.
///
/// A companion to `SensitiveFilter.blockedApps` rather than a replacement:
/// that list is what MemoryClip knows about credential managers, and it stays
/// in force whatever is stored here. This one is what the user knows about
/// their own machine — the internal tool, the banking app, the password
/// manager nobody has heard of.
///
/// # Identity
///
/// Bundle identifier only, matching the built-in list and the identity a clip
/// already records (`ClipItem.sourceBundleID`). Two things follow. It needs no
/// permission: MemoryClip holds neither Accessibility nor Screen Recording, so
/// an app's *name* and its identifier are all it can see of a source, and the
/// screen it copied from stays unread. And it survives the app being renamed,
/// which a stored display name would not.
///
/// The display-name matching `SensitiveFilter` does for its own entries is
/// deliberately not repeated here. A loose substring test is a fail-safe worth
/// having for apps we guessed at; on an app the user picked by hand it is a
/// trap, because they chose one app and would have a second one blocked for
/// sharing a word with it.
///
/// # Storage
///
/// One `UserDefaults` array of identifiers, in the order they were added, so
/// the list reads back the way it was built.
struct ExcludedApps {
    /// `UserDefaults` key holding the excluded bundle identifiers.
    static let bundleIDsKey = "excludedAppBundleIDs"

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests exercise the real storage
    ///   without writing to the user's own defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Register the empty list. Called at launch beside the filter's own
    /// default; `register(defaults:)` only fills the registration domain, so a
    /// list the user has built always wins.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [bundleIDsKey: [String]()])
    }

    /// The excluded identifiers, oldest first.
    ///
    /// Anything stored under the key that is not an array of strings reads as
    /// an empty list rather than throwing: a corrupted preference must not
    /// take capture down with it.
    var bundleIDs: [String] {
        defaults.stringArray(forKey: Self.bundleIDsKey) ?? []
    }

    /// Whether a copy from `bundleID` is excluded.
    ///
    /// Anchored the way the built-in list matches, so excluding an app also
    /// excludes its helper processes (`com.example.app.helper`) — which is
    /// where the copy actually comes from in a browser or an Electron app.
    /// `nil` (unknown source) is never excluded.
    func contains(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleIDs.contains { SensitiveFilter.matchesBundleID(bundleID, entry: $0) }
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
    var apps: [ExcludedApp] {
        bundleIDs.map(ExcludedApp.init(bundleID:))
    }

    /// Whether the list holds this exact identifier, as opposed to one that
    /// covers it. A child identifier is excluded by its parent but is still a
    /// distinct entry, so adding it is an addition and not a duplicate.
    private func contains(exactly bundleID: String) -> Bool {
        bundleIDs.contains { $0.compare(bundleID, options: .caseInsensitive) == .orderedSame }
    }
}

extension ExcludedApps {
    /// What an open panel came back with.
    ///
    /// Three cases rather than an optional identifier, because two of them
    /// need different things said about them: a cancelled panel is the user
    /// changing their mind and wants no reply at all, while a bundle with no
    /// identifier is a choice that cannot be honoured and has to say so.
    enum Choice: Equatable {
        case cancelled
        /// The chosen app's bundle identifier.
        case app(String)
        /// The chosen bundle declares no identifier, so there is nothing to
        /// store and nothing to match a future copy against.
        case unidentified
    }

    /// Ask the user for an app, and answer with its bundle identifier.
    ///
    /// An open panel rather than a list of running apps: the app to exclude is
    /// usually not the one in front of you, and `/Applications` is where a
    /// user goes looking for it. The bundle is read for its identifier and
    /// then forgotten — the path is not stored, so moving or updating the app
    /// cannot break the exclusion.
    @MainActor
    static func chooseApp() -> Choice {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = loc("Choose")
        panel.title = loc("Choose an App")
        panel.message = loc("Pick an app MemoryClip should never capture from.")

        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return .unidentified }
        return .app(bundleID)
    }
}

/// One row of the exclusion list.
///
/// An app uninstalled after being excluded leaves an identifier that resolves
/// to nothing. The row still has to render — the exclusion is still in force,
/// and seeing it is the only way to withdraw it — so `url` is optional and
/// every value derived from it has an answer without one.
struct ExcludedApp: Identifiable, Equatable {
    let bundleID: String
    /// Where macOS finds the app, or nil when nothing on this Mac claims the
    /// identifier.
    let url: URL?

    var id: String { bundleID }

    init(bundleID: String, url: URL?) {
        self.bundleID = bundleID
        self.url = url
    }

    init(bundleID: String) {
        self.init(
            bundleID: bundleID,
            url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        )
    }

    /// Whether this Mac still has the app.
    var isInstalled: Bool { url != nil }

    /// The name Finder shows, or the identifier itself when the app is gone —
    /// which is all that is left to name the row by.
    var displayName: String {
        guard let url else { return bundleID }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
    }
}
