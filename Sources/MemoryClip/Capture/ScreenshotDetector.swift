import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Where macOS puts screenshots, and how to tell one from any other image.
///
/// Pure and `nonisolated` throughout: the watcher runs the file-system half
/// off the main actor, and every rule here (folder resolution, the name
/// pattern, the metadata probe) is a function of its inputs so it can be
/// tested without taking a screenshot.
enum ScreenshotDetector {
    /// The preferences domain `screencapture` reads. `location` holds the
    /// save folder and `name` the file-name prefix; both are absent until the
    /// user changes them, which is why every accessor here has a fallback.
    static let screenCaptureDomain = "com.apple.screencapture"

    /// macOS's own default prefix, used when the domain has no `name`.
    ///
    /// Localised builds save "Bildschirmfoto …" rather than "Screenshot …",
    /// so this is only ever a *fallback* for the name test — the metadata
    /// probe below is the real check and is language-independent.
    static let defaultNamePrefix = "Screenshot"

    /// Spotlight's flag for "this file came from screencapture".
    ///
    /// Spelled as a literal rather than the `kMDItemIsScreenCapture` symbol:
    /// the constant is declared in CoreServices' Metadata headers but is not
    /// reliably re-exported to Swift, and the attribute name is the stable
    /// part of the contract either way.
    /// (Held as a `String` because `CFString` is not `Sendable`, and a
    /// static in a Swift 6 module must be.)
    static let screenCaptureAttribute = "kMDItemIsScreenCapture"

    /// How recent a file must be to pass the *fallback* (no-Spotlight) test.
    ///
    /// Only used when Spotlight has no record of the file — normally because
    /// it has not finished indexing the screenshot that was written a moment
    /// ago. A short window keeps the fallback from claiming an old PNG that
    /// merely happens to match the name pattern.
    static let fallbackRecencyWindow: TimeInterval = 120

    // MARK: - Where screenshots land

    /// The folder `screencapture` currently writes to.
    ///
    /// - Parameter defaults: the `com.apple.screencapture` domain, injectable
    ///   so tests can supply a suite instead of the user's real preferences.
    ///
    /// The stored value is a plain path string that may be abbreviated
    /// (`~/Pictures/Shots`) and may point somewhere that no longer exists —
    /// macOS silently falls back to the Desktop in that case, and so do we.
    static func configuredLocation(defaults: UserDefaults? = UserDefaults(suiteName: screenCaptureDomain)) -> URL {
        guard let raw = defaults?.string(forKey: "location") else { return desktopLocation }
        let expanded = (raw as NSString).expandingTildeInPath
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return desktopLocation }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return desktopLocation }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// `~/Desktop`, the macOS default and the fallback for everything above.
    static var desktopLocation: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Desktop", isDirectory: true)
    }

    /// The file-name prefix `screencapture` uses, e.g. "Screenshot" or a
    /// custom one set with `defaults write com.apple.screencapture name`.
    static func namePrefix(defaults: UserDefaults? = UserDefaults(suiteName: screenCaptureDomain)) -> String {
        let raw = defaults?.string(forKey: "name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return defaultNamePrefix }
        return raw
    }

    // MARK: - Is this file a screenshot?

    /// Whether `url` is a screenshot MemoryClip should keep.
    ///
    /// Two tests, in order of authority:
    ///
    /// 1. **Spotlight metadata.** macOS stamps every file `screencapture`
    ///    writes with `kMDItemIsScreenCapture`. This is exact, works whatever
    ///    the user renamed the prefix to, and is language-independent.
    /// 2. **Name and age.** Spotlight indexes asynchronously, so a screenshot
    ///    taken half a second ago often has no record yet. Falling back to
    ///    "matches the configured prefix AND was created in the last couple
    ///    of minutes" catches those without adopting every old PNG on the
    ///    Desktop.
    ///
    /// A file that is not an image never passes either test.
    static func isScreenshot(
        at url: URL,
        namePrefix: String,
        now: Date = .now,
        metadataProbe: (URL) -> Bool? = spotlightIsScreenCapture(at:)
    ) -> Bool {
        guard isImage(at: url) else { return false }
        if let flagged = metadataProbe(url) { return flagged }
        guard looksLikeScreenshotName(url.lastPathComponent, prefix: namePrefix) else { return false }
        guard let created = creationDate(of: url) else { return false }
        let age = now.timeIntervalSince(created)
        return age >= 0 && age <= fallbackRecencyWindow
    }

    /// Spotlight's verdict, or nil when it has no record of the file (not
    /// indexed yet, indexing disabled for the volume, file already gone).
    /// nil means "don't know", which is what sends `isScreenshot` to the
    /// name-and-age fallback rather than to a false negative.
    static func spotlightIsScreenCapture(at url: URL) -> Bool? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        guard let value = MDItemCopyAttribute(item, screenCaptureAttribute as CFString) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Whether the file is an image, by uniform type rather than extension —
    /// `screencapture` can be configured to write jpg, heic, pdf or tiff.
    /// PDF screenshots are excluded on purpose: they are not something the
    /// thumbnail and OCR paths handle as an image.
    static func isImage(at url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// Whether a file name matches the `screencapture` pattern:
    /// `<prefix> <date> at <time>.png`, plus the ` (2)` suffix macOS adds on
    /// collision. Only the prefix is checked strictly — the date portion is
    /// locale-formatted, so pattern-matching it would break outside en_US.
    static func looksLikeScreenshotName(_ name: String, prefix: String) -> Bool {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else { return false }
        guard name.hasPrefix(trimmedPrefix) else { return false }
        // Require a separator after the prefix, so "Screenshots-of-2019.png"
        // (a user's own file) is not mistaken for "Screenshot 2026-…".
        let remainder = name.dropFirst(trimmedPrefix.count)
        guard let next = remainder.first else { return false }
        return next == " " || next == "-" || next == "_"
    }

    /// File creation date, or nil when the file has vanished.
    static func creationDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    /// Size in bytes, or nil when the file has vanished. Used by the
    /// watcher's stability check.
    static func fileSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
