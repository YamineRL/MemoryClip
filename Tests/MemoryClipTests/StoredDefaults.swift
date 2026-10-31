import Foundation

extension UserDefaults {
    /// The value written to the app's own domain for `key`, ignoring
    /// registered defaults. Snapshot with this, not `object(forKey:)`:
    /// restoring a registered default with `set` writes it to disk for good.
    func storedObject(forKey key: String) -> Any? {
        persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key]
    }
}
