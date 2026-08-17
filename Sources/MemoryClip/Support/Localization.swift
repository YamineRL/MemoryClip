import Foundation

/// A class whose defining bundle locates the module at run time.
private final class CatalogueToken {}

/// The app's string catalogue: `<code>.lproj/Localizable.strings` inside the
/// SwiftPM resource bundle.
///
/// The bundle is found here rather than through `Bundle.module`: the generated
/// accessor looks for `MemoryClip_MemoryClip.bundle` beside `MemoryClip.app`
/// rather than inside it, falls back to an absolute path in the machine that
/// built it, and calls `fatalError` when both miss.
///
/// The localization is matched against the system's language order rather than
/// left to CFBundle's app-wide choice, which is the development region
/// whenever the executable's own bundle carries no `.lproj`.
enum L10n {
    static let bundleName = "MemoryClip_MemoryClip.bundle"

    /// The resource bundle, or the module's own bundle when it is absent.
    static let catalogue = resolveCatalogue()

    /// Language codes the catalogue ships.
    static var available: [String] { catalogue.localizations }

    /// The catalogue language for this process.
    static let code = resolveCode(preferences: Locale.preferredLanguages)

    /// The `.lproj` the strings are read from.
    static let bundle = resolveBundle(code: code)

    /// The locale plural rules and number formats are resolved against.
    static let locale = Locale(identifier: code)

    static func resolveCatalogue() -> Bundle {
        let own = Bundle(for: CatalogueToken.self)
        let roots = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            own.resourceURL,
            own.bundleURL,
            own.bundleURL.deletingLastPathComponent()
        ]
        for root in roots.compactMap({ $0 }) {
            if let found = Bundle(url: root.appending(path: bundleName)) { return found }
        }
        return own
    }

    /// The catalogue language for `preferences`, falling back to English.
    static func resolveCode(preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: available, forPreferences: preferences).first ?? "en"
    }

    static func resolveBundle(code: String) -> Bundle {
        catalogue.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? catalogue
    }

    /// The entry for `key` in `bundle`, or `key` itself when there is none.
    static func string(_ key: String, in bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// The catalogue entry for `key`, or `key` itself when there is none.
func loc(_ key: String) -> String {
    L10n.string(key, in: L10n.bundle)
}

/// `loc(_:)` with `arguments` substituted into the format.
func loc(_ key: String, _ arguments: any CVarArg...) -> String {
    String(format: loc(key), locale: L10n.locale, arguments: arguments)
}
