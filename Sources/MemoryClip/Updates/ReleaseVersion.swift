import Foundation

/// A three-number release version, ordered.
///
/// Strict on purpose. `Scripts/bump_version.sh` refuses anything that is not
/// `X.Y.Z` before it will write `Info.plist`, and `publish_release.sh` builds
/// the tag, the DMG name and the cask URL out of that same string — so every
/// version this app can ever meet, on either side of the comparison, has
/// exactly three numeric components. Parsing loosely here would only invent
/// orderings for strings the release machinery cannot produce.
///
/// A leading `v` is accepted because that is how the git tag spells it
/// (`v0.5.0`), and the tag is what the GitHub API reports.
struct ReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `0.5.1` or `v0.5.1`; nil for anything else.
    ///
    /// Nil rather than a zero fallback: an unreadable version compared as
    /// 0.0.0 would make every release on the far side of it look newer, and
    /// this decides whether to tell the user to install something.
    init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.first == "v" || body.first == "V" { body.removeFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        // `Int(_:)` accepts a leading `+` or `-`, and `1.-2.0` is not a
        // version — so the digits are checked before they are read.
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
