import Foundation

/// One host's tracking parameters.
///
/// `domain` is a registrable domain (`instagram.com`) or a registrable domain
/// with a wildcard public suffix (`amazon.*`, which covers `amazon.com`,
/// `amazon.co.uk` and the rest of the storefronts). Both forms match the
/// domain itself and any subdomain of it.
struct LinkHostRule: Sendable, Equatable {
    let domain: String
    /// Parameter names, each either exact (`igsh`) or a suffix wildcard
    /// (`pd_rd_*`).
    let parameters: [String]
}

/// The three tiers of cleaning rules, as data.
///
/// Data rather than code so a site that changes its parameter names is a
/// one-line edit with a test case beside it, and so the corpus in
/// `LinkCleanerTests` reads as the documentation of what each site is expected
/// to shed.
enum LinkRules {
    /// Tier 1a: campaign parameters, removed on every host but gated on their
    /// own setting — a marketer reading their own analytics wants these kept
    /// while still shedding `fbclid`.
    static let campaignParameters: [String] = ["utm_*"]

    /// Tier 1b: identifiers removed on every host. Each one names the click,
    /// the recipient or the send rather than the page.
    static let globalParameters: [String] = [
        "gclid",
        "dclid",
        "gbraid",
        "wbraid",
        "fbclid",
        "msclkid",
        "mc_cid",
        "mc_eid",
        "twclid",
        "ttclid",
        "yclid",
        "igshid",
        "_hsenc",
        "_hsmi",
        "vero_id",
        "oly_enc_id",
        "ref_src",
        "wt_mc",
        "pk_campaign",
        "pk_kwd",
    ]

    /// Tier 2: parameters removed only on the host that issues them, where
    /// the same name elsewhere may well be load-bearing — `si` is Spotify's
    /// share identifier and somebody else's sort index.
    static let hostRules: [LinkHostRule] = [
        LinkHostRule(domain: "instagram.com", parameters: ["igsh", "igshid", "img_index", "stkn"]),
        LinkHostRule(domain: "threads.net", parameters: ["igsh", "igshid", "xmt"]),
        LinkHostRule(domain: "threads.com", parameters: ["igsh", "igshid", "xmt"]),
        LinkHostRule(domain: "youtube.com", parameters: ["si", "pp", "feature", "kw"]),
        LinkHostRule(domain: "youtu.be", parameters: ["si", "pp", "feature", "kw"]),
        LinkHostRule(domain: "x.com", parameters: ["s", "t", "src", "refsrc", "cn", "ref_src", "ref_url"]),
        LinkHostRule(domain: "twitter.com", parameters: ["s", "t", "src", "refsrc", "cn", "ref_src", "ref_url"]),
        LinkHostRule(
            domain: "amazon.*",
            parameters: [
                "ref_", "th", "psc", "pd_rd_*", "pf_rd_*", "qid", "sr", "dib*", "tag", "linkcode",
                "ascsubtag", "crid", "sprefix", "_encoding", "content-id", "refrid", "rnid", "camp",
                "creative", "creativeasin", "colid", "coliid", "qualifier", "dchild", "__mk_*",
            ]
        ),
        LinkHostRule(
            domain: "tiktok.com",
            parameters: [
                "is_from_webapp", "sender_device", "web_id", "_t", "_r", "_d",
                "share_app_name", "share_iid", "u_code", "preview_pb",
            ]
        ),
        LinkHostRule(
            domain: "facebook.com",
            parameters: [
                "mibextid", "rdid", "__tn__", "__cft__*", "_rdr", "comment_tracking", "sfnsn",
                "paipv", "dti", "eav", "ls_ref", "referral_code", "referral_story_type",
                "video_source", "hc_*", "idorvanity",
            ]
        ),
        LinkHostRule(
            domain: "linkedin.com",
            parameters: ["trackingid", "originalsubdomain", "rcm", "refid", "trk", "lipi", "li_fat_id"]
        ),
        LinkHostRule(domain: "spotify.com", parameters: ["si", "nd", "dlsi"]),
        LinkHostRule(
            domain: "reddit.com",
            parameters: ["share_id", "correlation_id", "ref", "ref_source", "ref_campaign", "rdt"]
        ),
        LinkHostRule(domain: "ebay.*", parameters: ["hash", "_trkparms", "_trksid", "_from"]),
        LinkHostRule(
            domain: "aliexpress.*",
            parameters: [
                "spm", "algo_*", "pdp_*", "aff_request_id", "gps-id", "scm*", "ws_ab_test",
                "btsid", "mall_affr", "terminal_id", "af",
            ]
        ),
        LinkHostRule(domain: "twitch.tv", parameters: ["tt_content", "tt_medium"]),
        LinkHostRule(domain: "snapchat.com", parameters: ["sc_referrer", "sc_ua"]),
        LinkHostRule(domain: "etsy.com", parameters: ["click_key", "click_sum", "organic_search_click"]),
        LinkHostRule(domain: "walmart.com", parameters: ["u1", "ath*"]),
        LinkHostRule(domain: "imdb.com", parameters: ["ref_", "pf_rd_*"]),
        LinkHostRule(domain: "netflix.com", parameters: ["trackid", "tctx"]),
        LinkHostRule(
            domain: "google.*",
            parameters: [
                "ved", "usg", "sca_esv", "sca_upv", "sxsrf", "ei", "oq", "gs_*", "iflsig",
                "uact", "sourceid", "rlz", "aqs", "gws_*", "sei", "cshid", "pcampaignid",
            ]
        ),
    ]

    /// Tier 3a: hosts whose query string is never touched. The parameters are
    /// opaque and a false positive costs more than a long URL does.
    static let allowlistedDomains: [String] = ["docs.google.com", "drive.google.com"]

    /// Tier 3b: names that read as a credential. A URL carrying one is left
    /// entirely alone whatever else is on it — a stripped auth token is a
    /// broken link the user cannot diagnose.
    static let credentialParameters: Set<String> = [
        "token", "code", "signature", "sig", "auth", "key",
    ]

    /// Whether `name` matches `pattern`, which is either exact or a suffix
    /// wildcard. Case-insensitive: query parameter names are not consistently
    /// cased across the sites the rules cover.
    static func matches(name: String, pattern: String) -> Bool {
        let name = name.lowercased()
        let pattern = pattern.lowercased()
        guard pattern.hasSuffix("*") else { return name == pattern }
        return name.hasPrefix(String(pattern.dropLast()))
    }

    /// Whether `host` is `domain` or a subdomain of it.
    ///
    /// A `domain` ending in `.*` matches any public suffix of one or two
    /// labels, which is what covers `amazon.com` and `amazon.co.uk` from one
    /// rule without carrying a copy of the public-suffix list.
    static func host(_ host: String, matches domain: String) -> Bool {
        let host = host.lowercased()
        let domain = domain.lowercased()
        guard domain.hasSuffix(".*") else {
            return host == domain || host.hasSuffix("." + domain)
        }
        let base = String(domain.dropLast(2))
        let labels = host.split(separator: ".").map(String.init)
        guard let index = labels.lastIndex(of: base) else { return false }
        let suffixLength = labels.count - index - 1
        return suffixLength == 1 || suffixLength == 2
    }

    /// The parameter patterns to strip on `host`, from every tier that
    /// applies to it.
    static func parameters(forHost host: String, removingCampaigns: Bool) -> [String] {
        var patterns = globalParameters
        if removingCampaigns { patterns += campaignParameters }
        for rule in hostRules where Self.host(host, matches: rule.domain) {
            patterns += rule.parameters
        }
        return patterns
    }
}
