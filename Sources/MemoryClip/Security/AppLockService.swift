import LocalAuthentication

/// Optional Touch ID / passcode gate in front of the clipboard panel.
///
/// Backed by `UserDefaults` (`requireAppLock`, off by default). Uses the
/// `.deviceOwnerAuthentication` policy so the system always offers a passcode
/// fallback when biometrics fail — better UX than biometrics-only.
@MainActor
final class AppLockService {
    static let shared = AppLockService()

    /// `UserDefaults` key for the "require app lock" setting.
    static let settingsKey = "requireAppLock"

    /// How long one successful authentication keeps MemoryClip unlocked.
    ///
    /// The window lives here rather than in a single UI controller so every
    /// surface shares it: authenticating to open the panel also unredacts the
    /// menu-bar dropdown, and vice versa. NSMenu in particular cannot await an
    /// authentication while it is being built, so it needs a window to consult
    /// synchronously.
    static let unlockWindow: TimeInterval = 60

    /// End of the current unlocked window; `.distantPast` when locked.
    private(set) var unlockedUntil: Date = .distantPast

    /// True when clip contents may be shown without authenticating: either the
    /// lock is off, or the user authenticated within `unlockWindow`.
    var isUnlocked: Bool {
        !isEnabled || Date() < unlockedUntil
    }

    private init() {}

    /// Register the default (off) for `settingsKey`. Call once at launch.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [settingsKey: false])
    }

    /// Whether the user has opted into locking the app.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.settingsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.settingsKey) }
    }

    /// Whether this machine can authenticate at all (biometric hardware with
    /// an enrollment, or at least a user passcode set).
    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Run `.deviceOwnerAuthentication` (biometrics with passcode fallback).
    ///
    /// Returns true when unlocked OR when authentication isn't available on
    /// this machine — a missing enrollment must never lock the user out.
    /// Returns false only on user-cancel / failure.
    func authenticate(reason: String) async -> Bool {
        // Fresh LAContext per attempt; reusing one can carry lockout state.
        let context = LAContext()
        var preflightError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &preflightError) else {
            // No Touch ID hardware/enrollment (and no passcode) — don't lock the user out.
            log.notice("AppLock skipped, device can't authenticate: \(preflightError?.localizedDescription ?? "unknown reason")")
            return true
        }
        do {
            // Async variant (throws on cancel/failure); localizedReason is
            // shown in the system Touch ID dialog.
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            // LAError.userCancel / .userFallback / .systemCancel / auth failures → stay locked.
            log.notice("AppLock authentication failed: \(error.localizedDescription)")
            return false
        }
    }

    /// One-shot gate for callers (e.g. opening the panel): passes immediately
    /// when the lock is disabled or unavailable; otherwise requires a
    /// successful authentication.
    ///
    /// A pass opens the shared unlock window (see `unlockWindow`), so one
    /// Touch ID prompt unlocks the panel and the menu-bar dropdown alike. The
    /// gate itself never takes the shortcut: callers that must always
    /// authenticate (export, clear-all) get a real prompt every time.
    func gate(reason: String) async -> Bool {
        guard isEnabled else { return true }
        guard await authenticate(reason: reason) else { return false }
        unlockedUntil = Date().addingTimeInterval(Self.unlockWindow)
        return true
    }
}
