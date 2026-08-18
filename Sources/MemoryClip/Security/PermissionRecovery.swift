import Foundation
import Security

/// A permission MemoryClip loses when its bundle is replaced, and can ask for
/// again on the user's behalf.
///
/// # Why this exists
///
/// TCC does not remember an app by its bundle identifier alone: it remembers
/// the identifier *and* the code it was signed as. MemoryClip ships ad-hoc
/// signed, so every update writes a new signature, and every update is
/// therefore a new app as far as macOS is concerned. The grants the user gave
/// the old one do not carry over.
///
/// Nothing announces that. The switches stay on, the buttons stay enabled, and
/// the first note or event after an update fails — or worse, an automatic one
/// fails with nobody watching. The user's only move is to work out which of
/// four System Settings panes has gone quiet, which is a repair job they
/// should never have been handed.
///
/// So the app keeps a record of what has worked (`PermissionLedger`), notices
/// at launch what has stopped working, and offers to ask again. Where macOS
/// has genuinely forgotten, the ask is the real prompt and one click restores
/// the grant. Where it has not — a refusal on the record, which no app may
/// re-raise — the offer is a link straight to the pane that holds the switch.
enum RecoverablePermission: String, CaseIterable, Sendable, Identifiable {
    /// Write-only calendar access — `EventKitSink`.
    case calendar
    /// Apple Events to Notes.app — `NotesAppSink`.
    case notesAutomation
    /// The synthetic ⌘V — `PasteService`.
    case accessibility

    var id: String { rawValue }

    /// What the row is called, in the words System Settings uses for it, so
    /// that the pane the button opens reads as the place it promised.
    var title: String {
        switch self {
        case .calendar: return loc("Calendars")
        case .notesAutomation: return loc("Automation")
        case .accessibility: return loc("Accessibility")
        }
    }

    /// What stops working while the grant is missing. Stated as the feature
    /// the user knows, not the API: nobody grants "Apple Events", they grant
    /// "MemoryClip may write my notes".
    var detail: String {
        switch self {
        case .calendar:
            return loc("Adding a clip to your calendar.")
        case .notesAutomation:
            return loc("Saving a clip to Apple Notes.")
        case .accessibility:
            return loc("Pasting the clip you pick into the app you came from.")
        }
    }

    var symbol: String {
        switch self {
        case .calendar: return "calendar.badge.plus"
        case .notesAutomation: return "note.text"
        case .accessibility: return "hand.tap"
        }
    }

    /// The System Settings pane that holds this switch, for the case macOS
    /// will not be prompted again.
    ///
    /// The anchors are Apple's own and have outlived several redesigns of the
    /// Settings app; an anchor that ever stops resolving opens Privacy &
    /// Security itself, which is one scroll from the answer rather than none.
    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .calendar: anchor = "Privacy_Calendars"
        case .notesAutomation: anchor = "Privacy_Automation"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// Whether MemoryClip can raise this permission's own prompt while macOS
    /// has forgotten the grant.
    ///
    /// False for Accessibility alone, and the exception is the whole reason
    /// the recovery window has two kinds of button: `AXIsProcessTrusted` has
    /// no "ask" — the API only opens System Settings with the list scrolled to
    /// MemoryClip, where the user has to add it themselves.
    var canPromptInPlace: Bool { self != .accessibility }
}

/// What macOS currently says about one permission.
///
/// Deliberately not any single framework's status type: EventKit, Apple Events
/// and the Accessibility API each spell this differently, and the only
/// distinction this feature turns on is whether asking again would put a
/// prompt on screen or waste the user's click.
enum PermissionState: Sendable, Equatable {
    /// Working. Nothing to recover.
    case granted
    /// macOS has nothing on file, so it will ask again — which is the state an
    /// update leaves a grant in.
    case forgotten
    /// Refused on the record. No app may re-raise it; only System Settings can.
    case denied
    /// Unavailable to check — Notes is not installed, a profile has turned the
    /// service off, the probe could not run. Never recovered from, because
    /// there is nothing here the user can act on.
    case unavailable
}

/// The identity TCC keys a grant to, as far as this app can observe it.
///
/// The cdhash: the one value that changes exactly when the thing TCC cares
/// about changes. A version string would miss a rebuild at the same version
/// (every development build, and any re-signed release), and a file date would
/// catch a copy that changed nothing.
enum AppIdentity {
    /// Resolved once: it cannot change while the process runs, and the
    /// fallbacks reach the filesystem.
    static let current: String = resolve()

    /// The running code's cdhash, hex, or the best stand-in available.
    ///
    /// `swift run` and `swift test` produce an unsigned binary with no cdhash;
    /// they get the executable's size and modification date instead, which is
    /// as much identity as an unsigned file has, and which keeps the recovery
    /// window testable outside a bundle.
    static func resolve() -> String {
        if let hash = signingHash() { return hash }
        return fileIdentity() ?? "unknown"
    }

    private static func signingHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileIdentity() -> String? {
        guard let url = Bundle.main.executableURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate
        else { return nil }
        return "\(size)-\(modified.timeIntervalSince1970)"
    }
}

/// What has worked, and under which build of MemoryClip.
///
/// Two records per permission, both keyed by `AppIdentity`:
///
/// - **granted** — the last identity this permission was seen working under.
///   Written wherever a grant is observed, which is the only honest place to
///   write it: TCC will not tell an app what it was allowed to do yesterday.
/// - **asked** — the identity the recovery window last offered it under, so a
///   permission the user chose not to restore is not put in front of them
///   again on every launch. A further update resets that, because a further
///   update is a fresh loss rather than the same one.
///
/// Plain `[String: String]` in UserDefaults rather than a coded blob: it is
/// two strings per permission, it has to survive a version it does not
/// recognise, and it is worth being readable in `defaults read`.
struct PermissionLedger {
    static let grantedKey = "permissionGrantIdentities"
    static let askedKey = "permissionRecoveryOffered"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Identities under which each permission was last seen working.
    var granted: [RecoverablePermission: String] {
        Self.read(defaults.dictionary(forKey: Self.grantedKey))
    }

    /// Identities under which each permission was last offered for recovery.
    var asked: [RecoverablePermission: String] {
        Self.read(defaults.dictionary(forKey: Self.askedKey))
    }

    /// Record that `permission` works under the running build.
    func noteGranted(_ permission: RecoverablePermission, identity: String = AppIdentity.current) {
        write(Self.grantedKey, permission, identity)
    }

    /// Forget a grant, so nothing offers to restore it.
    ///
    /// Called when macOS reports a refusal: a permission the user turned off
    /// themselves is not a permission an update lost, and an app that keeps
    /// offering to undo a decision is an app that has stopped listening.
    func forget(_ permission: RecoverablePermission) {
        write(Self.grantedKey, permission, nil)
    }

    /// Record that recovery has been offered under the running build.
    func noteOffered(_ permission: RecoverablePermission, identity: String = AppIdentity.current) {
        write(Self.askedKey, permission, identity)
    }

    private func write(_ key: String, _ permission: RecoverablePermission, _ identity: String?) {
        var stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        stored[permission.rawValue] = identity
        defaults.set(stored, forKey: key)
    }

    private static func read(_ stored: [String: Any]?) -> [RecoverablePermission: String] {
        var found: [RecoverablePermission: String] = [:]
        for (key, value) in stored ?? [:] {
            guard let permission = RecoverablePermission(rawValue: key), let identity = value as? String else {
                continue
            }
            found[permission] = identity
        }
        return found
    }
}

/// Which permissions an update has cost the user, from what the ledger
/// remembers and what macOS says now.
///
/// Pure, so the rule can be tested without a TCC database, a bundle or a
/// window server — none of which a test machine has.
enum PermissionRecovery {
    /// The permissions worth putting in front of the user, in a stable order.
    ///
    /// A permission qualifies when all four hold:
    ///
    /// 1. It was seen working at some point. A grant that never existed is a
    ///    feature the user has not tried, not a loss to repair.
    /// 2. It was working under a *different* build. Losing a grant under the
    ///    build that has it is not something an update did, so it is left to
    ///    the feature's own error to report.
    /// 3. macOS has forgotten it, or refused it. Anything else — granted,
    ///    unavailable — is not a repair this window can offer.
    /// 4. This build has not offered it already. One offer per update; the
    ///    Settings panes stay open to anyone who declines and changes their
    ///    mind.
    static func lost(
        granted: [RecoverablePermission: String],
        asked: [RecoverablePermission: String],
        states: [RecoverablePermission: PermissionState],
        identity: String
    ) -> [RecoverablePermission] {
        RecoverablePermission.allCases.filter { permission in
            guard let seen = granted[permission], seen != identity else { return false }
            guard asked[permission] != identity else { return false }
            switch states[permission] {
            case .forgotten, .denied: return true
            case .granted, .unavailable, nil: return false
            }
        }
    }
}
