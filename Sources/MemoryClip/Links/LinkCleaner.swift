import Foundation

/// Strips tracking parameters out of a URL.
///
/// Pure string work over `LinkRules`: no AppKit, no network, no state, so it
/// runs inline on the capture path and the whole of it is reachable from a
/// test.
///
/// The surgery is done on the original string rather than by re-serializing
/// `URLComponents`, which would re-encode surviving values and normalise the
/// parts nobody asked it to touch. Everything outside the query — scheme,
/// host case, path, port, fragment — comes through byte for byte, and so does
/// the order and encoding of the parameters that stay.
enum LinkCleaner {
    /// What the user's settings make of the rules.
    struct Options: Sendable, Equatable {
        /// Whether `utm_*` goes with the rest. Its own switch, because
        /// campaign parameters are the one tier somebody may be reading.
        var removeCampaignParameters: Bool
        /// Hosts the user has put out of bounds, matched like a rule domain:
        /// the host itself and any subdomain of it.
        var excludedHosts: [String]

        init(removeCampaignParameters: Bool = true, excludedHosts: [String] = []) {
            self.removeCampaignParameters = removeCampaignParameters
            self.excludedHosts = excludedHosts
        }

        static let `default` = Options()
    }

    /// A URL that was actually changed.
    struct Result: Sendable, Equatable {
        /// The cleaned URL.
        let url: String
        /// The parameter names that were dropped, in the order they appeared.
        let removed: [String]
    }

    /// The cleaned form of `url`, or nil when there was nothing to remove.
    ///
    /// Nil covers every "leave it alone" case as well as the no-op: a scheme
    /// that is not `http`/`https`, an allowlisted or user-excluded host, a URL
    /// carrying a credential-shaped parameter, and a URL whose parameters are
    /// all load-bearing. A caller that gets nil stores the URL as it arrived.
    static func clean(_ url: String, options: Options = .default) -> Result? {
        guard let host = host(of: url) else { return nil }
        guard !isExempt(host: host, options: options) else { return nil }
        guard let query = queryRange(in: url) else { return nil }

        let pairs = url[query].split(separator: "&", omittingEmptySubsequences: false).map(String.init)
        let names = pairs.map(name(ofPair:))
        // Checked over every parameter, not just the ones a rule would take:
        // a URL that authenticates through its query string is one where any
        // edit is a guess.
        guard !names.contains(where: { LinkRules.credentialParameters.contains($0.lowercased()) }) else {
            return nil
        }

        let patterns = LinkRules.parameters(
            forHost: host,
            removingCampaigns: options.removeCampaignParameters
        )
        var removed: [String] = []
        var kept: [String] = []
        for (pair, name) in zip(pairs, names) {
            if patterns.contains(where: { LinkRules.matches(name: name, pattern: $0) }) {
                removed.append(name)
            } else if !pair.isEmpty {
                kept.append(pair)
            }
        }
        guard !removed.isEmpty else { return nil }

        // The `?` goes with the last parameter: a bare `?` at the end of a URL
        // is the leftover this is meant to avoid.
        var cleaned = String(url[url.startIndex..<url.index(before: query.lowerBound)])
        if !kept.isEmpty { cleaned += "?" + kept.joined(separator: "&") }
        cleaned += url[query.upperBound...]
        return Result(url: cleaned, removed: removed)
    }

    /// The host of a web URL, or nil when the string is not one.
    ///
    /// A URL with no scheme is read as `https`, matching how
    /// `ContentParser.isWebURL` classifies `www.example.com` as a link in the
    /// first place — the prepended scheme is used for parsing only and never
    /// reaches the cleaned string.
    private static func host(of url: String) -> String? {
        let candidate = url.lowercased().hasPrefix("www.") ? "https://" + url : url
        guard let parsed = URL(string: candidate) else { return nil }
        if let scheme = parsed.scheme?.lowercased(), scheme != "http", scheme != "https" { return nil }
        guard let host = parsed.host?.lowercased(), host.contains(".") else { return nil }
        return host
    }

    /// Whether this host's query string is out of bounds — allowlisted here,
    /// or listed by the user.
    private static func isExempt(host: String, options: Options) -> Bool {
        let domains = LinkRules.allowlistedDomains + options.excludedHosts
        return domains.contains { LinkRules.host(host, matches: $0) }
    }

    /// The span of the query string inside `url`, empty query excluded.
    ///
    /// The fragment ends it: `?a=1#x?y` carries one parameter, not two.
    private static func queryRange(in url: String) -> Range<String.Index>? {
        guard let mark = url.firstIndex(of: "?") else { return nil }
        let start = url.index(after: mark)
        let end = url[start...].firstIndex(of: "#") ?? url.endIndex
        guard start < end else { return nil }
        return start..<end
    }

    /// A pair's parameter name — everything up to the first `=`, percent
    /// decoded where it can be.
    private static func name(ofPair pair: String) -> String {
        let raw = pair.prefix { $0 != "=" }
        return String(raw).removingPercentEncoding ?? String(raw)
    }
}
