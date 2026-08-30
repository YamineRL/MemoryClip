import Foundation

/// Every UserDefaults key the link cleaner reads, in the shape of
/// `NoteSettingsKeys`.
enum LinkSettingsKeys {
    /// The master switch: whether a copied link is stored cleaned.
    static let cleanEnabled = "linkCleanEnabled"
    /// Whether `utm_*` goes with the rest of the identifiers.
    static let removeCampaignParameters = "linkCleanCampaignParameters"
    /// Hosts the cleaner never touches, as the user typed them.
    static let excludedHosts = "linkCleanExcludedHosts"

    /// Registered at launch. Both switches are ON: a copied link arrives
    /// carrying identifiers the user did not put there, and the escape
    /// hatches — the per-site list, `Use original` on every cleaned clip —
    /// are what make an on-by-default safe. The exclusion list starts empty.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            cleanEnabled: true,
            removeCampaignParameters: true,
            excludedHosts: [String](),
        ])
    }
}

/// What the settings make of the cleaner.
enum LinkSettings {
    static var isCleaningEnabled: Bool {
        UserDefaults.standard.bool(forKey: LinkSettingsKeys.cleanEnabled)
    }

    /// The options the rules are applied under, read fresh so a change in
    /// Settings takes effect on the next copy rather than the next launch.
    static var options: LinkCleaner.Options {
        LinkCleaner.Options(
            removeCampaignParameters: UserDefaults.standard.bool(
                forKey: LinkSettingsKeys.removeCampaignParameters
            ),
            excludedHosts: LinkExclusions().hosts
        )
    }

    /// The cleaned form of a captured link, or nil when cleaning is switched
    /// off or there was nothing to remove.
    static func cleanOnCapture(_ url: String) -> LinkCleaner.Result? {
        guard isCleaningEnabled else { return nil }
        return LinkCleaner.clean(url, options: options)
    }
}

/// The hosts the user has put out of the cleaner's reach.
///
/// One `UserDefaults` array of hosts, in the order they were added, the same
/// storage shape `ExcludedApps` uses for the capture exclusions.
struct LinkExclusions {
    static let hostsKey = LinkSettingsKeys.excludedHosts

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests exercise the real storage
    ///   without writing to the user's own defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The excluded hosts, oldest first. A stored value that is not an array
    /// of strings reads as an empty list rather than throwing.
    var hosts: [String] {
        defaults.stringArray(forKey: Self.hostsKey) ?? []
    }

    func add(_ host: String) {
        guard let host = Self.normalize(host) else { return }
        var current = hosts
        guard !current.contains(host) else { return }
        current.append(host)
        defaults.set(current, forKey: Self.hostsKey)
    }

    func remove(_ host: String) {
        defaults.set(hosts.filter { $0 != host }, forKey: Self.hostsKey)
    }

    /// A typed entry reduced to the host it names, or nil when it names none.
    ///
    /// Accepts what a user actually has to hand — a whole URL pasted out of
    /// the address bar, a bare domain, a stray `www.` — because the list is
    /// matched by domain and a pasted path would never match anything.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let separator = text.range(of: "://") { text = String(text[separator.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if let mark = text.firstIndex(of: "?") { text = String(text[..<mark]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        guard text.contains("."), !text.hasPrefix("."), !text.hasSuffix(".") else { return nil }
        guard !text.contains(" ") else { return nil }
        return text
    }
}
