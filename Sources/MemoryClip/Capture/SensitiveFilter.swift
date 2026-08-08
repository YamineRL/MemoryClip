import AppKit
import Foundation

/// Sensitive-data filtering applied at capture time (Phase 2).
///
/// Design note: the app is permission-minimal — MemoryClip requests neither
/// Accessibility nor Screen Recording, so it *cannot* read other apps'
/// window titles. The credential-manager guard is therefore APP-IDENTITY
/// based (bundle identifier / localized name of the frontmost/source app),
/// not window-title pattern matching.
public enum SensitiveFilter {
    /// UserDefaults key toggling the whole filter (settings UI, Phase 2).
    public static let filteringEnabledKey = "sensitiveFilterEnabled"

    // MARK: - Enablement

    /// Register the filter's defaults. Wave-2 settings calls this at launch.
    /// `register(defaults:)` only fills the registration domain, so an
    /// explicit user preference always wins.
    public static func registerDefaults() {
        UserDefaults.standard.register(defaults: [filteringEnabledKey: true])
    }

    /// Whether filtering is on. Defaults to `true`, including when the key
    /// was never registered (fresh install, tests, defaults wiped).
    public static var isFilteringEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: filteringEnabledKey) != nil else { return true }
        return defaults.bool(forKey: filteringEnabledKey)
    }

    // MARK: - Card-number detection (Luhn)

    /// True when the text contains what looks like a payment-card number.
    ///
    /// # The rule
    ///
    /// Text is split into *runs* of digits, where a single space or dash
    /// between two digit groups does not break the run, so
    /// `4242 4242 4242 4242` is one run of four *groups*. A candidate card is
    /// any contiguous sequence of WHOLE groups, and it is treated as a card
    /// only when all four of these hold:
    ///
    /// 1. **Delimited boundaries.** The candidate starts and ends on a group
    ///    boundary — a separator or the end of the run. A window whose edges
    ///    fall in the middle of an unbroken digit run is not considered.
    /// 2. **Card-like grouping.** A multi-group candidate must have every
    ///    group at least 3 digits long (`4111 1111 1111 1111`,
    ///    `3782 822463 10005`, `4111-1111-1111-1111`). A single unbroken
    ///    group is always allowed.
    /// 3. **Plausible issuer prefix and length.** The candidate's leading
    ///    digits must match a known IIN range at a length that issuer
    ///    actually uses (see `issuerRules`) — Visa 4 at 13/16/19, Amex 34/37
    ///    at 15, and so on.
    /// 4. **Luhn.** The candidate passes the Luhn checksum.
    ///
    /// # Why
    ///
    /// The previous version slid a 13…19 digit window across every run and
    /// blocked on any Luhn-valid window. That closed real evasions (a card
    /// beside a longer reference number, two cards merged into one 32-digit
    /// run, a card after a long log timestamp) but roughly 65% of random
    /// 16-digit runs contain *some* Luhn-valid 13-digit sub-window, so long
    /// order numbers, tracking numbers and reference IDs were silently
    /// dropped from the user's history. Requirements 1–3 cut that to a few
    /// percent while still catching every genuinely-formatted card: real
    /// cards are written as whole numbers with recognisable groupings and
    /// start with a real IIN.
    ///
    /// # Deliberate limitations
    ///
    /// This is a heuristic, not a scanner, and it is a best-effort courtesy —
    /// the whole filter is user-toggleable in Settings.
    ///
    /// - A card buried inside a longer unbroken digit run with no separator
    ///   (`ref20244242424242424242`) is NOT detected. Detecting it is exactly
    ///   what produced the false-positive flood; a clip like that does not
    ///   look like a copied card.
    /// - Cards written with implausible groupings (`4 2424 2424 2424 242`)
    ///   are not detected.
    /// - The IIN table covers the major networks plus Maestro/Mir/RuPay/Verve.
    ///   A card on a network outside the table — notably UATP (prefix `1`),
    ///   deliberately excluded because it would re-add 10% of all 15-digit
    ///   runs — is not detected.
    /// - A non-card that happens to be grouped like a card, carry a real IIN
    ///   and pass Luhn is still blocked. Failing that way costs a re-copy;
    ///   failing the other way stores a card number forever.
    public static func isLikelyCardNumber(_ text: String) -> Bool {
        for run in digitGroupRuns(in: text) {
            for start in run.indices {
                // Multi-group candidates must look like card grouping.
                if run[start].count < minimumGroupLength, run.count > 1 { continue }
                var digits: [Int] = []
                for end in start..<run.count {
                    let group = run[end]
                    if end > start, group.count < minimumGroupLength { break }
                    digits.append(contentsOf: group)
                    if digits.count > 19 { break }
                    if digits.count >= 13, isPlausibleCard(digits), passesLuhn(digits) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Shortest group allowed inside a multi-group candidate. Real cards are
    /// written in groups of 4 (most networks), 4-6-5 (Amex) or 4-6-4
    /// (Diners) — never in ones and twos.
    private static let minimumGroupLength = 3

    /// Issuer identification ranges, as (inclusive numeric prefix range of a
    /// fixed digit width, lengths that issuer actually issues at).
    ///
    /// Kept a little wider than strictly necessary — this is a fail-safe
    /// filter, so an unnecessary entry costs a rare dropped clip while a
    /// missing one leaks a card.
    static let issuerRules: [(low: Int, high: Int, width: Int, lengths: Set<Int>)] = [
        (4, 4, 1, [13, 16, 19]),                    // Visa
        (51, 55, 2, [16]),                          // Mastercard
        (2221, 2720, 4, [16]),                      // Mastercard 2-series
        (2200, 2204, 4, [16]),                      // Mir
        (34, 34, 2, [15]),                          // American Express
        (37, 37, 2, [15]),                          // American Express
        (6011, 6011, 4, [16, 19]),                  // Discover
        (644, 649, 3, [16, 19]),                    // Discover
        (65, 65, 2, [16, 19]),                      // Discover / Verve
        (3528, 3589, 4, [16, 17, 18, 19]),          // JCB
        (300, 305, 3, [14, 16, 19]),                // Diners Club
        (3095, 3095, 4, [14]),                      // Diners Club
        (36, 36, 2, [14, 16, 19]),                  // Diners Club International
        (38, 39, 2, [14, 16, 19]),                  // Diners Club / Carte Blanche
        (62, 62, 2, [16, 17, 18, 19]),              // UnionPay
        (60, 60, 2, [16]),                          // RuPay
        (81, 82, 2, [16]),                          // RuPay
        (508, 508, 3, [16]),                        // RuPay
        (5018, 5018, 4, [13, 14, 15, 16, 17, 18, 19]), // Maestro
        (5020, 5020, 4, [13, 14, 15, 16, 17, 18, 19]), // Maestro
        (5038, 5038, 4, [13, 14, 15, 16, 17, 18, 19]), // Maestro
        (5060, 5060, 4, [16, 19]),                  // Verve
        (5893, 5893, 4, [13, 14, 15, 16, 17, 18, 19]), // Maestro
        (6304, 6304, 4, [13, 14, 15, 16, 17, 18, 19]), // Maestro
        (6759, 6763, 4, [13, 14, 15, 16, 17, 18, 19]), // Maestro UK
    ]

    /// Whether `digits` carries a known issuer prefix at a length that issuer
    /// issues at.
    static func isPlausibleCard(_ digits: [Int]) -> Bool {
        guard digits.count >= 13, digits.count <= 19 else { return false }
        for rule in issuerRules where rule.lengths.contains(digits.count) {
            guard rule.width <= digits.count else { continue }
            var prefix = 0
            for index in 0..<rule.width { prefix = prefix * 10 + digits[index] }
            if prefix >= rule.low, prefix <= rule.high { return true }
        }
        return false
    }

    /// All digit runs in `text`, each split into its groups. A single space or
    /// dash between two digit groups keeps the run going (so "4242 4242 …" is
    /// one run of several groups) but is remembered as a group boundary.
    static func digitGroupRuns(in text: String) -> [[[Int]]] {
        let chars = Array(text)
        var runs: [[[Int]]] = []
        var run: [[Int]] = []
        var group: [Int] = []
        var i = 0

        func endGroup() {
            if !group.isEmpty { run.append(group) }
            group = []
        }
        func endRun() {
            endGroup()
            if !run.isEmpty { runs.append(run) }
            run = []
        }

        while i < chars.count {
            let c = chars[i]
            if c.isASCII, c.isNumber, let d = c.wholeNumberValue {
                group.append(d)
                i += 1
            } else if (c == " " || c == "-"), !group.isEmpty,
                      i + 1 < chars.count,
                      chars[i + 1].isASCII, chars[i + 1].isNumber {
                // Separator between two digit groups: stay in the run.
                endGroup()
                i += 1
            } else {
                endRun()
                i += 1
            }
        }
        endRun()
        return runs
    }

    /// Standard Luhn checksum over decimal digits.
    private static func passesLuhn<C: Collection>(_ digits: C) -> Bool where C.Element == Int {
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }

    // MARK: - Credential-app guard

    /// Known credential managers. Extend as needed: an entry blocks when the
    /// source app's bundle identifier matches EXACTLY (or is a dotted child
    /// of it, e.g. a helper process), or when its localized name contains the
    /// entry's name.
    static let blockedApps: [(bundleID: String?, name: String?)] = [
        // 1Password 8 (current) plus the long-dead 6/7/4 standalone builds.
        ("com.1password.1password", "1Password"),
        ("com.1password.browser-support", "1Password"),
        ("com.agilebits.onepassword7", "1Password"),
        ("com.agilebits.onepassword4", "1Password"),
        ("com.apple.Passwords", "Passwords"),
        ("com.apple.keychainaccess", "Keychain Access"),
        ("com.bitwarden.desktop", "Bitwarden"),
        ("com.lastpass.lastpassmac", "LastPass"),
        ("com.dashlane.Dashlane", "Dashlane"),
        ("org.keepassxc.keepassxc", "KeePassXC"),
        ("com.nordpass.NordPass", "NordPass"),
        ("io.enpass.mac.inhouse", "Enpass"),
        ("me.proton.pass", "Proton Pass"),
        ("ch.protonmail.pass", "Proton Pass"),
        ("com.markmcguill.strongbox.mac", "Strongbox"),
        ("com.markmcguill.strongbox", "Strongbox"),
    ]

    /// Generic name fragments that always mark an app as credential storage.
    ///
    /// Deliberately a loose substring catch-all: it blocks any app whose
    /// display name merely *contains* these words, so unrelated apps
    /// ("Password Game", "Vault of Glass", a note-taking app called
    /// "Vaults") are blocked too. That false-positive rate is the accepted
    /// price of catching credential managers we have never heard of; the
    /// user can turn the whole filter off in Settings.
    private static let blockedNameFragments = ["password", "vault"]

    /// Whether the given running app is a known credential manager.
    /// `nil` (unknown source) is never blocked.
    public static func isBlockedApp(_ app: NSRunningApplication?) -> Bool {
        isBlocked(bundleID: app?.bundleIdentifier, name: app?.localizedName)
    }

    /// Pure matching core (testable without constructing NSRunningApplication,
    /// which is not constructible in tests).
    public static func isBlocked(bundleID: String?, name: String?) -> Bool {
        if let bundleID, !bundleID.isEmpty,
           blockedApps.contains(where: { entry in
               guard let entryID = entry.bundleID else { return false }
               return matchesBundleID(bundleID, entry: entryID)
           }) {
            return true
        }
        if let name, !name.isEmpty {
            if blockedApps.contains(where: { entry in
                guard let entryName = entry.name else { return false }
                return name.range(of: entryName, options: .caseInsensitive) != nil
            }) {
                return true
            }
            let lowered = name.lowercased()
            if blockedNameFragments.contains(where: lowered.contains) {
                return true
            }
        }
        return false
    }

    /// Anchored bundle-identifier match: equal, or a dotted descendant of the
    /// listed id (`com.1password.1password.helper`). A plain substring test —
    /// what this used to do — also blocked unrelated apps whose identifier
    /// merely contained a listed one (`com.example.com.bitwarden.desktop.viewer`).
    static func matchesBundleID(_ bundleID: String, entry: String) -> Bool {
        if bundleID.compare(entry, options: .caseInsensitive) == .orderedSame { return true }
        let prefix = entry + "."
        return bundleID.count > prefix.count
            && bundleID.prefix(prefix.count).compare(prefix, options: .caseInsensitive) == .orderedSame
    }
}
