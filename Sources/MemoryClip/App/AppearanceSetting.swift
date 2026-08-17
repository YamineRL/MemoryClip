import AppKit

/// The user's appearance override for MemoryClip's own windows.
///
/// Until this existed MemoryClip followed the system appearance unconditionally —
/// `Design.Palette.adaptive(light:dark:)` resolves against whatever appearance
/// a view is drawn in, so the app was already Dark-Mode-correct but not
/// Dark-Mode-*choosable*. `.system` keeps exactly that behaviour; the other two
/// pin the app regardless of what macOS is doing, for people who run a light
/// desktop with dark tools or the reverse.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = SettingsKeys.appearance
    static let fallback: AppearanceSetting = .system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: loc("System")
        case .light: loc("Light")
        case .dark: loc("Dark")
        }
    }

    /// The AppKit appearance to pin, or `nil` to inherit from the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The stored setting, treating a missing or unrecognised value as
    /// `.system` rather than failing — a stale string from a future build
    /// should degrade to "follow the system", not to a broken window.
    static var current: AppearanceSetting {
        let raw = UserDefaults.standard.string(forKey: storageKey)
        return raw.flatMap(AppearanceSetting.init(rawValue:)) ?? fallback
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [storageKey: fallback.rawValue])
    }
}

/// Applies `setting` to the whole app.
///
/// Setting it on `NSApp` rather than per-window covers every window MemoryClip owns —
/// the panel, settings, onboarding and the QR sheet — including ones not yet
/// created. None of them assign their own `appearance`, so all of them inherit
/// this, and `nil` hands control back to the system.
@MainActor
func applyAppearanceSetting(_ setting: AppearanceSetting = .current) {
    NSApp.appearance = setting.nsAppearance
}
