import CryptoKit
import Foundation

/// What the app does with a clip the detector calls a secret.
enum SecretMode: String, CaseIterable, Sendable {
    /// Seal it under the Secure Enclave key and keep the ciphertext (D1's
    /// default, for new installs and existing users alike).
    case keepEncrypted
    /// Never store it at all.
    case drop
    /// The behaviour before this feature: an ordinary clip.
    case keepPlain
}

/// The secrets feature's UserDefaults keys.
enum SecretSettingsKeys {
    /// `SecretMode` raw value.
    static let mode = "secretMode"
    /// Whether the generic high-entropy token rule runs (default on).
    static let genericTokens = "secretGenericTokens"
    /// Whether one-time codes expire after ten minutes (default on).
    static let forgetCodes = "secretForgetCodes"
    /// Whether a pasted secret is wiped from the clipboard 90 s later
    /// (default on).
    static let clearClipboard = "secretClearClipboard"
    /// Set once the one-time "secrets are now encrypted" notice has gone out
    /// (D1) — it is shown at most once per install.
    static let noticeShown = "secretNoticeShown"
}

/// Settings reads for the secrets feature, and the three timings that are
/// constants rather than preferences (D2/D3 are owner decisions, not knobs).
enum SecretSettings {
    /// Seconds a revealed secret stays shown in the preview pane (D2).
    static let revealSeconds: TimeInterval = 30
    /// Seconds a pasted secret stays on the clipboard before the
    /// clear-after-paste pass wipes it (D3).
    static let clipboardClearDelay: TimeInterval = 90
    /// How long a copied one-time code is kept before the maintenance pass
    /// deletes it — the "Forget one-time codes" toggle's number.
    static let oneTimeCodeLifetime: TimeInterval = 600

    /// Register every default. `register(defaults:)` only fills the
    /// registration domain, so an explicit user preference always wins.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SecretSettingsKeys.mode: SecretMode.keepEncrypted.rawValue,
            SecretSettingsKeys.genericTokens: true,
            SecretSettingsKeys.forgetCodes: true,
            SecretSettingsKeys.clearClipboard: true,
        ])
    }

    /// What the mode picker says; `.keepEncrypted` when the key is unset or
    /// holds something unreadable.
    static var mode: SecretMode {
        guard let raw = UserDefaults.standard.string(forKey: SecretSettingsKeys.mode) else {
            return .keepEncrypted
        }
        return SecretMode(rawValue: raw) ?? .keepEncrypted
    }

    /// Whether the generic token rule runs. Defaults on, including when the
    /// key was never registered.
    static var detectsGenericTokens: Bool {
        defaultsBool(for: SecretSettingsKeys.genericTokens)
    }

    /// Whether one-time codes get an `expiresAt`.
    static var forgetsOneTimeCodes: Bool {
        defaultsBool(for: SecretSettingsKeys.forgetCodes)
    }

    /// Whether `PasteService` wipes a pasted secret after the delay.
    static var clearsClipboardAfterPaste: Bool {
        defaultsBool(for: SecretSettingsKeys.clearClipboard)
    }

    /// Whether this Mac can seal secrets at all. When it cannot, the
    /// picker's first option is annotated as unavailable and the effective
    /// behaviour is "Don't keep it": storing plaintext it cannot protect
    /// would be the worst of the three modes.
    static var canProtect: Bool {
        SecureEnclave.isAvailable
    }

    /// The mode as it actually applies to a capture: `keepEncrypted`
    /// collapses to `drop` on a Mac with no Secure Enclave.
    static var effectiveMode: SecretMode {
        let chosen = mode
        guard chosen == .keepEncrypted, !canProtect else { return chosen }
        return .drop
    }

    /// `bool(forKey:)` with a true default — the three toggles are on unless
    /// the user switched them off, even when no default was registered.
    private static func defaultsBool(for key: String) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}
